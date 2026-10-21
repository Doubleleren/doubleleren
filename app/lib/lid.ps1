# Versleutelde, ondertekende bestanden per deelnemer. Vereist krypto.ps1 en opslag.ps1.
#
# Twee repo's:
#   doubleleren          (openbaar; alleen de beheerder schrijft)  code, website, lessen, sjablonen,
#       vertrouwd.json              publieke beheersleutel: daarmee wordt alles onder beheer/ gecontroleerd
#   doubleleren-data     (privé; deelnemers schrijven met een token)
#       beheer/organisatie.json     namen, cellen, projecten, leidinggevenden            } ondertekend door de beheerder;
#       beheer/sleutels/<id>.json   publieke sleutel + kluis                              } een token-houder kan ze niet
#       beheer/toegang/<id>.json    DK van <id>, verpakt per kijker + vingerafdrukken      } vervalsen, alleen verwijderen
#       data/<id>/profiel.enc, matrix.enc, log-JJJJ-MM.enc   versleuteld met DK, ondertekend door <id>
#       data/<id>/wachtrij.enc                                 versleuteld met DK, ondertekend door de generator
#       data/<id>/prive.enc                                    eigen antwoorden, versleuteld met AK (afgeleid uit de eigen privésleutel)
#       aanvragen/<id>.json                                    nieuwe deelnemer, wacht op goedkeuring (controlewoorden)
#       scorebord/<JJJJ-MM>/<id>.json                          aantal goed en reeks van die maand: ondertekend door <id>,
#                                                              NIET versleuteld (het team leest mee), zonder naam
#       feedback/<tijd>-<willekeurig>.json                     feedback, versleuteld met een eigen DK die per kijker
#                                                              (beheer, later generator) is verpakt; binnenin ondertekend
#
# Inhoud van elk .enc-bestand (ontsleuteld): {"v":2,"door":"<ondertekenaar>","inhoud":"<json als tekst>","sig":"<RSA-PSS>"}
# opgevuld tot een veelvoud van 1024 bytes.

function Get-DlLidPad([string]$Id, [string]$Soort) { "data/$Id/$Soort.enc" }

# Wie mag een bestand ondertekenen: de generator de wachtrij, het lid zelf al het andere
function Get-DlVerwachteOndertekenaar([string]$Id, [string]$Soort) { if ($Soort -eq 'wachtrij') { 'generator' } else { $Id } }

function ConvertTo-DlEnvelop([string]$Id, [string]$Soort, $Obj, [string]$Door, $DoorPrive) {
    $inhoud = ConvertTo-Json -InputObject $Obj -Depth 12 -Compress
    $sig = New-DlHandtekening $DoorPrive "$Id|$Soort" $Door $inhoud
    $env = [ordered]@{ v = 2; door = $Door; inhoud = $inhoud; sig = $sig } | ConvertTo-Json -Compress
    , (Add-DlOpvulling $script:DlUtf8.GetBytes($env))
}

# $Publiek: scriptblock dat bij een id de publieke sleutel(s) geeft: de huidige plus eerdere (na 'code kwijt').
# Zonder geldige handtekening van een van die sleutels: fout.
function ConvertFrom-DlEnvelop([string]$Id, [string]$Soort, [byte[]]$Pt, [scriptblock]$Publiek) {
    $env = $script:DlUtf8.GetString($Pt).Trim() | ConvertFrom-Json
    if ([int]$env.v -ne 2) { throw "Onbekend formaat ($Id|$Soort)" }
    $verwacht = Get-DlVerwachteOndertekenaar $Id $Soort
    if ($env.door -ne $verwacht) { throw "Onverwachte ondertekenaar '$($env.door)' voor $Id|$Soort" }
    $geldig = $false
    foreach ($pub in @(& $Publiek $env.door)) { if ($pub -and (Test-DlHandtekening $pub "$Id|$Soort" $env.door $env.inhoud $env.sig)) { $geldig = $true; break } }
    if (-not $geldig) { throw "Handtekening ongeldig voor $Id|$Soort" }
    $env.inhoud | ConvertFrom-Json
}

function Read-DlVersleuteld($O, [string]$Id, [string]$Soort, [hashtable]$Sleutels, [scriptblock]$Publiek) {
    $r = Read-DlOpslag $O (Get-DlLidPad $Id $Soort)
    if (-not $r) { return $null }
    $pt = Unprotect-Dl $Sleutels "$Id|$Soort" $r.bytes
    @{ obj = (ConvertFrom-DlEnvelop $Id $Soort $pt $Publiek); sha = $r.sha }
}

