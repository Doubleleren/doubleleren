# Beheer van DoubleLeren (alleen voor de beheerder).
# Werkt in de lokale kopie van de PRIVÉ beheer-repo (organisatie, sleutels, toegang), standaard
# %LOCALAPPDATA%\DoubleLeren\beheer\repo (buiten OneDrive). -Push zet wijzigingen online.
#
#   beheer.ps1 -Init                                             eenmalig: generatorsleutel; vraagt je beheertoken (niet zichtbaar)
#   beheer.ps1 -Uitnodigen -Naam Alfa -Rol projectleider -Project ecom-b2b [-Optioneel] [-Beheerder]
#   beheer.ps1 -Aanvragen                                        openstaande aanmeldingen
#   beheer.ps1 -Goedkeuren lid-xxxxxx -Controlewoorden "a b c d e f"
#   beheer.ps1 -Wijzig lid-xxxxxx -Leren verplicht|optioneel
#   beheer.ps1 -Bijwerken                                        toegang opnieuw berekenen (na wijziging organogram of sleutels)
#   beheer.ps1 -Controleer                                       overzicht: wie ziet wie
# Rollen: lid (met -Project of -Cel), projectleider (-Project), celleider (-Cel), head.
param(
    [switch]$Init, [switch]$Uitnodigen, [switch]$Aanvragen, [string]$Goedkeuren, [switch]$Bijwerken, [switch]$Controleer, [string]$Wijzig,
    [string]$Naam, [ValidateSet('lid', 'projectleider', 'celleider', 'head')][string]$Rol = 'lid', [string]$Project, [string]$Cel,
    [string]$Controlewoorden, [switch]$Push, [switch]$Optioneel, [switch]$Beheerder,
    [ValidateSet('', 'verplicht', 'optioneel')][string]$Leren = '',
    [string]$DataMap, [string]$BeheerMap, [string]$Thuis       # tests: lokale mappen i.p.v. GitHub
)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'organisatie', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Utf8 = New-Object Text.UTF8Encoding($false)
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
if (-not $BeheerMap) { $BeheerMap = Join-Path $Thuis 'repo' }
New-Item -ItemType Directory $Thuis, $BeheerMap -Force | Out-Null
$geheimPad = Join-Path $Thuis 'beheer.dpapi'
$geheim = Read-DlGeheim $geheimPad
$beheerO = New-DlOpslag -Map $BeheerMap
$orgPad = Join-Path $BeheerMap 'organisatie.json'
if (-not (Test-Path $orgPad)) { Copy-Item (Join-Path $App 'sjablonen\organisatie-sjabloon.json') $orgPad }
$org = Get-Content $orgPad -Raw -Encoding UTF8 | ConvertFrom-Json

function Save-Org { [IO.File]::WriteAllText($orgPad, ($org | ConvertTo-Json -Depth 10), $Utf8) }
function Save-Geheim { Save-DlGeheim $geheimPad $script:geheim }
function Naam($id) { if ($id -eq 'generator') { return 'generator' }; $n = $org.leden.$id.naam; if ($n) { "$n ($id)" } else { $id } }
function DataOpslag {
    if ($DataMap) { return (New-DlOpslag -Map $DataMap) }
    if (-not $geheim.token) { throw 'Geen beheertoken: draai eerst -Init' }
    New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token
}
function GenPrive { if (-not $geheim.generatorPrive) { throw 'Geen generatorsleutel: draai eerst -Init' }; $geheim.generatorPrive }
function PubVan($id) { $s = Read-DlJson $beheerO "sleutels/$id.json"; if ($s) { $s.publiek } }

# Toegang: de DK verpakt voor elke kijker met een goedgekeurde sleutel, plus de vingerafdruk van die sleutel
function New-Toegang([string]$id, [byte[]]$dk, [int]$versie) {
    $kop = [ordered]@{}; $vf = [ordered]@{}
    foreach ($k in @(Get-DlKijkers $org $id)) {
        $pub = PubVan $k; if (-not $pub) { continue }
        $kop[$k] = ConvertTo-B64u (Protect-DlRsa $pub $dk); $vf[$k] = Get-DlVingerafdrukHex $pub
    }
    [ordered]@{ v = 2; versie = $versie; kopieen = $kop; vingerafdrukken = $vf }
}
function Write-Toegang([string]$id, $t) { Write-DlJson $beheerO "toegang/$id.json" $t (Read-DlOpslag $beheerO "toegang/$id.json").sha | Out-Null }

