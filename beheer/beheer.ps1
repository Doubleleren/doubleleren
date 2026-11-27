# Beheer van DoubleLeren (alleen voor de beheerder). Wijzigingen gaan direct naar de privé data-repo,
# ondertekend met de beheersleutel (de publieke helft staat in vertrouwd.json in de openbare app-repo).
#
#   beheer.ps1 -Init                                             eenmalig: beheersleutel; vraagt je beheertoken (niet zichtbaar)
#   beheer.ps1 -Uitnodigen -Naam Alfa -Rol projectleider -Project ecom-b2b [-Vak cro] [-Optioneel] [-Beheerder]
#   beheer.ps1 -Aanvragen                                        openstaande aanmeldingen
#   beheer.ps1 -Goedkeuren lid-xxxxxx [-Controlewoorden "a b c d e f"]   woorden verplicht bij herstel (code kwijt)
#   beheer.ps1 -AutoGoedkeuren                                   nieuwe aanmeldingen van gewone leden (heads, leiders en herstel niet)
#   beheer.ps1 -Verplaats lid-xxxxxx -Project ecom-nationaal     (of -Cel leadgen, en/of -Vak cro) en toegang meteen bijwerken
#   beheer.ps1 -Head lid-xxxxxx -Vak cro                         head van een vak maken (ziet de voortgang van dat vak)
#   beheer.ps1 -Wijzig lid-xxxxxx -Leren verplicht|optioneel
#   beheer.ps1 -Verwijder lid-xxxxxx                             iemand die nooit meedeed eruit halen (bijv. vertrokken)
#   beheer.ps1 -Bijwerken                                        toegang opnieuw berekenen
#   beheer.ps1 -Controleer                                       overzicht: wie ziet wie
#   beheer.ps1 -NieuweGeneratorsleutel                           aparte sleutel voor de lesgenerator (hervatbaar)
#   beheer.ps1 -Migreer -VanMap <map>                            eenmalig: oude beheer-repo (onondertekend) overzetten
#   beheer.ps1 -Exporteer -Bestand <pad>                         noodkopie van de beheergeheimen (voor NordPass), met wachtzin
#   beheer.ps1 -Importeer -Bestand <pad>                         noodkopie terugzetten op een andere laptop of Windows-account
# Rollen: lid (met -Project of -Cel), projectleider (-Project), celleider (-Cel), head (van -Vak, standaard het standaardvak).
# Vakken staan in instellingen.json; zonder -Vak hoort een lid bij het standaardvak (vakgebied).
# Cloudmodus (GitHub Actions in de privé-repo doubleleren-beheer): staat DL_BEHEER_SLEUTEL in de omgeving, dan komen de
# sleutels daaruit en niet uit DPAPI. De cloud keurt alleen gewone leden goed en doet nooit een sleutelwissel.
# Exitcode: 0 = klaar, 2 = er wacht iets op de beheerder (herstel, head/leider, sleutelwissel, vreemde aanvraag), 1 = fout.
param(
    [switch]$Init, [switch]$Uitnodigen, [switch]$Aanvragen, [switch]$AutoGoedkeuren, [string]$Goedkeuren, [switch]$Bijwerken, [switch]$Controleer,
    [string]$Wijzig, [string]$Verplaats, [string]$Head, [string]$Vak, [switch]$Migreer, [string]$VanMap, [switch]$NieuweGeneratorsleutel,
    [string]$Naam, [ValidateSet('lid', 'projectleider', 'celleider', 'head')][string]$Rol = 'lid', [string]$Project, [string]$Cel,
    [string]$Controlewoorden, [switch]$Optioneel, [switch]$Beheerder,
    [ValidateSet('', 'verplicht', 'optioneel')][string]$Leren = '',
    [switch]$Exporteer, [switch]$Importeer, [string]$Bestand,
    [string]$DataMap, [string]$Thuis, [string]$Wachtzin,      # tests: lokale map i.p.v. GitHub, wachtzin zonder vragen
    [switch]$OokOpLaptop,     # -AutoGoedkeuren op de laptop terwijl de cloud het doet (terugval)
    [switch]$HerstelVersie,   # laptop vergeet een te hoge onthouden organogramversie (bijv. na een weggegooide lokale commit)
    [switch]$VulOrganogram, [switch]$Doorvoeren,     # eenmalig het concept-organogram (-Bestand) overnemen; zonder -Doorvoeren alleen tonen
    [string]$Verwijder,       # iemand die nooit heeft meegedaan uit het organogram halen (bijv. vertrokken)
    [switch]$MetKoppeling     # intern (cloud): -AutoGoedkeuren controleerde de koppeling aan een portier-uitnodiging
)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'organisatie', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Utf8 = New-Object Text.UTF8Encoding($false)
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
New-Item -ItemType Directory $Thuis -Force | Out-Null
$geheimPad = Join-Path $Thuis 'beheer.dpapi'
$Cloud = [bool]$env:DL_BEHEER_SLEUTEL
if ($Cloud) {
    if (-not $env:DL_GENERATOR_SLEUTEL) { throw 'Cloudmodus: DL_GENERATOR_SLEUTEL ontbreekt.' }
    $geheim = [pscustomobject]@{ beheerPrive = ($env:DL_BEHEER_SLEUTEL | ConvertFrom-Json); generatorPrive = ($env:DL_GENERATOR_SLEUTEL | ConvertFrom-Json) }
    if ($geheim.beheerPrive.n -eq $geheim.generatorPrive.n) { throw 'Cloudmodus: beheer- en generatorsleutel zijn gelijk.' }
    if (-not ($AutoGoedkeuren -or $Goedkeuren -or $Aanvragen -or $Controleer)) { throw 'Deze actie kan alleen op de laptop van de beheerder.' }
} else { $geheim = Read-DlGeheim $geheimPad }
$script:wacht = 0     # telt wat op de beheerder wacht (exitcode 2)

# Een sleutelwissel begint altijd met opslaan; in de cloud is daar geen veilige plek voor, dus stopt hij dan vóór er iets verandert
function Save-Geheim {
    if ($Cloud) { throw 'In de cloud worden geen beheergeheimen opgeslagen, dus ook geen sleutelwissel: doe dit op de laptop.' }
    # Een hogere organogramversie die een ander proces intussen opsloeg nooit overschrijven
    $op = Read-DlGeheim $geheimPad
    if ($op -and $op.orgVersie -and [int]$op.orgVersie -gt [int]$script:geheim.orgVersie) { $script:geheim | Add-Member -NotePropertyName orgVersie -NotePropertyValue ([int]$op.orgVersie) -Force }
    Save-DlGeheim $geheimPad $script:geheim
}
# Twee sleutels: de beheersleutel (beheerPrive) ondertekent alles onder beheer/; de generatorsleutel (generatorPrive)
# ontsleutelt de generatorkopieën en ondertekent wachtrijen en scorebord. De beheerder heeft beide (voor goedkeuren en
# sleutelwissels); de generator (straks in de cloud) alleen de zijne. Zonder beheerPrive is het nog één gedeelde sleutel.
function BeheerPrive { $p = if ($geheim.beheerPrive) { $geheim.beheerPrive } else { $geheim.generatorPrive }; if (-not $p) { throw 'Geen beheersleutel: draai eerst -Init' }; $p }
function GenPrive { if (-not $geheim.generatorPrive) { throw 'Geen generatorsleutel: draai eerst -Init' }; $geheim.generatorPrive }
function Pub($p) { [pscustomobject]@{ kty = 'RSA'; n = $p.n; e = $p.e } }
function Vertrouwd { Pub (BeheerPrive) }
# Generatorkopie van een datasleutel openen; een kopie van vóór de aparte generatorsleutel opent met de beheersleutel
function Open-GeneratorKopie([string]$Kopie) {
    try { , (Unprotect-DlRsa (GenPrive) (ConvertFrom-B64u $Kopie)) }
    catch { if (-not $geheim.beheerPrive) { throw }; , (Unprotect-DlRsa $geheim.beheerPrive (ConvertFrom-B64u $Kopie)) }
}
. (Join-Path $PSScriptRoot 'kloon.ps1')
$script:kloon = $null
function DataOpslag {
    if ($DataMap) { return (New-DlOpslag -Map $DataMap) }
    # Voorkeur: lokale git-kopie met je git-inlog (geen beheertoken nodig); wijzigingen worden aan het eind gepusht
    $k = Get-DlKloon $Thuis
    if ($k) { Update-DlKloon $k; $script:kloon = $k; return (New-DlOpslag -Map $k) }
    if (-not $geheim.token) { throw 'Geen beheertoken: draai eerst -Init' }
    New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token
}