function Write-DlVersleuteld($O, [string]$Id, [string]$Soort, [hashtable]$Sleutels, $Obj, [string]$Sha, [string]$Door, $DoorPrive) {
    Write-DlOpslag $O (Get-DlLidPad $Id $Soort) (Protect-Dl $Sleutels "$Id|$Soort" (ConvertTo-DlEnvelop $Id $Soort $Obj $Door $DoorPrive)) $Sha
}

# Lezen, wijzigen, schrijven; bij een conflict (andere laptop schreef net) opnieuw vanaf de nieuwste versie
function Update-DlVersleuteld($O, [string]$Id, [string]$Soort, [hashtable]$Sleutels, [scriptblock]$Wijzig, [string]$Door, $DoorPrive, [scriptblock]$Publiek) {
    for ($poging = 1; $poging -le 4; $poging++) {
        $h = Read-DlVersleuteld $O $Id $Soort $Sleutels $Publiek
        $nieuw = & $Wijzig $(if ($h) { $h.obj } else { $null })
        try { return (Write-DlVersleuteld $O $Id $Soort $Sleutels $nieuw $(if ($h) { $h.sha } else { $null }) $Door $DoorPrive) }
        catch { if ("$_" -ne 'conflict') { throw }; Start-Sleep -Milliseconds (400 * $poging) }
    }
    throw "Opslaan van $Soort lukt niet: blijft botsen met een andere wijziging"
}

# --- Beheerbestanden: leesbaar (privé repo) maar ondertekend met de beheersleutel uit vertrouwd.json ---
function Read-DlBeheer($O, [string]$Pad, $Vertrouwd) {
    $r = Read-DlOpslag $O "beheer/$Pad"
    if (-not $r) { return $null }
    $env = $script:DlUtf8.GetString($r.bytes).Trim() | ConvertFrom-Json
    if ([int]$env.v -ne 2 -or $env.door -ne 'beheer' -or -not (Test-DlHandtekening $Vertrouwd "beheer|$Pad" 'beheer' $env.inhoud $env.sig)) {
        throw "Beheerbestand $Pad heeft geen geldige handtekening van de beheerder"
    }
    $env.inhoud | ConvertFrom-Json
}
function Write-DlBeheer($O, [string]$Pad, $Obj, $BeheerPrive) {
    $inhoud = ConvertTo-Json -InputObject $Obj -Depth 12 -Compress
    $env = [ordered]@{ v = 2; door = 'beheer'; inhoud = $inhoud; sig = (New-DlHandtekening $BeheerPrive "beheer|$Pad" 'beheer' $inhoud) }
    $b = Read-DlOpslag $O "beheer/$Pad"
    Write-DlOpslag $O "beheer/$Pad" ($script:DlUtf8.GetBytes(($env | ConvertTo-Json -Compress))) $(if ($b) { $b.sha }) | Out-Null
}

# Datasleutel van <LidId> zoals <MijnId> die mag openen: ALLEEN uit de ondertekende toegang (pas na goedkeuring)
function Get-DlDk($O, [string]$LidId, [string]$MijnId, $PriveJwk, $Vertrouwd) {
    $t = Read-DlBeheer $O "toegang/$LidId.json" $Vertrouwd
    $kopie = if ($t) { $t.kopieen.$MijnId } else { $null }
    if (-not $kopie) { throw "Geen sleutelkopie van $LidId voor $MijnId (nog niet goedgekeurd?)" }
    , (Unprotect-DlRsa $PriveJwk (ConvertFrom-B64u $kopie))
}

# Publieke sleutels (huidige + eerdere) uit de ondertekende beheerbestanden, met cache.
# 'generator' is de beheersleutel uit vertrouwd.json. De eigen sleutel telt altijd mee.
function New-DlSleutelbron($O, $Vertrouwd, [string]$EigenId, $EigenPrive) {
    $cache = @{}
    $eigen = if ($EigenId -and $EigenPrive) { [pscustomobject]@{ kty = 'RSA'; n = $EigenPrive.n; e = $EigenPrive.e } } else { $null }
    {
        param($id)
        if (-not $cache.ContainsKey($id)) {
            $lijst = @(); if ($id -eq $EigenId -and $eigen) { $lijst += $eigen }
            if ($id -eq 'generator') { $cache[$id] = @($Vertrouwd); return $cache[$id] }
            $s = $null; try { $s = Read-DlBeheer $O "sleutels/$id.json" $Vertrouwd } catch {}
            if ($s) { $lijst += $s.publiek; $lijst += @($s.eerdere | Where-Object { $_ }) }
            $cache[$id] = $lijst
        }
        $cache[$id]
    }.GetNewClosure()
}

