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