# Laptop en cloud mogen nooit tegelijk in de data schrijven (git botst, en bij een sleutelwissel kan er data verloren
# gaan). Alleen als instellingen.json een beheerRepo noemt (vanaf het moment dat de cloud goedkeurt):
# - de oude Windows-taak (-AutoGoedkeuren elke minuut) doet dan niets meer; terugval: -AutoGoedkeuren -OokOpLaptop;
# - schrijft de laptop, dan neemt hij een slot (nooit twee laptopprocessen tegelijk), zet de cloud-goedkeuring van deze
#   omgeving uit, wacht tot er geen run meer loopt of wacht, doet het werk in een eigen proces, en zet de cloud daarna
#   altijd weer aan, met één run om op te pakken wat er intussen binnenkwam.
function Get-Gh {
    $g = (Get-Command gh -ErrorAction SilentlyContinue).Source
    if (-not $g) { $g = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\GitHub.cli_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\gh.exe' }
    if (-not (Test-Path $g)) { throw 'GitHub CLI (gh) niet gevonden. Niets gedaan.' }
    $g
}
# Welke omgeving beheert deze laptop met deze Thuis: staging (testdata) of live
function Get-Omgeving {
    $kl = Get-DlKloon $Thuis; if (-not $kl) { return 'live' }
    $ErrorActionPreference = 'Continue'
    if ((git -C $kl remote get-url origin 2>$null) -match 'doubleleren-data-staging') { 'staging' } else { 'live' }
}
$schrijft = $Uitnodigen -or $Goedkeuren -or $AutoGoedkeuren -or $Verplaats -or $Head -or $Wijzig -or $Bijwerken -or $NieuweGeneratorsleutel -or $Migreer -or $HerstelVersie -or ($VulOrganogram -and $Doorvoeren) -or $Verwijder
if (-not $Cloud -and -not $DataMap -and $schrijft -and $inst.beheerRepo -and -not $env:DL_CLOUD_GEPAUZEERD) {
    if ($AutoGoedkeuren -and -not $OokOpLaptop) { return }
    $gh = Get-Gh; $repo = "$($inst.eigenaar)/$($inst.beheerRepo)"; $wf = "goedkeuren-$(Get-Omgeving).yml"
    $slot = New-Object Threading.Mutex($false, 'Global\DoubleLerenBeheer')
    try { $heb = $slot.WaitOne([TimeSpan]::FromMinutes(10)) } catch [Threading.AbandonedMutexException] { $heb = $true }
    if (-not $heb) { throw 'Er draait al ander beheer op deze laptop (10 minuten gewacht). Niets gedaan.' }
    try {
        $ErrorActionPreference = 'Continue'
        & $gh workflow disable $wf --repo $repo 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Kon de cloud-goedkeuring ($repo, $wf) niet pauzeren met gh. Niets gedaan. Staat gh op het account thijsbol2004?" }
        try {
            Start-Sleep -Seconds 3      # een start van vlak vóór het uitzetten moet eerst zichtbaar worden
            for ($i = 0; $i -lt 120; $i++) {      # hooguit 10 minuten wachten op een run die al bezig was of wachtte
                $n = 0; $gelukt = $true
                foreach ($s in 'in_progress', 'queued', 'pending', 'waiting', 'requested') {
                    $r = & $gh run list --repo $repo --workflow $wf --status $s --json databaseId --jq length 2>$null
                    if ($LASTEXITCODE -ne 0) { $gelukt = $false } else { $n += [int]$r }
                }
                if ($gelukt -and $n -eq 0) { break }
                if ($i -eq 0) { Write-Host 'Wacht tot de lopende cloud-goedkeuring klaar is…' }
                Start-Sleep -Seconds 5
            }
            if (-not $gelukt -or $n) { throw 'De cloud-goedkeuring is na 10 minuten nog bezig (of gh gaf geen antwoord). Niets gedaan; probeer het later opnieuw.' }
            $env:DL_CLOUD_GEPAUZEERD = '1'
            $mee = foreach ($p in $PSBoundParameters.GetEnumerator()) { if ($p.Value -is [switch]) { if ($p.Value) { "-$($p.Key)" } } else { "-$($p.Key)"; [string]$p.Value } }
            & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @mee
            $code = $LASTEXITCODE
        } finally {
            & $gh workflow enable $wf --repo $repo 2>$null | Out-Null
            if ($LASTEXITCODE) { Write-Warning "Zet de cloud-goedkeuring zelf weer aan: gh workflow enable $wf --repo $repo" }
            else { & $gh workflow run $wf --repo $repo -f bron=handmatig 2>$null | Out-Null }      # 'kijk' stopt meteen als er niets ligt
        }
    } finally { $slot.ReleaseMutex(); $slot.Dispose() }
    exit $code
}

if ($Init) {
    if ($geheim -and ($geheim.generatorPrive -or $geheim.beheerPrive)) { Write-Host 'Beheersleutel bestaat al.' }
    else {
        $kp = New-DlSleutelpaar 3072
        $script:geheim = [pscustomobject]@{ generatorPrive = $kp.prive; token = $null; rotaties = [pscustomobject]@{} }
        Write-Host "Beheersleutel gemaakt. De privésleutel staat beschermd in $geheimPad"
    }
    if (-not $DataMap) {
        $s = Read-Host 'Plak je beheertoken (wordt niet getoond, Enter = overslaan)' -AsSecureString
        $t = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
        if ($t) { $geheim.token = $t.Trim(); Write-Host 'Token opgeslagen (DPAPI).' }
    }
    Save-Geheim
    $vPad = Join-Path $App 'vertrouwd.json'
    $v = [ordered]@{ v = 1; beheer = (Vertrouwd) }
    [IO.File]::WriteAllText($vPad, ($v | ConvertTo-Json -Depth 4), $Utf8)
    Write-Host "vertrouwd.json bijgewerkt in de app-repo: commit en push die (alleen de beheerder kan dat)."
    return
}

# Noodkopie: alle beheergeheimen (beheer- en generatorsleutel, beheertoken, lopende sleutelwissels) versleuteld met een
# wachtzin (PBKDF2-SHA256 + DL1), los van DPAPI. Zo kan iemand anders het beheer overnemen. Bestand en wachtzin apart bewaren.
if ($Exporteer -or $Importeer) {
    if (-not $Bestand) { throw 'Geef -Bestand' }
    function Read-Wachtzin([string]$Vraag) {
        $s = Read-Host $Vraag -AsSecureString
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    }
    if ($Exporteer) {
        if (-not $geheim) { throw "Geen beheergeheimen in $geheimPad" }
        $w = $Wachtzin
        if (-not $w) {
            $w = Read-Wachtzin 'Kies een wachtzin (minstens 16 tekens, wordt niet getoond)'
            if ($w -cne (Read-Wachtzin 'Nog een keer')) { throw 'De wachtzinnen zijn niet gelijk.' }
        }
        if ($w.Length -lt 16) { throw 'De wachtzin moet minstens 16 tekens hebben.' }
        $zout = Get-DlWillekeurig 16
        $sl = Get-DlSleutelsUitAfgeleid (Get-DlPbkdf2 $w $zout)
        $blob = Protect-Dl $sl 'beheer|noodkopie' $Utf8.GetBytes(($geheim | ConvertTo-Json -Depth 6 -Compress))
        $vf = (Get-DlVingerafdrukHex (Vertrouwd)).Substring(0, 16)
        $kopie = [ordered]@{ v = 1; soort = 'doubleleren-beheer-noodkopie'; gemaakt = (Get-Date).ToString('s'); vingerafdruk = $vf
            salt = (ConvertTo-B64u $zout); iteraties = $script:DlPbkdf2Iteraties; geheim = (ConvertTo-B64u $blob) }
        [IO.File]::WriteAllText($Bestand, ($kopie | ConvertTo-Json), $Utf8)
        Write-Host "Noodkopie gemaakt: $Bestand (beheersleutel $vf…)." -ForegroundColor Green
        Write-Host 'Zet het bestand en de wachtzin als APARTE items in NordPass en wis het bestand daarna van deze laptop.'
    } else {
        if ($geheim) { throw "Er staan al beheergeheimen in $geheimPad. Verplaats dat bestand eerst; overschrijven gebeurt bewust niet." }
        $kopie = Get-Content $Bestand -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($kopie.soort -ne 'doubleleren-beheer-noodkopie' -or [int]$kopie.v -ne 1) { throw 'Dit is geen noodkopie van DoubleLeren.' }
        $it = [int]$kopie.iteraties; if ($it -lt 100000 -or $it -gt 2000000) { throw 'Ongeldig aantal iteraties' }
        $w = $Wachtzin; if (-not $w) { $w = Read-Wachtzin 'Wachtzin van de noodkopie' }
        $sl = Get-DlSleutelsUitAfgeleid (Get-DlPbkdf2 $w (ConvertFrom-B64u $kopie.salt) $it)
        try { $pt = Unprotect-Dl $sl 'beheer|noodkopie' (ConvertFrom-B64u $kopie.geheim) } catch { throw 'Verkeerde wachtzin of aangepast bestand.' }
        $script:geheim = $Utf8.GetString($pt) | ConvertFrom-Json
        Save-Geheim
        Write-Host "Beheergeheimen teruggezet in $geheimPad (beheersleutel $((Get-DlVingerafdrukHex (Vertrouwd)).Substring(0, 16))…)." -ForegroundColor Green
        Write-Host 'Kloon de data-repo daarna in de map data-kloon ernaast (zie beheer\kloon.ps1).'
    }
    return
}

$V = Vertrouwd
if ($Cloud) {
    # Past de sleutel uit de omgeving bij deze omgeving? Een verkeerd ingestelde sleutel (bijv. die van staging) stopt hier
    $vt = (Get-Content (Join-Path $App 'vertrouwd.json') -Raw -Encoding UTF8 | ConvertFrom-Json).beheer
    if ($vt.n -ne $V.n -or $vt.e -ne $V.e) { throw 'Cloudmodus: de beheersleutel past niet bij vertrouwd.json (verkeerde omgeving?). Niets gedaan.' }
}
$d = DataOpslag
$org = Read-DlBeheer $d 'organisatie.json' $V
if (-not $org -and $Cloud) { throw 'Cloudmodus: geen organisatie.json gevonden. Niets gedaan.' }
if (-not $org -and -not $Migreer) { $org = Get-Content (Join-Path $App 'sjablonen\organisatie-sjabloon.json') -Raw -Encoding UTF8 | ConvertFrom-Json }

# Versie van het organogram. Iedereen met een token kan een ouder (wel ondertekend) organogram terugzetten; daarmee zou
# een vervangen leider zijn rol terugkrijgen. Daarom stopt elke actie als de versie lager is dan de hoogste die bekend is:
# uit de git-geschiedenis, uit wat de laptop eerder las of schreef, en (straks) van de portier.
# De cloud krijgt de ondergrens van de laptop mee (repo-variabele, zie Publish-OrgVersie): de geschiedenis alleen is te
# herschrijven (force-push; branch protection zit niet in het gratis plan).
$script:orgVersie = [int]$(if ($org -and $org.versie) { $org.versie } else { 0 })
if ($HerstelVersie) {
    if ($Cloud) { throw 'Alleen op de laptop.' }
    if ($script:kloon) { Remove-Item (Join-Path $Thuis 'orgversie-cache.json') -ErrorAction SilentlyContinue }
    $geheim | Add-Member -NotePropertyName orgVersie -NotePropertyValue $script:orgVersie -Force; Save-DlGeheim $geheimPad $geheim
    Write-Host "Onthouden organogramversie teruggezet naar $($script:orgVersie) (de versie die nu op GitHub staat). De geschiedenis telt nog steeds mee." -ForegroundColor Green
    return
}
$script:hoogste = [int]$(if ($geheim -and $geheim.orgVersie) { $geheim.orgVersie } else { 0 })
if ($script:kloon) { $script:hoogste = [Math]::Max($script:hoogste, (Get-DlHoogsteOrgVersie $script:kloon $V 'HEAD' $(if (-not $Cloud) { Join-Path $Thuis 'orgversie-cache.json' }))) }
if ($env:DL_ORG_VERSIE_MIN) { $script:hoogste = [Math]::Max($script:hoogste, [int]$env:DL_ORG_VERSIE_MIN) }
# Portier (fase 2): staat DL_PORTIER (adres) met DL_PORTIER_GEHEIM in de omgeving, dan haalt het script daar de stand op:
# nieuwe collega's, de koppelingen van aanmeldingen aan uitnodigingen, en de hoogste organogramversie die de portier zag.
function Invoke-Portier([string]$Methode, [string]$Pad, $Body) {
    $p = @{ Uri = "$($env:DL_PORTIER)$Pad"; Method = $Methode; Headers = @{ Authorization = "Bearer $env:DL_PORTIER_GEHEIM" }; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
    Invoke-RestMethod @p
}
$script:stand = $null; $script:naPush = @()      # naPush: meldingen aan de portier die pas mogen na een geslaagde push
if ($env:DL_PORTIER -and -not $Migreer) {
    if (-not $env:DL_PORTIER_GEHEIM) { throw 'DL_PORTIER staat ingesteld, maar DL_PORTIER_GEHEIM ontbreekt.' }
    $script:stand = Invoke-Portier 'GET' '/stand' $null
    $script:hoogste = [Math]::Max($script:hoogste, [int]$script:stand.orgversie)
}
if (-not $Migreer -and $script:orgVersie -lt $script:hoogste) {
    throw "Het organogram is teruggezet naar een oudere versie ($($script:orgVersie); bekend is $($script:hoogste)). Niets gedaan: zet eerst de nieuwste versie terug."
}
# De portier hoort de hoogste versie die hier bekend is (ook van wijzigingen op de laptop), zodat hij een teruggezet
# organogram ook weigert
if ($script:stand -and [Math]::Max($script:orgVersie, $script:hoogste) -gt [int]$script:stand.orgversie) { Invoke-Portier 'POST' '/orgversie' @{ versie = [Math]::Max($script:orgVersie, $script:hoogste) } | Out-Null }
# Onthouden wat er al op GitHub staat (de laptop): pas als het echt verstuurd is, anders kan een mislukte push of een
# weggegooide lokale commit alles blokkeren. Leest de beheergeheimen opnieuw in, zodat niets van een ander proces verdwijnt.
function Save-OrgVersie([int]$Versie) {
    if ($Cloud -or -not $script:geheim) { return }
    $op = Read-DlGeheim $geheimPad; if (-not $op -or ($op.orgVersie -and [int]$op.orgVersie -ge $Versie)) { return }
    $op | Add-Member -NotePropertyName orgVersie -NotePropertyValue $Versie -Force; Save-DlGeheim $geheimPad $op
    $script:geheim | Add-Member -NotePropertyName orgVersie -NotePropertyValue $Versie -Force
}
# De laptop zet de bekende versie ook in doubleleren-beheer, als ondergrens voor de cloud
function Publish-OrgVersie([int]$Versie) {
    if ($Cloud -or $DataMap -or -not $inst.beheerRepo) { return }
    $ErrorActionPreference = 'Continue'
    $naam = if ((Get-Omgeving) -eq 'staging') { 'STAGING_ORG_VERSIE' } else { 'DL_ORG_VERSIE' }
    & (Get-Gh) variable set $naam --body $Versie --repo "$($inst.eigenaar)/$($inst.beheerRepo)" 2>$null | Out-Null
    if ($LASTEXITCODE) { Write-Warning "Kon $naam niet bijwerken in $($inst.beheerRepo); de cloud valt terug op de git-geschiedenis." }
}
if (-not $script:kloon -or (Test-DlKloonVerstuurd $script:kloon)) { Save-OrgVersie $script:orgVersie }

$standaardVak = [string]$inst.vakgebied
$vakIds = @($(if ($inst.vakken) { $inst.vakken.id } else { $standaardVak }))
if ($Vak -and $vakIds -notcontains $Vak) { throw "Onbekend vak '$Vak' ($($vakIds -join ', '))" }
# Een onderwerp (bijv. Coderen met AI) kun je leren, maar het is niemands eigen vak; een groep (Base) wel, zonder lessen
if ($Vak -and @($inst.vakken | Where-Object { $_.id -eq $Vak -and $_.soort -eq 'onderwerp' }).Count) { throw "'$Vak' is een onderwerp om te leren, geen eigen vak. Kies een discipline of groep." }
if ($org -and -not $org.vakgebied) { $org | Add-Member -NotePropertyName vakgebied -NotePropertyValue $standaardVak -Force }
# Head van een vak vastleggen: het standaardvak in head (zoals altijd), andere vakken in heads.<vak>
# (let op: geen variabele $v, PowerShell ziet die als $V, de beheersleutel)
function Set-Head([string]$id, [string]$welkVak) {
    if (-not $welkVak -or $welkVak -eq $org.vakgebied) { $org.head = $id; return }
    if (-not $org.heads) { $org | Add-Member -NotePropertyName heads -NotePropertyValue ([pscustomobject]@{}) -Force }
    $org.heads | Add-Member -NotePropertyName $welkVak -NotePropertyValue $id -Force
}
function Set-LidVak($l, [string]$welkVak) {
    if (-not $welkVak) { return }
    if ($welkVak -eq $org.vakgebied) { $l.PSObject.Properties.Remove('vak') } else { $l | Add-Member -NotePropertyName vak -NotePropertyValue $welkVak -Force }
}

function Save-Org {
    $script:orgVersie = [Math]::Max($script:orgVersie, $script:hoogste) + 1
    $script:org | Add-Member -NotePropertyName versie -NotePropertyValue $script:orgVersie -Force
    Write-DlBeheer $d 'organisatie.json' $script:org (BeheerPrive)
    if (-not $script:kloon) { Save-OrgVersie $script:orgVersie }      # zonder git-kopie staat het meteen op GitHub
}
# Goedgekeurd in het (ondertekende) organogram: wie al eens is goedgekeurd, kan zich alleen opnieuw aanmelden via herstel
# met controlewoorden. Op sleutels/ en toegang/ kun je hier niet bouwen: die kan iedereen met een token wissen.
function Test-Goedgekeurd([string]$id) { [bool]$org.leden.$id.goedgekeurd }
function Set-Goedgekeurd([string]$id) {
    if (Test-Goedgekeurd $id) { return $false }
    $org.leden.$id | Add-Member -NotePropertyName goedgekeurd -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd') -Force; $true
}
function Naam($id) { if ($id -eq 'generator') { return 'generator' }; $n = $org.leden.$id.naam; if ($n) { "$n ($id)" } else { $id } }
function PubVan($id) { if ($id -eq 'generator') { return (Pub (GenPrive)) }; $s = Read-DlBeheer $d "sleutels/$id.json" $V; if ($s) { $s.publiek } }

# Toegang: de DK verpakt voor elke kijker met een goedgekeurde sleutel, plus de vingerafdruk van die sleutel
function New-Toegang([string]$id, [byte[]]$dk, [int]$versie) {
    $kop = [ordered]@{}; $vf = [ordered]@{}
    foreach ($k in @(Get-DlKijkers $org $id)) {
        $pub = PubVan $k; if (-not $pub) { continue }
        $kop[$k] = ConvertTo-B64u (Protect-DlRsa $pub $dk); $vf[$k] = Get-DlVingerafdrukHex $pub
    }
    [ordered]@{ v = 2; versie = $versie; kopieen = $kop; vingerafdrukken = $vf }
}
function Write-Toegang([string]$id, $t) { Write-DlBeheer $d "toegang/$id.json" $t (BeheerPrive) }

# Sleutelwissel, hervatbaar: de nieuwe DK staat eerst veilig in de beheergeheimen, daarna wordt alles omgezet
function Start-Rotatie([string]$id, [byte[]]$oudDk) {
    if (-not $geheim.rotaties) { $geheim | Add-Member -NotePropertyName rotaties -NotePropertyValue ([pscustomobject]@{}) -Force }
    $geheim.rotaties | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ oud = (ConvertTo-B64u $oudDk); nieuw = (ConvertTo-B64u (Get-DlWillekeurig 32)) }) -Force
    Save-Geheim
}
function Complete-Rotatie([string]$id) {
    $r = $geheim.rotaties.$id
    $oud = Get-DlSleutelsUitDk (ConvertFrom-B64u $r.oud); $nieuwDk = ConvertFrom-B64u $r.nieuw; $nieuw = Get-DlSleutelsUitDk $nieuwDk
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
    $oudT = Read-DlBeheer $d "toegang/$id.json" $V
    Write-Toegang $id (New-Toegang $id $nieuwDk ([int]$(if ($oudT) { $oudT.versie } else { 0 }) + 1))
    & $zet      # wat een laptop tijdens de wissel nog met de oude sleutel schreef
    # Met een git-kopie staat de nieuwe sleutel pas veilig op GitHub na de push: tot dan blijft de wissel bewaard (en hervatbaar)
    if ($script:kloon) { $script:rotatiesNaPush += $id } else { $geheim.rotaties.PSObject.Properties.Remove($id); Save-Geheim }
}
$script:rotatiesNaPush = @()