# --- Scorebord: per maand aantal goed en reeks; zelfde rekenregels als maandStand()/reeks() in docs/app.js ---
function Get-DlLogDagen($Logs) { @($Logs | ForEach-Object { "$($_.datum)" } | Where-Object { $_.Length -ge 10 } | ForEach-Object { $_.Substring(0, 10) } | Sort-Object -Unique) }
function Test-DlWerkdag([datetime]$D) { $D.DayOfWeek -ne 'Saturday' -and $D.DayOfWeek -ne 'Sunday' }
# Huidige reeks: vanaf vandaag (als er vandaag een les is) of gisteren terug; weekenden onderbreken niet
function Get-DlReeks($Logs, [datetime]$Nu = (Get-Date)) {
    $dagen = @{}; foreach ($d in (Get-DlLogDagen $Logs)) { $dagen[$d] = $true }
    $d = $Nu.Date; if (-not $dagen[$d.ToString('yyyy-MM-dd')]) { $d = $d.AddDays(-1) }
    $n = 0
    for ($i = 0; $i -lt 3650; $i++) {
        if ($dagen[$d.ToString('yyyy-MM-dd')]) { $n++ } elseif (Test-DlWerkdag $d) { break }
        $d = $d.AddDays(-1)
    }
    $n
}
function Get-DlMaandStand($Logs, [string]$Maand, [datetime]$Nu = (Get-Date)) {
    $inM = @($Logs | Where-Object { "$($_.datum)".StartsWith($Maand) })
    $dagen = @{}; foreach ($d in (Get-DlLogDagen $inM)) { $dagen[$d] = $true }
    $d = [datetime]::ParseExact("$Maand-01", 'yyyy-MM-dd', $null); $tot = $Nu.ToString('yyyy-MM-dd'); $lang = 0; $cur = 0
    while ($d.ToString('yyyy-MM') -eq $Maand -and $d.ToString('yyyy-MM-dd') -le $tot) {
        $k = $d.ToString('yyyy-MM-dd')
        if ($dagen[$k]) { $cur++; if ($cur -gt $lang) { $lang = $cur } } elseif ((Test-DlWerkdag $d) -and $k -ne $tot) { $cur = 0 }
        $d = $d.AddDays(1)
    }
    $laatste = @($dagen.Keys | Sort-Object) | Select-Object -Last 1
    [pscustomobject]@{ goed = @($inM | Where-Object { $_.resultaat -eq 'goed' }).Count; langsteReeks = $lang; reeksAanEind = $cur; laatsteDag = $laatste; lessen = $inM.Count }
}
function Read-DlScore($O, [string]$Maand, [string]$Id, $Publiek) {
    $r = Read-DlOpslag $O "scorebord/$Maand/$Id.json"
    if (-not $r) { return $null }
    $env = $script:DlUtf8.GetString($r.bytes).Trim() | ConvertFrom-Json
    $geldig = [int]$env.v -eq 2 -and $env.door -eq $Id
    if ($geldig) { $geldig = $false; foreach ($pub in @($Publiek)) { if ($pub -and (Test-DlHandtekening $pub "scorebord|$Maand|$Id" $Id $env.inhoud $env.sig)) { $geldig = $true; break } } }
    if (-not $geldig) { throw "Scorebord $Maand/$Id heeft geen geldige handtekening" }
    @{ obj = ($env.inhoud | ConvertFrom-Json); sha = $r.sha }
}
# Wil het lid op het scorebord? Dat staat in het eigen profiel (versleuteld en ondertekend door het lid zelf), niet in de
# openbare scorebordbestanden: die kan een collega met een token verwijderen of terugzetten.
function Get-DlScorebordZichtbaar($C, [hashtable]$Sleutels) {
    $p = Read-DlVersleuteld $C.data $C.id 'profiel' $Sleutels $C.publiek
    -not ($p -and $p.obj.scorebord -eq $false)
}
# Eigen stand bijwerken voor deze maand en (als daar lessen in zaten) de vorige. Schrijft alleen als er iets veranderde.
function Write-DlScorebord($C, $Logs, [bool]$Zichtbaar = $true, [datetime]$Nu = (Get-Date)) {
    $id = $C.id; $zichtbaar = $Zichtbaar
    $nuM = $Nu.ToString('yyyy-MM')
    foreach ($maand in @($Nu.AddMonths(-1).ToString('yyyy-MM'), $nuM)) {
        $pad = "scorebord/$maand/$id.json"
        for ($poging = 1; $poging -le 3; $poging++) {
            $oud = Read-DlOpslag $C.data $pad
            $st = Get-DlMaandStand $Logs $maand $Nu
            if ($maand -ne $nuM -and -not $st.lessen -and -not $oud) { break }
            $obj = if ($zichtbaar) {
                [ordered]@{ v = 1; maand = $maand; zichtbaar = $true; goed = [int]$st.goed; langsteReeks = [int]$st.langsteReeks
                    huidigeReeks = [int]$(if ($maand -eq $nuM) { Get-DlReeks $Logs $Nu } else { $st.reeksAanEind }); laatsteDag = $st.laatsteDag }
            } else { [ordered]@{ v = 1; maand = $maand; zichtbaar = $false } }
            if ($oud) {
                $o = $null; try { $o = ($script:DlUtf8.GetString($oud.bytes).Trim() | ConvertFrom-Json).inhoud | ConvertFrom-Json } catch {}
                if ($o -and -not @('zichtbaar', 'goed', 'langsteReeks', 'huidigeReeks', 'laatsteDag' | Where-Object { "$($o.$_)" -ne "$($obj[$_])" })) { break }
            }
            $obj.bijgewerkt = $Nu.ToString('s')
            $inhoud = ConvertTo-Json -InputObject $obj -Compress
            $env = [ordered]@{ v = 2; door = $id; inhoud = $inhoud; sig = (New-DlHandtekening $C.prive "scorebord|$maand|$id" $id $inhoud) } | ConvertTo-Json -Compress
            try { Write-DlOpslag $C.data $pad ($script:DlUtf8.GetBytes($env)) $(if ($oud) { $oud.sha }) | Out-Null; break }
            catch { if ("$_" -ne 'conflict' -or $poging -eq 3) { throw }; Start-Sleep -Milliseconds 400 }
        }
    }
}