# Sleutelwissel, hervatbaar: de nieuwe DK staat eerst veilig in de beheergeheimen, daarna wordt alles omgezet
function Start-Rotatie([string]$id, [byte[]]$oudDk) {
    if (-not $geheim.rotaties) { $geheim | Add-Member -NotePropertyName rotaties -NotePropertyValue ([pscustomobject]@{}) -Force }
    $nieuw = Get-DlWillekeurig 32
    $geheim.rotaties | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ oud = (ConvertTo-B64u $oudDk); nieuw = (ConvertTo-B64u $nieuw) }) -Force
    Save-Geheim
}
function Complete-Rotatie([string]$id) {
    $r = $geheim.rotaties.$id
    $oud = Get-DlSleutelsUitDk (ConvertFrom-B64u $r.oud); $nieuwDk = ConvertFrom-B64u $r.nieuw; $nieuw = Get-DlSleutelsUitDk $nieuwDk
    $d = DataOpslag
    $zet = {
        foreach ($f in (Get-DlOpslagLijst $d "data/$id")) {
            if ($f -notlike '*.enc' -or $f -eq 'prive.enc') { continue }
            $soort = $f -replace '\.enc$', ''; $b = Read-DlOpslag $d "data/$id/$f"
            try { Unprotect-Dl $nieuw "$id|$soort" $b.bytes | Out-Null; continue } catch {}      # al omgezet
            $pt = Unprotect-Dl $oud "$id|$soort" $b.bytes
            Write-DlOpslag $d "data/$id/$f" (Protect-Dl $nieuw "$id|$soort" $pt) $b.sha | Out-Null
        }
    }
    & $zet
    $oudT = Read-DlJson $beheerO "toegang/$id.json"
    Write-Toegang $id (New-Toegang $id $nieuwDk ([int]$(if ($oudT) { $oudT.versie } else { 0 }) + 1))
    & $zet      # wat een laptop tijdens de wissel nog met de oude sleutel schreef
    $geheim.rotaties.PSObject.Properties.Remove($id); Save-Geheim
}

if ($Init) {
    if ($geheim -and $geheim.generatorPrive) { Write-Host 'Generatorsleutel bestaat al.' }
    else {
        $kp = New-DlSleutelpaar 3072
        $script:geheim = [pscustomobject]@{ generatorPrive = $kp.prive; token = $null; rotaties = [pscustomobject]@{} }
        Write-DlJson $beheerO 'sleutels/generator.json' ([ordered]@{ v = 1; id = 'generator'; publiek = $kp.publiek }) (Read-DlOpslag $beheerO 'sleutels/generator.json').sha | Out-Null
        Write-Host "Generatorsleutel gemaakt. De privésleutel staat beschermd in $geheimPad"
    }
    if (-not $DataMap) {
        $s = Read-Host 'Plak je beheertoken (wordt niet getoond, Enter = overslaan)' -AsSecureString
        $t = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
        if ($t) { $geheim.token = $t.Trim(); Write-Host 'Token opgeslagen (DPAPI).' }
    }
    Save-Geheim
}

elseif ($Uitnodigen) {
    if (-not $Naam) { throw 'Geef -Naam' }
    if (-not $geheim) { throw 'Draai eerst -Init' }
    $id = 'lid-' + (-join ((Get-DlWillekeurig 3) | ForEach-Object { $_.ToString('x2') }))
    $lid = [ordered]@{ naam = $Naam }
    $alleProjecten = @($org.cellen | ForEach-Object { $_.projecten })
    switch ($Rol) {
        'head' { $org.head = $id }
        'celleider' {
            $c = @($org.cellen | Where-Object id -eq $Cel)[0]; if (-not $c) { throw "Onbekende cel '$Cel' ($(($org.cellen.id) -join ', '))" }
            $c.leider = $id; $lid.cel = $Cel
        }
        default {
            if ($Project) {
                $p = @($alleProjecten | Where-Object id -eq $Project)[0]; if (-not $p) { throw "Onbekend project '$Project' ($(($alleProjecten.id) -join ', '))" }
                $lid.project = $Project
                if ($Rol -eq 'projectleider') { $p.leider = $id }
            } elseif ($Cel) { $lid.cel = $Cel }
            elseif ($Rol -eq 'projectleider') { throw 'Een projectleider heeft -Project nodig' }
        }
    }
    if ($Optioneel) { $lid.leren = 'optioneel' }
    if ($Beheerder) { $org.beheerders = @(@($org.beheerders) + $id | Where-Object { $_ }) }
    $org.leden | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]$lid)
    Save-Org
    $plekTekst = if ($Project) { $Project } elseif ($Cel) { "cel $Cel" } else { '-' }
    $uitPad = Join-Path $Thuis 'uitnodigingen.md'
    if (-not (Test-Path $uitPad)) { [IO.File]::WriteAllText($uitPad, "| Naam | Rol | Plek | Lessen | Id |`n|---|---|---|---|---|`n", $Utf8) }
    [IO.File]::AppendAllText($uitPad, "| $Naam | $Rol | $plekTekst | $(if ($Optioneel) { 'optioneel' } else { 'verplicht' }) | $id |`n", $Utf8)
    Write-Host "Uitnodiging voor $Naam ($id, $Rol$(if ($Optioneel) { ', lessen optioneel' }))" -ForegroundColor Green
    Write-Host "Maak een token (github.com/settings/personal-access-tokens/new): repo's $($inst.dataRepo) (Contents: Read and write)"
    Write-Host "en $($inst.beheerRepo) (Contents: Read-only), zonder vervaldatum (intrekken bij vertrek). Uitnodigingscode: $id`:<token>"
}