if ($Migreer) {
    if (-not $VanMap -or -not (Test-Path (Join-Path $VanMap 'organisatie.json'))) { throw 'Geef -VanMap met de oude beheer-repo (met organisatie.json)' }
    $script:org = Get-Content (Join-Path $VanMap 'organisatie.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Save-Org
    foreach ($soort in 'sleutels', 'toegang') {
        foreach ($f in Get-ChildItem (Join-Path $VanMap $soort) -Filter 'lid-*.json' -ErrorAction SilentlyContinue) {
            Write-DlBeheer $d "$soort/$($f.Name)" ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json) (BeheerPrive)
            Write-Host "  $soort/$($f.Name) overgezet en ondertekend"
        }
    }
    Write-Host "Organogram met $(@($org.leden.PSObject.Properties).Count) leden overgezet."
}

elseif ($NieuweGeneratorsleutel) {
    # Hervatbaar: de nieuwe sleutel staat eerst veilig in de beheergeheimen; daarna per lid alleen de generatorkopie van
    # de datasleutel opnieuw verpakt (de oude generatorsleutel was de beheersleutel zelf, dus geen datasleutel-wissel nodig).
    if (-not $geheim.beheerPrive) { $geheim | Add-Member -NotePropertyName beheerPrive -NotePropertyValue $geheim.generatorPrive -Force; Save-Geheim }
    $actief = $geheim.generatorPrive.n -ne $geheim.beheerPrive.n -and -not $geheim.generatorNieuw
    if ($actief) { Write-Host 'De aparte generatorsleutel is al actief; er is niets veranderd.' }
}
if ($NieuweGeneratorsleutel -and -not $actief) {
    if (-not $geheim.generatorNieuw) {
        $kp = New-DlSleutelpaar 3072; while (-not (Test-DlSleutelVorm $kp.publiek)) { $kp = New-DlSleutelpaar 3072 }
        $geheim | Add-Member -NotePropertyName generatorNieuw -NotePropertyValue $kp.prive -Force; Save-Geheim
    }
    $nieuwPub = Pub $geheim.generatorNieuw; $vf = Get-DlVingerafdrukHex $nieuwPub
    foreach ($id in @($org.leden.PSObject.Properties.Name)) {
        $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t -or -not $t.kopieen.generator) { continue }
        if ($t.vingerafdrukken.generator -eq $vf) { continue }                       # al omgezet
        $dk = Open-GeneratorKopie $t.kopieen.generator
        $kop = [ordered]@{}; foreach ($p in $t.kopieen.PSObject.Properties) { $kop[$p.Name] = $p.Value }
        $vfs = [ordered]@{}; foreach ($p in $t.vingerafdrukken.PSObject.Properties) { $vfs[$p.Name] = $p.Value }
        $kop.generator = ConvertTo-B64u (Protect-DlRsa $nieuwPub $dk); $vfs.generator = $vf
        Write-Toegang $id ([ordered]@{ v = 2; versie = $t.versie; kopieen = $kop; vingerafdrukken = $vfs })
        Write-Host "  $(Naam $id): generatorkopie omgezet"
    }
    Write-DlBeheer $d 'generator.json' ([ordered]@{ v = 1; publiek = $nieuwPub; sinds = (Get-Date).ToString('s') }) (BeheerPrive)
    $geheim.generatorPrive = $geheim.generatorNieuw; $geheim.PSObject.Properties.Remove('generatorNieuw'); Save-Geheim
    Write-Host "Aparte generatorsleutel actief (vingerafdruk $($vf.Substring(0, 16))…). De beheersleutel en vertrouwd.json blijven gelijk." -ForegroundColor Green
}