# --- Halfjaarlijkse check van de skilllijst; zelfde regels als ronde() in docs/app.js ---
# Rondes: januari (deadline 31 januari) en juli (31 juli). Gedaan = een score uit dat halfjaar. Wie zijn eerste meting
# of zijn aanmelding minder dan ~3 maanden voor de deadline deed, slaat die ronde over.
function Get-DlRonde($Matrix, [string]$Sinds, [datetime]$D = (Get-Date)) {
    $h2 = $D.Month -ge 7; $mnd = if ($h2) { 7 } else { 1 }
    $start = '{0}-{1:00}' -f $D.Year, $mnd; $eind = '{0}-{1:00}' -f $D.Year, ($mnd + 5)
    $maanden = @()
    if ($Matrix -and $Matrix.scores) { foreach ($p in $Matrix.scores.PSObject.Properties) { if ($p.Value) { $maanden += @($p.Value.PSObject.Properties.Name) } } }
    $maanden = @($maanden | Where-Object { $_ -match '^\d{4}-(0[1-9]|1[0-2])$' } | Sort-Object -Unique)
    $voldaan = [bool]@($maanden | Where-Object { $_ -ge $start -and $_ -le $eind }).Count
    $grens = (New-Object DateTime($D.Year, $mnd, 1)).AddMonths(-2).ToString('yyyy-MM')
    $sindsM = if ($Sinds -match '^\d{4}-\d{2}') { $Sinds.Substring(0, 7) } else { $null }
    $vrij = [bool]((-not $voldaan) -and (($maanden.Count -and $maanden[0] -ge $grens) -or ($sindsM -and $sindsM -ge $grens)))
    $nodig = -not $voldaan -and -not $vrij
    [pscustomobject]@{ voldaan = $voldaan; vrij = $vrij; nodig = $nodig; teLaat = $nodig -and $D -gt (New-Object DateTime($D.Year, $mnd, 31, 23, 59, 59))
        tekst = "31 $(if ($h2) { 'juli' } else { 'januari' })" }
}