elseif ($Wijzig) {
    if (-not $org.leden.$Wijzig) { throw "Onbekend: $Wijzig" }
    if (-not $Leren) { throw 'Geef -Leren verplicht of -Leren optioneel' }
    $org.leden.$Wijzig | Add-Member -NotePropertyName leren -NotePropertyValue $Leren -Force
    Save-Org
    Write-Host "$(Naam $Wijzig): lessen $Leren. Push om het door te voeren; de pop-up pakt het bij de volgende start op."
}

elseif ($Aanvragen) {
    $d = DataOpslag
    $lijst = @(Get-DlOpslagLijst $d 'aanvragen')
    if (-not $lijst.Count) { Write-Host 'Geen openstaande aanvragen.' }
    foreach ($f in $lijst) {
        $a = Read-DlJson $d "aanvragen/$f"
        $vorm = if (Test-DlSleutelVorm $a.publiek) { '' } else { '  (ONGELDIGE SLEUTEL)' }
        Write-Host ("{0,-28} {1}{2}  controlewoorden: {3}" -f (Naam $a.id), $(if ($a.herstel) { 'herstel ' } else { '' }), $vorm, (Get-DlControlewoorden $a))
    }
}

elseif ($Goedkeuren) {
    $id = $Goedkeuren; $d = DataOpslag
    if (-not $org.leden.$id) { throw "$id staat niet in het organogram: eerst uitnodigen" }
    $a = Read-DlOpslag $d "aanvragen/$id.json"; if (-not $a) { throw "Geen aanvraag voor $id" }
    $aanvraag = $script:DlUtf8.GetString($a.bytes) | ConvertFrom-Json
    if ($aanvraag.id -ne $id) { throw 'Aanvraag hoort bij een ander id' }
    if (-not (Test-DlSleutelVorm $aanvraag.publiek)) { throw 'De sleutel in de aanvraag heeft niet de vaste vorm: niet goedkeuren.' }
    $echt = Get-DlControlewoorden $aanvraag
    $gegeven = (($Controlewoorden.ToLower() -split '[\s,\-]+') | Where-Object { $_ }) -join ' '
    if ($gegeven -ne $echt) { throw "Controlewoorden komen NIET overeen. Niet goedkeuren: vraag $(Naam $id) opnieuw te installeren en de woorden opnieuw door te geven." }
    $sleutelsObj = [ordered]@{ v = 2; id = $id; publiek = $aanvraag.publiek; kluis = $aanvraag.kluis }
    if ($aanvraag.herstel) {
        # Code kwijt: nieuwe sleutel en meteen een nieuwe datasleutel, zodat de oude code of laptop niets meer opent
        $oudT = Read-DlJson $beheerO "toegang/$id.json"; if (-not $oudT) { throw "Herstel kan niet: $id had nog geen toegang" }
        $oudDk = Unprotect-DlRsa (GenPrive) (ConvertFrom-B64u $oudT.kopieen.generator)
        # Oude publieke sleutel(s) bewaren: alleen om oude handtekeningen te controleren
        $oudS = Read-DlJson $beheerO "sleutels/$id.json"
        $sleutelsObj.eerdere = @(@($oudS.publiek) + @($oudS.eerdere) | Where-Object { $_ })
        Write-DlJson $beheerO "sleutels/$id.json" $sleutelsObj (Read-DlOpslag $beheerO "sleutels/$id.json").sha | Out-Null
        Start-Rotatie $id $oudDk; Complete-Rotatie $id
    } else {
        if (Read-DlOpslag $beheerO "sleutels/$id.json") { throw "$id is al goedgekeurd; gebruik herstel" }
        $dk = Unprotect-DlRsa (GenPrive) (ConvertFrom-B64u $aanvraag.toegang.generator)
        Write-DlJson $beheerO "sleutels/$id.json" $sleutelsObj $null | Out-Null
        Write-Toegang $id (New-Toegang $id $dk 1)
    }
    Remove-DlOpslag $d "aanvragen/$id.json" $a.sha
    $t = Read-DlJson $beheerO "toegang/$id.json"
    Write-Host "Goedgekeurd: $(Naam $id). Zichtbaar voor: $((@($t.kopieen.PSObject.Properties.Name) | ForEach-Object { Naam $_ }) -join ', ')" -ForegroundColor Green
    $Bijwerken = $true   # leidinggevenden krijgen toegang tot de nieuwe persoon en andersom
}