elseif ($Uitnodigen) {
    if (-not $Naam) { throw 'Geef -Naam' }
    $id = 'lid-' + (-join ((Get-DlWillekeurig 3) | ForEach-Object { $_.ToString('x2') }))
    $lid = [ordered]@{ naam = $Naam }
    $alleProjecten = @($org.cellen | ForEach-Object { $_.projecten })
    switch ($Rol) {
        'head' { Set-Head $id $Vak }
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
    if ($Vak -and $Vak -ne $org.vakgebied) { $lid.vak = $Vak }
    if ($Optioneel) { $lid.leren = 'optioneel' }
    if ($Beheerder) { $org.beheerders = @(@($org.beheerders) + $id | Where-Object { $_ }) }
    $org.leden | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]$lid)
    Save-Org
    Write-Host "Uitnodiging voor $Naam ($id, $Rol$(if ($Vak) { ", $Vak" })$(if ($Optioneel) { ', lessen optioneel' }))" -ForegroundColor Green
    $url = 'https://github.com/settings/personal-access-tokens/new?name=' + [Uri]::EscapeDataString("DoubleLeren $Naam") + '&description=' + [Uri]::EscapeDataString("DoubleLeren $id") + "&target_name=$($inst.eigenaar)&contents=write"
    Write-Host "1. Token maken (vooraf ingevuld; kies bij Repository access alleen $($inst.dataRepo)):"
    Write-Host "   $url"
    Write-Host "2. Stuur via Teams: https://$($inst.eigenaar).github.io/$($inst.appRepo)/#welkom  met uitnodigingscode  $id`:<token>"
    $Bijwerken = $true      # vervangt de nieuwe rol een goedgekeurde leider of head, dan meteen de sleutelwissel (hier op de laptop)
}

