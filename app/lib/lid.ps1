# Versleutelde, ondertekende bestanden per deelnemer. Vereist krypto.ps1 en opslag.ps1.
#
# Drie repo's:
#   doubleleren          (openbaar)  code, website, lessen, sjablonen
#   doubleleren-beheer   (privé; deelnemers alleen lezen, beheerder schrijft)
#       organisatie.json            namen, cellen, projecten, leidinggevenden
#       sleutels/<id>.json          publieke sleutel + kluis (privésleutel achter de inlogcode)
#       toegang/<id>.json           datasleutel (DK) van <id>, verpakt per kijker + vingerafdruk van die kijker
#   doubleleren-data     (privé; deelnemers schrijven)
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

# Datasleutel van <LidId> zoals <MijnId> die mag openen: ALLEEN uit de beheer-repo (pas na goedkeuring)
function Get-DlDk($BeheerOpslag, [string]$LidId, [string]$MijnId, $PriveJwk) {
    $t = Read-DlJson $BeheerOpslag "toegang/$LidId.json"
    $kopie = if ($t) { $t.kopieen.$MijnId } else { $null }
    if (-not $kopie) { throw "Geen sleutelkopie van $LidId voor $MijnId (nog niet goedgekeurd?)" }
    , (Unprotect-DlRsa $PriveJwk (ConvertFrom-B64u $kopie))
}

# Publieke sleutels uit de beheer-repo (huidige + eerdere), met cache. De eigen sleutel telt altijd mee.
function New-DlSleutelbron($BeheerOpslag, [string]$EigenId, $EigenPrive) {
    $cache = @{}
    $eigen = if ($EigenId -and $EigenPrive) { [pscustomobject]@{ kty = 'RSA'; n = $EigenPrive.n; e = $EigenPrive.e } } else { $null }
    {
        param($id)
        if (-not $cache.ContainsKey($id)) {
            $s = Read-DlJson $BeheerOpslag "sleutels/$id.json"
            $lijst = @(); if ($id -eq $EigenId -and $eigen) { $lijst += $eigen }
            if ($s) { $lijst += $s.publiek; $lijst += @($s.eerdere | Where-Object { $_ }) }
            $cache[$id] = $lijst
        }
        $cache[$id]
    }.GetNewClosure()
}