# --- Feedback: spiegelbeeld van verstuurFeedback() in docs/app.js ---
$script:DlFeedbackSoorten = @('bug', 'fout', 'toevoeging', 'goed')
# Lezen met de privésleutel van een kijker ('beheer' of 'generator'); controleert de handtekening van het lid
function Read-DlFeedback($O, [string]$Bestand, [string]$Kijker, $KijkerPrive, [scriptblock]$Publiek) {
    $naam = $Bestand -replace '\.json$', ''
    if ($naam -notmatch '^\d{8}T\d{6}-[0-9a-f]{8}$') { throw "Onverwachte bestandsnaam $Bestand" }
    $r = Read-DlOpslag $O "feedback/$naam.json"; if (-not $r) { return $null }
    $f = $script:DlUtf8.GetString($r.bytes).Trim() | ConvertFrom-Json
    $kopie = $f.kopieen.$Kijker
    if ([int]$f.v -ne 1 -or -not $kopie -or -not $f.blob) { throw "Feedback ${naam}: onbekend formaat of geen kopie voor $Kijker" }
    $pt = Unprotect-Dl (Get-DlSleutelsUitDk (Unprotect-DlRsa $KijkerPrive (ConvertFrom-B64u $kopie))) "feedback|$naam" (ConvertFrom-B64u $f.blob)
    $env = $script:DlUtf8.GetString($pt).Trim() | ConvertFrom-Json
    if ([int]$env.v -ne 2 -or "$($env.door)" -notmatch '^lid-[0-9a-f]{6}$') { throw "Feedback ${naam}: onbekend formaat" }
    $geldig = $false
    foreach ($pub in @(& $Publiek $env.door)) { if ($pub -and (Test-DlHandtekening $pub "feedback|$naam" $env.door $env.inhoud $env.sig)) { $geldig = $true; break } }
    if (-not $geldig) { throw "Feedback ${naam}: ongeldige handtekening" }
    $i = $env.inhoud | ConvertFrom-Json
    if ($script:DlFeedbackSoorten -notcontains $i.soort -or -not $i.tekst -or "$($i.datum)" -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$') { throw "Feedback ${naam}: onbekende inhoud" }
    $tekst = [string]$i.tekst
    [pscustomobject]@{ bestand = $naam; door = $env.door; soort = $i.soort; les = $(if ("$($i.les)" -match '^[0-9a-z][0-9a-z-]{0,80}$') { $i.les }); tekst = $tekst.Substring(0, [Math]::Min(2000, $tekst.Length)); datum = $i.datum }
}
# Schrijven (de website doet dit normaal; gebruikt door tests). $Kopieen: @{ beheer = <publieke JWK>; generator = ... }
function New-DlFeedback($O, [string]$Door, $DoorPrive, [hashtable]$Kopieen, [string]$Soort, [string]$Tekst, [string]$Les, [datetime]$Tijd = (Get-Date)) {
    $naam = $Tijd.ToString('yyyyMMddTHHmmss') + '-' + (-join ((Get-DlWillekeurig 4) | ForEach-Object { $_.ToString('x2') }))
    $i = [ordered]@{ v = 1; soort = $Soort }; if ($Les) { $i.les = $Les }; $i.tekst = $Tekst; $i.datum = $Tijd.ToString('s')
    $inhoud = ConvertTo-Json -InputObject $i -Compress
    $env = [ordered]@{ v = 2; door = $Door; inhoud = $inhoud; sig = (New-DlHandtekening $DoorPrive "feedback|$naam" $Door $inhoud) } | ConvertTo-Json -Compress
    $dk = Get-DlWillekeurig 32
    $kop = [ordered]@{}; foreach ($k in $Kopieen.Keys) { $kop[$k] = ConvertTo-B64u (Protect-DlRsa $Kopieen[$k] $dk) }
    $blob = Protect-Dl (Get-DlSleutelsUitDk $dk) "feedback|$naam" (Add-DlOpvulling $script:DlUtf8.GetBytes($env))
    Write-DlOpslag $O "feedback/$naam.json" ($script:DlUtf8.GetBytes(([ordered]@{ v = 1; kopieen = $kop; blob = (ConvertTo-B64u $blob) } | ConvertTo-Json -Compress))) $null | Out-Null
    $naam
}