elseif ($VulOrganogram) {
    # Eenmalig het concept-organogram overnemen (zie plan, onderdeel F). Zonder -Doorvoeren alleen tonen wat er gebeurt.
    #   nieuwe mensen (zonder id) erbij met het label 'uitgenodigd: false', volledige namen bij wie nu alleen een voornaam
    #   heeft, rollen op lege plekken of bij iemand zonder sleutel, en het label bij iedereen die nog niet meedoet.
    #   Nooit: een goedgekeurde leider of head vervangen (sleutelwissel), of iemand verplaatsen (dat blijft -Verplaats).
    if ($Cloud) { throw 'Alleen op de laptop.' }
    if (-not $Bestand -or -not (Test-Path $Bestand)) { throw 'Geef -Bestand met het concept-organogram (organogram-concept.json)' }
    $concept = Get-Content $Bestand -Raw -Encoding UTF8 | ConvertFrom-Json
    $alleProjecten = @($org.cellen | ForEach-Object { $_.projecten })
    $onderwerpen = @($inst.vakken | Where-Object { $_.soort -eq 'onderwerp' } | ForEach-Object { $_.id })
    # 'Doet mee' = een sleutel óf de markering goedgekeurd (een gewist sleutelbestand mag een leider niet vervangbaar maken)
    $heeftSleutel = @{}; foreach ($lidId in @($org.leden.PSObject.Properties.Name)) { $heeftSleutel[$lidId] = [bool]$org.leden.$lidId.goedgekeurd -or [bool](Read-DlBeheer $d "sleutels/$lidId.json" $V) }
    $acties = New-Object Collections.Generic.List[string]; $verschillen = New-Object Collections.Generic.List[string]
    $naarId = @{}; $idsTerug = @{}
    # 1. Leden
    foreach ($c in @($concept.leden)) {
        $cNaam = [string]$c.naam
        $vakC = if ($c.vak) { [string]$c.vak } else { [string]$org.vakgebied }
        if ($vakIds -notcontains $vakC -or $onderwerpen -contains $vakC) { $verschillen.Add("$($cNaam): onbekend vak '$vakC', overgeslagen"); continue }
        $plek = [string]$c.plek
        $proj = $null; $celC = $null
        if ($plek -like 'cel:*') { $celC = $plek.Substring(4); if (-not @($org.cellen | Where-Object id -eq $celC).Count) { $verschillen.Add("$($cNaam): onbekende cel '$celC', overgeslagen"); continue } }
        elseif ($plek -and $plek -ne 'base') { $proj = $plek; if (-not @($alleProjecten | Where-Object id -eq $proj).Count) { $verschillen.Add("$($cNaam): onbekend project '$proj', overgeslagen"); continue } }
        if ($naarId.ContainsKey($cNaam)) { $verschillen.Add("$($cNaam): staat twee keer in het concept, overgeslagen"); continue }
        # Zonder id, maar staat hij al in het organogram (volledige naam, of een unieke voornaam)? Dan dat lid, geen nieuw lid
        if (-not $c.id) {
            $gebruikt = @($naarId.Values)
            $zelfde = @($org.leden.PSObject.Properties | Where-Object { $gebruikt -notcontains $_.Name -and ([string]$_.Value.naam -eq $cNaam -or ($cNaam -like "$([string]$_.Value.naam) *" -and [string]$_.Value.naam)) })
            if ($zelfde.Count -eq 1) { $c | Add-Member -NotePropertyName id -NotePropertyValue $zelfde[0].Name -Force; $idsTerug[$cNaam] = $zelfde[0].Name; $verschillen.Add("$($cNaam): had geen id in het concept; gekoppeld aan bestaand lid $(Naam $zelfde[0].Name)") }
            elseif ($zelfde.Count -gt 1) { $verschillen.Add("$($cNaam): lijkt op meerdere leden ($(($zelfde | ForEach-Object { Naam $_.Name }) -join ', ')), overgeslagen; zet het id in het concept"); continue }
        }
        if ($c.id) {
            $lid = $org.leden.($c.id); if (-not $lid) { $verschillen.Add("$($cNaam): id $($c.id) staat niet in het organogram, overgeslagen"); continue }
            $naarId[$cNaam] = [string]$c.id
            if ([string]$lid.naam -ne $cNaam -and $cNaam.StartsWith([string]$lid.naam)) { $acties.Add("Naam: $($lid.naam) wordt $cNaam"); $lid | Add-Member -NotePropertyName naam -NotePropertyValue $cNaam -Force }
            $plekNu = if ($lid.project) { [string]$lid.project } elseif ($lid.cel) { "cel:$($lid.cel)" } else { '' }
            $plekConcept = if ($proj) { $proj } elseif ($celC) { "cel:$celC" } else { '' }
            if ($plekNu -ne $plekConcept) { $verschillen.Add("$($cNaam): plek in het organogram '$plekNu', in het concept '$plekConcept' (niet aangepast; gebruik -Verplaats)") }
            if ((Get-DlVakVanLid $org $c.id) -ne $vakC) { $verschillen.Add("$($cNaam): vak in het organogram '$(Get-DlVakVanLid $org $c.id)', in het concept '$vakC' (niet aangepast; gebruik -Verplaats -Vak)") }
        } else {
            do { $nid = 'lid-' + (-join ((Get-DlWillekeurig 3) | ForEach-Object { $_.ToString('x2') })) } while ($org.leden.$nid)
            $nieuwLid = [ordered]@{ naam = $cNaam; uitgenodigd = $false }
            if ($proj) { $nieuwLid.project = $proj } elseif ($celC) { $nieuwLid.cel = $celC }
            if ($vakC -ne $org.vakgebied) { $nieuwLid.vak = $vakC }
            $org.leden | Add-Member -NotePropertyName $nid -NotePropertyValue ([pscustomobject]$nieuwLid)
            $naarId[$cNaam] = $nid; $idsTerug[$cNaam] = $nid; $heeftSleutel[$nid] = $false
            $acties.Add("Nieuw: $cNaam ($nid, $(if ($proj) { $proj } elseif ($celC) { "cel $celC" } else { 'geen plek' }), $vakC)")
        }
    }
    # 2. Rollen: alleen op een lege plek of bij iemand zonder sleutel; nooit een goedgekeurde leider of head vervangen
    function Set-ConceptRol([string]$Soort, [string]$Waar, [string]$Naam, $Nu, [scriptblock]$Zet) {
        if (-not $naarId.ContainsKey($Naam)) { $verschillen.Add("$Soort ${Waar}: '$Naam' staat niet (goed) in het concept"); return }
        $nieuwId = $naarId[$Naam]
        if ($Nu -eq $nieuwId) { return }
        if ($Nu -and $heeftSleutel[$Nu]) { $verschillen.Add("$Soort ${Waar}: nu $(Naam $Nu), in het concept $Naam. Niet vervangen: $(Naam $Nu) doet al mee (sleutelwissel, doe dit apart)"); return }
        & $Zet $nieuwId
        $acties.Add("$Soort ${Waar}: $Naam$(if ($Nu) { " (in plaats van $(Naam $Nu), die nog niet meedoet)" })")
    }
    foreach ($p in @($(if ($concept.heads) { $concept.heads.PSObject.Properties }))) {
        if ($vakIds -notcontains $p.Name) { $verschillen.Add("Head: onbekend vak '$($p.Name)'"); continue }
        $vakH = $p.Name; Set-ConceptRol 'Head' $vakH ([string]$p.Value) (Get-DlHeadVanVak $org $vakH) { param($x) Set-Head $x $vakH }
    }
    foreach ($p in @($(if ($concept.celleiders) { $concept.celleiders.PSObject.Properties }))) {
        $celObj = @($org.cellen | Where-Object id -eq $p.Name)[0]; if (-not $celObj) { $verschillen.Add("Celleider: onbekende cel '$($p.Name)'"); continue }
        Set-ConceptRol 'Celleider' $p.Name ([string]$p.Value) $celObj.leider { param($x) $celObj.leider = $x }
    }
    foreach ($p in @($(if ($concept.projectleiders) { $concept.projectleiders.PSObject.Properties }))) {
        $pr = @($alleProjecten | Where-Object id -eq $p.Name)[0]; if (-not $pr) { $verschillen.Add("Projectleider: onbekend project '$($p.Name)'"); continue }
        Set-ConceptRol 'Projectleider' $p.Name ([string]$p.Value) $pr.leider { param($x) $pr.leider = $x }
    }
    # 3. Label bij iedereen die nog niet meedoet: alleen goedkeuren met een uitnodiging van de portier (of door de beheerder)
    $label = @($org.leden.PSObject.Properties | Where-Object { -not $heeftSleutel[$_.Name] -and -not $_.Value.goedgekeurd -and $_.Value.uitgenodigd -ne $false })
    foreach ($l in $label) { $l.Value | Add-Member -NotePropertyName uitgenodigd -NotePropertyValue $false -Force }
    if ($label.Count) { $acties.Add("Label 'nog niet uitgenodigd' bij $($label.Count) bestaande deelnemer(s) die nog niet meedoen: $(($label | ForEach-Object { Naam $_.Name }) -join ', ')") }
    Write-Host "Acties ($($acties.Count)):" -ForegroundColor Green; $acties | ForEach-Object { Write-Host "  $_" }
    Write-Host "Verschillen die je zelf moet bekijken ($($verschillen.Count)):" -ForegroundColor Yellow; $verschillen | ForEach-Object { Write-Host "  $_" }
    if (-not $Doorvoeren) { Write-Host "`nNiets gewijzigd. Draai opnieuw met -Doorvoeren om de acties uit te voeren."; return }
    if (-not $acties.Count) { Write-Host 'Niets te doen.'; return }
    Save-Org
    # Nieuwe ids terug in het concept (met een kopie van het oude bestand ernaast)
    if ($idsTerug.Count) {
        Copy-Item $Bestand "$Bestand.voor-vullen-$(Get-Date -Format yyyyMMdd-HHmm)"
        foreach ($c in @($concept.leden)) { if ($idsTerug.ContainsKey([string]$c.naam)) { $c | Add-Member -NotePropertyName id -NotePropertyValue $idsTerug[[string]$c.naam] -Force } }
        [IO.File]::WriteAllText($Bestand, ($concept | ConvertTo-Json -Depth 8), $Utf8)
    }
    Write-Host "Organogram bijgewerkt ($($acties.Count) acties)." -ForegroundColor Green
    $Bijwerken = $true
}