if ($Bijwerken) {
    foreach ($p in @($(if ($geheim.rotaties) { $geheim.rotaties.PSObject.Properties.Name }) | Where-Object { $_ })) { Write-Host "Afgebroken sleutelwissel hervatten: $(Naam $p)"; Complete-Rotatie $p }
    $gen = GenPrive
    foreach ($id in @($org.leden.PSObject.Properties.Name)) {
        $t = Read-DlJson $beheerO "toegang/$id.json"; if (-not $t) { continue }
        $dk = Unprotect-DlRsa $gen (ConvertFrom-B64u $t.kopieen.generator)
        $moet = @(Get-DlKijkers $org $id | Where-Object { PubVan $_ })
        $heeft = @($t.kopieen.PSObject.Properties.Name)
        $weg = @($heeft | Where-Object { $moet -notcontains $_ })
        $erbij = @($moet | Where-Object { $heeft -notcontains $_ })
        $anders = @($moet | Where-Object { $heeft -contains $_ -and $t.vingerafdrukken.$_ -ne (Get-DlVingerafdrukHex (PubVan $_)) })
        if (-not ($weg.Count + $erbij.Count + $anders.Count)) { continue }
        if ($weg.Count -or $anders.Count) { Start-Rotatie $id $dk; Complete-Rotatie $id }       # iemand verliest toegang of een sleutel is vervangen
        else { Write-Toegang $id (New-Toegang $id $dk ([int]$t.versie)) }
        $tekst = @(); if ($erbij.Count) { $tekst += "+ $(($erbij | ForEach-Object { Naam $_ }) -join ', ')" }
        if ($weg.Count) { $tekst += "- $(($weg | ForEach-Object { Naam $_ }) -join ', ')" }
        if ($anders.Count) { $tekst += "nieuwe sleutel: $(($anders | ForEach-Object { Naam $_ }) -join ', ')" }
        Write-Host "$(Naam $id): $($tekst -join '; ')$(if ($weg.Count -or $anders.Count) { ' (datasleutel vernieuwd)' })"
    }
}

if ($Controleer) {
    Write-Host ("{0,-30} {1,-20} {2,-22} {3}" -f 'Deelnemer', 'Rol', 'Project / cel', 'Zichtbaar voor')
    foreach ($id in @($org.leden.PSObject.Properties.Name)) {
        $l = $org.leden.$id; $plek = if ($l.project) { $l.project } elseif ($l.cel) { "cel $($l.cel)" } else { '-' }
        $rolTekst = if ($org.head -eq $id) { 'head' } elseif (@($org.cellen | Where-Object leider -eq $id).Count) { 'celleider' } elseif (@($org.cellen.projecten | Where-Object leider -eq $id).Count) { 'projectleider' } else { 'lid' }
        if ($l.leren -eq 'optioneel') { $rolTekst += ' (opt.)' }
        $t = Read-DlJson $beheerO "toegang/$id.json"
        $kijkers = if ($t) { @($t.kopieen.PSObject.Properties.Name | Where-Object { $_ -ne $id }) | ForEach-Object { Naam $_ } } else { @('(nog niet goedgekeurd)') }
        Write-Host ("{0,-30} {1,-20} {2,-22} {3}" -f (Naam $id), $rolTekst, $plek, ($kijkers -join ', '))
    }
}

if ($Push) {
    if (-not (Test-Path (Join-Path $BeheerMap '.git'))) { throw "$BeheerMap is nog geen git-kopie van $($inst.beheerRepo)" }
    git -C $BeheerMap add -A organisatie.json sleutels toegang
    git -C $BeheerMap -c user.name=doubleleren -c user.email=sync@doubleleren.invalid commit -q -m 'sync' 2>$null
    git -C $BeheerMap push -q
}