elseif ($Verplaats) {
    $l = $org.leden.$Verplaats; if (-not $l) { throw "Onbekend: $Verplaats" }
    if ($Project) {
        if (-not @($org.cellen | ForEach-Object { $_.projecten } | Where-Object id -eq $Project).Count) { throw "Onbekend project '$Project'" }
        $l | Add-Member -NotePropertyName project -NotePropertyValue $Project -Force; $l.PSObject.Properties.Remove('cel')
    } elseif ($Cel) {
        if (-not @($org.cellen | Where-Object id -eq $Cel).Count) { throw "Onbekende cel '$Cel'" }
        $l | Add-Member -NotePropertyName cel -NotePropertyValue $Cel -Force; $l.PSObject.Properties.Remove('project')
    } elseif (-not $Vak) { throw 'Geef -Project, -Cel en/of -Vak' }
    Set-LidVak $l $Vak
    Save-Org
    Write-Host "$(Naam $Verplaats) verplaatst$(if ($Vak) { " (vak $Vak)" })."
    $Bijwerken = $true
}

elseif ($Head) {
    if (-not $org.leden.$Head) { throw "Onbekend: $Head" }
    $headVak = if ($Vak) { $Vak } else { $org.vakgebied }
    Set-Head $Head $headVak
    Save-Org
    Write-Host "$(Naam $Head) is nu head van $headVak."
    $Bijwerken = $true
}

elseif ($Wijzig) {
    if (-not $org.leden.$Wijzig) { throw "Onbekend: $Wijzig" }
    if (-not $Leren) { throw 'Geef -Leren verplicht of -Leren optioneel' }
    $org.leden.$Wijzig | Add-Member -NotePropertyName leren -NotePropertyValue $Leren -Force
    Save-Org
    Write-Host "$(Naam $Wijzig): lessen $Leren. De pop-up en website pakken het bij de volgende start op."
}

elseif ($Verwijder) {
    # Alleen wie nooit heeft meegedaan (geen sleutel, nooit goedgekeurd): dan is er geen data en geen toegang om op te ruimen.
    # Wie wel meedeed, eerst via Actions -> Toegang intrekken; dat vraagt een sleutelwissel en blijft handwerk.
    if (-not $org.leden.$Verwijder) { throw "Onbekend: $Verwijder" }
    if ((Test-Goedgekeurd $Verwijder) -or (Read-DlBeheer $d "sleutels/$Verwijder.json" $V)) { throw "$(Naam $Verwijder) doet al mee: trek eerst de toegang in (Actions -> Toegang intrekken)." }
    $wie = Naam $Verwijder
    foreach ($c in @($org.cellen)) { if ($c.leider -eq $Verwijder) { $c.leider = $null }; foreach ($p in @($c.projecten)) { if ($p.leider -eq $Verwijder) { $p.leider = $null } } }
    if ($org.head -eq $Verwijder) { $org.head = $null }
    foreach ($h in @($(if ($org.heads) { $org.heads.PSObject.Properties }))) { if ($h.Value -eq $Verwijder) { $org.heads.PSObject.Properties.Remove($h.Name) } }
    $org.leden.PSObject.Properties.Remove($Verwijder)
    Save-Org
    $ab = Read-DlOpslag $d "aanvragen/$Verwijder.json"; if ($ab) { Remove-DlOpslag $d "aanvragen/$Verwijder.json" $ab.sha }
    Write-Host "$wie uit het organogram gehaald. Trek ook zijn uitnodigingstoken in op GitHub (Settings -> Personal access tokens)."
}

elseif ($Aanvragen) {
    $lijst = @(Get-DlOpslagLijst $d 'aanvragen')
    if (-not $lijst.Count) { Write-Host 'Geen openstaande aanvragen.' }
    foreach ($f in $lijst) {
        $a = Read-DlJson $d "aanvragen/$f"
        $vorm = if (Test-DlSleutelVorm $a.publiek) { '' } else { '  (ONGELDIGE SLEUTEL)' }
        Write-Host ("{0,-28} {1}{2}  controlewoorden: {3}" -f (Naam $a.id), $(if ($a.herstel) { 'herstel ' } else { '' }), $vorm, (Get-DlControlewoorden $a))
    }
}

elseif ($AutoGoedkeuren) {
    # Leeftijd van een aanvraag in dagen: uit git (of het bestand), niet uit het veld 'aangevraagd' (dat kiest de aanvrager zelf)
    function Get-AanvraagLeeftijd([string]$Bestand) {
        if ($script:kloon) { $ErrorActionPreference = 'Continue'; $t = git -C $script:kloon log -1 --format=%ct -- "aanvragen/$Bestand" 2>$null; if ($t -match '^\d+$') { return ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$t) / 86400 } }
        if ($DataMap) { $pad = Join-Path $DataMap "aanvragen\$Bestand"; if (Test-Path $pad) { return ((Get-Date) - (Get-Item $pad).LastWriteTime).TotalDays } }
        0
    }
    # Nieuwe aanmeldingen van gewone leden zonder controlewoorden goedkeuren: het wachtwoord van zes woorden is genoeg.
    # Handwerk blijft: "code kwijt" (herstel, met controlewoorden), en heads, leiders en beheerders (die zien anderen;
    # de beheerder keurt hen zelf goed, zodat niemand met een token zich als een nieuwe leider kan aanmelden).
    $lijst = @(Get-DlOpslagLijst $d 'aanvragen')
    # Eenmalig: wie al een (door de beheerder ondertekende) sleutel heeft, krijgt de markering 'goedgekeurd'.
    # Meteen versturen: de kindprocessen hieronder werken in dezelfde git-kopie.
    $nieuw = @(foreach ($id in @($org.leden.PSObject.Properties.Name)) { if (-not (Test-Goedgekeurd $id) -and (Read-DlBeheer $d "sleutels/$id.json" $V)) { $id } })
    if ($nieuw.Count) {
        foreach ($id in $nieuw) { Set-Goedgekeurd $id | Out-Null }
        Save-Org; Write-Host "Markering 'goedgekeurd' gezet bij $($nieuw.Count) bestaande deelnemer(s)."
        if ($script:kloon) { Push-DlKloon $script:kloon; Save-OrgVersie $script:orgVersie }
    }
    # Nieuwe collega's die een head of leider via de portier toevoegde: opnieuw controleren met het organogram van nu en
    # toevoegen met het label 'uitgenodigd: false' (dan alleen goedkeuren met een koppeling aan de uitnodigingscode).
    # Meteen versturen, net als de markering hierboven. Pas daarna de portier laten weten dat het verwerkt is.
    if ($script:stand) {
        $verwerkt = @(); $geweigerd = @(); $erbij = 0
        $onderwerpen = @($inst.vakken | Where-Object { $_.soort -eq 'onderwerp' } | ForEach-Object { $_.id })
        foreach ($p in @($(if ($script:stand.nieuw) { $script:stand.nieuw.PSObject.Properties }))) {
            $nid = $p.Name; $verzoek = $p.Value; $nl = $verzoek.lid
            if ($org.leden.$nid) {
                # Een eerdere run zette hem er al in (zelfde naam); anders is het id al van een ander: weigeren
                if ([string]$org.leden.$nid.naam -eq [string]$nl.naam) { $verwerkt += $nid } else { Write-Host "Nieuwe collega $nid geweigerd: het id is al van $(Naam $nid)"; $script:wacht++; $geweigerd += $nid }
                continue
            }
            $vakNieuw = if ($nl.vak) { [string]$nl.vak } else { [string]$org.vakgebied }
            $reden = $null
            if ($nid -cnotmatch '^lid-[0-9a-f]{6}$') { $reden = 'ongeldig id' }
            elseif (-not $nl -or [string]$nl.naam -notmatch '^[^\x00-\x1f<>"\\]{2,60}$') { $reden = 'ongeldige naam' }
            elseif ($vakIds -notcontains $vakNieuw -or $onderwerpen -contains $vakNieuw) { $reden = "onbekend vak '$vakNieuw'" }
            elseif ($nl.project -and -not @($org.cellen | ForEach-Object { $_.projecten } | Where-Object id -eq $nl.project).Count) { $reden = "onbekend project '$($nl.project)'" }
            elseif ($nl.cel -and -not @($org.cellen | Where-Object id -eq $nl.cel).Count) { $reden = "onbekende cel '$($nl.cel)'" }
            elseif (-not (Test-DlMagToevoegen $org ([string]$verzoek.door) ([string]$nl.project) ([string]$nl.cel) $vakNieuw)) { $reden = "$(Naam $verzoek.door) mag daar geen collega toevoegen" }
            elseif ((Read-DlOpslag $d "beheer/sleutels/$nid.json") -or (Read-DlOpslag $d "beheer/toegang/$nid.json") -or @(Get-DlOpslagLijst $d "data/$nid").Count) { $reden = 'het id is niet vrij' }
            if ($reden) { Write-Host "Nieuwe collega $nid geweigerd: $reden"; $script:wacht++; $geweigerd += $nid; continue }
            $nieuwLid = [ordered]@{ naam = [string]$nl.naam; uitgenodigd = $false }
            if ($nl.project) { $nieuwLid.project = [string]$nl.project } elseif ($nl.cel) { $nieuwLid.cel = [string]$nl.cel }
            if ($vakNieuw -ne $org.vakgebied) { $nieuwLid.vak = $vakNieuw }
            if ($nl.leren -eq 'optioneel') { $nieuwLid.leren = 'optioneel' }
            $org.leden | Add-Member -NotePropertyName $nid -NotePropertyValue ([pscustomobject]$nieuwLid)
            Write-Host "Nieuwe collega toegevoegd: $($nieuwLid.naam) ($nid), door $(Naam $verzoek.door)"; $erbij++; $verwerkt += $nid
        }
        if ($erbij) { Save-Org }
        # Seintjes opruimen: van wat nu verwerkt is, en oude seintjes waar de portier niets meer van weet
        $open = @($(if ($script:stand.nieuw) { $script:stand.nieuw.PSObject.Properties.Name }))
        foreach ($sf in @(Get-DlOpslagLijst $d 'uitnodigingen')) {
            $sid = $sf -replace '\.json$', ''
            if ($verwerkt -contains $sid -or $geweigerd -contains $sid -or $open -notcontains $sid) { $sb = Read-DlOpslag $d "uitnodigingen/$sf"; if ($sb) { Remove-DlOpslag $d "uitnodigingen/$sf" $sb.sha } }
        }
        if ($script:kloon) { Push-DlKloon $script:kloon; if ($erbij) { Save-OrgVersie $script:orgVersie } }
        foreach ($nid in $verwerkt) { Invoke-Portier 'POST' '/afgehandeld' @{ id = $nid; soort = 'nieuw' } | Out-Null }
        foreach ($nid in $geweigerd) { Invoke-Portier 'POST' '/afgehandeld' @{ id = $nid; soort = 'geweigerd' } | Out-Null }      # de code werkt dan niet meer
        # Op de laptop goedgekeurd (bijv. een head): de portier bijwerken, zodat de uitnodiging niet meer 'open' staat
        foreach ($oid in @($script:stand.open)) { if (Test-Goedgekeurd $oid) { Invoke-Portier 'POST' '/afgehandeld' @{ id = $oid; soort = 'goedgekeurd' } | Out-Null } }
        if ($erbij) { Invoke-Portier 'POST' '/orgversie' @{ versie = $script:orgVersie } | Out-Null }
    }
    $fouten = 0; $wegTeGooien = @()
    foreach ($f in $lijst) {
        try { $a = Read-DlJson $d "aanvragen/$f" } catch { Write-Host "Overgeslagen: $f is geen geldige aanvraag"; $script:wacht++; continue }
        if (-not $a -or $f -ne "$($a.id).json" -or -not $org.leden.($a.id)) { Write-Host "Overgeslagen: $f hoort niet bij een lid uit het organogram"; $script:wacht++; continue }
        if ($a.herstel) { Write-Host "Wacht op handmatige controle (code kwijt): $(Naam $a.id)  controlewoorden: $(Get-DlControlewoorden $a)"; $script:wacht++; continue }
        # Een projectleider die via de portier is uitgenodigd (koppeling aan de code, hieronder gecontroleerd) mag wel
        $plMetBand = (Test-DlAlleenProjectleider $org $a.id) -and $script:stand -and $script:stand.bindingen -and [string]$script:stand.bindingen.($a.id)
        if ((Test-DlRolhouder $org $a.id) -and -not $plMetBand) { Write-Host "Wacht op goedkeuring door de beheerder (head, leider of beheerder): $(Naam $a.id). Op de laptop: beheer.ps1 -Goedkeuren $($a.id)"; $script:wacht++; continue }
        if (Test-Goedgekeurd $a.id) { Write-Host "Geweigerd: $(Naam $a.id) is al eens goedgekeurd; een nieuwe aanmelding kan alleen als herstel met controlewoorden (mogelijk overname)"; $script:wacht++; continue }
        if (Read-DlBeheer $d "sleutels/$($a.id).json" $V) { Write-Host "Overgeslagen: $(Naam $a.id) is al goedgekeurd"; $script:wacht++; continue }
        # Uitgenodigd via de portier (label 'uitgenodigd: false'): alleen goedkeuren als de aanmelding aan de uitnodigingscode
        # gekoppeld is, met precies deze sleutel. Een aanvraag met een andere sleutel (van iemand met alleen een token) gaat
        # weg; zonder koppeling blijft hij liggen (de koppeling kan net onderweg zijn), tot hij ouder is dan 7 dagen.
        # Ook zonder label: staat er bij de portier een open uitnodiging (of een koppeling) voor dit lid, dan geldt hetzelfde.
        $band = if ($script:stand -and $script:stand.bindingen) { [string]$script:stand.bindingen.($a.id) } else { '' }
        if ($org.leden.($a.id).uitgenodigd -eq $false -or $band -or ($script:stand -and @($script:stand.open) -contains $a.id)) {
            $teOud = (Get-AanvraagLeeftijd $f) -gt 7
            if ($band -and $band -ne (Get-DlVingerafdrukHex $a.publiek)) { Write-Host "Weggegooid: de aanvraag voor $(Naam $a.id) hoort niet bij de uitnodiging (andere sleutel)"; $wegTeGooien += $f; continue }
            if (-not $band) {
                if ($teOud) { Write-Host "Weggegooid: aanvraag voor $(Naam $a.id) zonder koppeling aan de uitnodiging, ouder dan 7 dagen"; $wegTeGooien += $f }
                else { Write-Host "Wacht: $(Naam $a.id) is uitgenodigd, maar de aanmelding is (nog) niet aan de uitnodiging gekoppeld" }
                continue
            }
        }
        $extra = @('-Thuis', $Thuis); if ($DataMap) { $extra += @('-DataMap', $DataMap) }
        if ($plMetBand) { $extra += '-MetKoppeling' }
        $voor = if ($script:kloon) { Get-DlKloonCommit $script:kloon }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Goedkeuren $a.id -Controlewoorden (Get-DlControlewoorden $a) @extra
        $code = $LASTEXITCODE
        if ($code -eq 2) { $script:wacht++ }
        elseif ($code) {
            # Wat een mislukt kindproces in de git-kopie achterliet (bijv. een sleutel zonder toegang) nooit meesturen.
            # Terug naar de stand van vlak ervoor, niet naar GitHub: eerder werk dat nog niet verstuurd is, blijft zo bewaard.
            $fouten++; Write-Host "Goedkeuren van $(Naam $a.id) mislukt (exitcode $code); niets daarvan verstuurd."
            if ($script:kloon -and $voor) { Reset-DlKloon $script:kloon $voor }
        }
    }
    # Pas na alle kindprocessen (die werken in dezelfde git-kopie)
    foreach ($f in $wegTeGooien) { $wb = Read-DlOpslag $d "aanvragen/$f"; if ($wb) { Remove-DlOpslag $d "aanvragen/$f" $wb.sha } }
    if ($fouten) { if ($script:kloon) { Push-DlKloon $script:kloon }; exit 1 }
}

elseif ($Goedkeuren) {
    $id = $Goedkeuren
    if (-not $org.leden.$id) { throw "$id staat niet in het organogram: eerst uitnodigen" }
    $a = Read-DlOpslag $d "aanvragen/$id.json"; if (-not $a) { throw "Geen aanvraag voor $id" }
    $aanvraag = $script:DlUtf8.GetString($a.bytes) | ConvertFrom-Json
    if ($aanvraag.id -ne $id) { throw 'Aanvraag hoort bij een ander id' }
    if (-not (Test-DlSleutelVorm $aanvraag.publiek)) { throw 'De sleutel in de aanvraag heeft niet de vaste vorm: niet goedkeuren.' }
    # Controlewoorden zijn verplicht bij herstel (code kwijt). Een nieuwe aanmelding keurt de beheerder ook zonder woorden
    # goed (bijv. een head of leider, die de cloud laat liggen); geef je ze toch mee, dan moeten ze kloppen.
    $echt = Get-DlControlewoorden $aanvraag
    if ($Controlewoorden -or $aanvraag.herstel) {
        $gegeven = (($Controlewoorden.ToLower() -split '[\s,\-]+') | Where-Object { $_ }) -join ' '
        if ($gegeven -ne $echt) { throw "Controlewoorden komen NIET overeen. Niet goedkeuren: vraag $(Naam $id) opnieuw aan te melden en de woorden opnieuw door te geven." }
    }
    if ($Cloud -and $aanvraag.herstel) { throw 'Herstel (code kwijt) kan alleen op de laptop.' }
    if ($Cloud -and (Test-DlRolhouder $org $id) -and -not ($MetKoppeling -and (Test-DlAlleenProjectleider $org $id))) { throw 'Heads, leiders en beheerders keurt de beheerder zelf goed op de laptop.' }
    if (-not $aanvraag.herstel -and (Test-Goedgekeurd $id)) { throw "$(Naam $id) is al eens goedgekeurd ($($org.leden.$id.goedgekeurd)). Een nieuwe aanmelding kan alleen als herstel (code kwijt): mogelijk overname." }
    $sleutelsObj = [ordered]@{ v = 2; id = $id; publiek = $aanvraag.publiek; kluis = $aanvraag.kluis }
    $oudS = Read-DlBeheer $d "sleutels/$id.json" $V
    if ($aanvraag.herstel) {
        $oudT = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $oudT) { throw "Herstel kan niet: $id had nog geen toegang" }
        $oudDk = Open-GeneratorKopie $oudT.kopieen.generator
        $sleutelsObj.eerdere = @(@($oudS.publiek) + @($oudS.eerdere) | Where-Object { $_ })
        Write-DlBeheer $d "sleutels/$id.json" $sleutelsObj (BeheerPrive)
        Start-Rotatie $id $oudDk; Complete-Rotatie $id
    } else {
        if ($oudS) { throw "$id is al goedgekeurd; gebruik herstel" }
        $dk = Open-GeneratorKopie $aanvraag.toegang.generator
        Write-DlBeheer $d "sleutels/$id.json" $sleutelsObj (BeheerPrive)
        if ($env:DL_TEST_FOUT_NA_SLEUTEL -eq $id) { throw 'Testfout na het schrijven van de sleutel (alleen test\cloud-git.ps1)' }
        Write-Toegang $id (New-Toegang $id $dk 1)
    }
    Remove-DlOpslag $d "aanvragen/$id.json" $a.sha
    $labelWeg = $org.leden.$id.uitgenodigd -eq $false
    if ($labelWeg) { $org.leden.$id.PSObject.Properties.Remove('uitgenodigd') }
    if ((Set-Goedgekeurd $id) -or $labelWeg) { Save-Org }
    if ($env:DL_PORTIER) { $script:naPush += @{ id = $id; soort = 'goedgekeurd' } }
    $t = Read-DlBeheer $d "toegang/$id.json" $V
    Write-Host "Goedgekeurd: $(Naam $id). Zichtbaar voor: $((@($t.kopieen.PSObject.Properties.Name) | ForEach-Object { Naam $_ }) -join ', ')" -ForegroundColor Green
    $Bijwerken = $true
}

if ($Bijwerken) {
    # (een wissel die deze run al afrondde, staat tot na de push nog in de geheimen: niet nog een keer)
    foreach ($p in @($(if ($geheim.rotaties) { $geheim.rotaties.PSObject.Properties.Name }) | Where-Object { $_ -and $script:rotatiesNaPush -notcontains $_ })) { Write-Host "Afgebroken sleutelwissel hervatten: $(Naam $p)"; Complete-Rotatie $p }
    foreach ($id in @($org.leden.PSObject.Properties.Name)) {
        $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t) { continue }
        $dk = Open-GeneratorKopie $t.kopieen.generator
        $moet = @(Get-DlKijkers $org $id | Where-Object { PubVan $_ })
        $heeft = @($t.kopieen.PSObject.Properties.Name)
        $weg = @($heeft | Where-Object { $moet -notcontains $_ })
        $erbij = @($moet | Where-Object { $heeft -notcontains $_ })
        $anders = @($moet | Where-Object { $heeft -contains $_ -and $t.vingerafdrukken.$_ -ne (Get-DlVingerafdrukHex (PubVan $_)) })
        if (-not ($weg.Count + $erbij.Count + $anders.Count)) { continue }
        # Sleutelwissel nodig: de cloud laat deze toegang helemaal ongemoeid (ook geen nieuwe kijker erbij), anders ziet de
        # laptop later niet meer dat er gewisseld moet worden en houdt wie weg moest de datasleutel
        if (($weg.Count -or $anders.Count) -and $Cloud) { Write-Host "Sleutelwissel nodig voor $(Naam $id): overgeslagen, draai -Bijwerken op de laptop."; $script:wacht++; continue }
        if ($weg.Count -or $anders.Count) { Start-Rotatie $id $dk; Complete-Rotatie $id }
        else { Write-Toegang $id (New-Toegang $id $dk ([int]$t.versie)) }
        $tekst = @(); if ($erbij.Count) { $tekst += "+ $(($erbij | ForEach-Object { Naam $_ }) -join ', ')" }
        if ($weg.Count) { $tekst += "- $(($weg | ForEach-Object { Naam $_ }) -join ', ')" }
        if ($anders.Count) { $tekst += "nieuwe sleutel: $(($anders | ForEach-Object { Naam $_ }) -join ', ')" }
        Write-Host "$(Naam $id): $($tekst -join '; ')$(if ($weg.Count -or $anders.Count) { ' (datasleutel vernieuwd)' })"
    }
}

if ($Controleer) {
    Write-Host ("{0,-30} {1,-20} {2,-12} {3,-22} {4}" -f 'Deelnemer', 'Rol', 'Vak', 'Project / cel', 'Zichtbaar voor')
    foreach ($id in @($org.leden.PSObject.Properties.Name)) {
        $l = $org.leden.$id; $plek = if ($l.project) { $l.project } elseif ($l.cel) { "cel $($l.cel)" } else { '-' }
        $headVan = @($vakIds | Where-Object { (Get-DlHeadVanVak $org $_) -eq $id })
        $rolTekst = if ($headVan.Count) { "head $($headVan -join '/')" } elseif (@($org.cellen | Where-Object leider -eq $id).Count) { 'celleider' } elseif (@($org.cellen.projecten | Where-Object leider -eq $id).Count) { 'projectleider' } else { 'lid' }
        if ($l.leren -eq 'optioneel') { $rolTekst += ' (opt.)' }
        $t = Read-DlBeheer $d "toegang/$id.json" $V
        $kijkers = if ($t) { @($t.kopieen.PSObject.Properties.Name | Where-Object { $_ -ne $id }) | ForEach-Object { Naam $_ } } else { @('(nog niet goedgekeurd)') }
        Write-Host ("{0,-30} {1,-20} {2,-12} {3,-22} {4}" -f (Naam $id), $rolTekst, (Get-DlVakVanLid $org $id), $plek, ($kijkers -join ', '))
    }
}

if ($script:kloon) {
    Push-DlKloon $script:kloon
    # Pas nu staat alles op GitHub: afgeronde sleutelwissels uit de beheergeheimen halen en de organogramversie onthouden
    if ($script:rotatiesNaPush.Count) { foreach ($p in $script:rotatiesNaPush) { $geheim.rotaties.PSObject.Properties.Remove($p) }; Save-Geheim }
    if (Test-DlKloonVerstuurd $script:kloon) { Save-OrgVersie $script:orgVersie; Publish-OrgVersie $script:orgVersie }
}
# Pas nu (alles staat op GitHub) de portier laten weten wat er goedgekeurd is. Lukt dat niet, dan is er niets stuk: de
# markering 'goedgekeurd' in het organogram houdt een tweede aanmelding toch tegen. Wel melden (exitcode 2).
if ($env:DL_PORTIER -and $script:naPush.Count) {
    try {
        foreach ($m in $script:naPush) { Invoke-Portier 'POST' '/afgehandeld' $m | Out-Null }
        Invoke-Portier 'POST' '/orgversie' @{ versie = $script:orgVersie } | Out-Null
    } catch { Write-Host "Kon de portier niet bijwerken ($($_.Exception.Message)); de goedkeuring zelf is gelukt."; $script:wacht++ }
}
if ($script:wacht) { exit 2 }
