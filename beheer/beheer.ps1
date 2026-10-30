# Beheer van DoubleLeren (alleen voor de beheerder). Wijzigingen gaan direct naar de privé data-repo,
# ondertekend met de beheersleutel (de publieke helft staat in vertrouwd.json in de openbare app-repo).
#
#   beheer.ps1 -Init                                             eenmalig: beheersleutel; vraagt je beheertoken (niet zichtbaar)
#   beheer.ps1 -Uitnodigen -Naam Alfa -Rol projectleider -Project ecom-b2b [-Vak cro] [-Optioneel] [-Beheerder]
#   beheer.ps1 -Aanvragen                                        openstaande aanmeldingen
#   beheer.ps1 -Goedkeuren lid-xxxxxx -Controlewoorden "a b c d e f"
#   beheer.ps1 -AutoGoedkeuren                                   nieuwe aanmeldingen zonder controlewoorden (herstel niet)
#   beheer.ps1 -Verplaats lid-xxxxxx -Project ecom-nationaal     (of -Cel leadgen, en/of -Vak cro) en toegang meteen bijwerken
#   beheer.ps1 -Head lid-xxxxxx -Vak cro                         head van een vak maken (ziet de voortgang van dat vak)
#   beheer.ps1 -Wijzig lid-xxxxxx -Leren verplicht|optioneel
#   beheer.ps1 -Bijwerken                                        toegang opnieuw berekenen
#   beheer.ps1 -Controleer                                       overzicht: wie ziet wie
#   beheer.ps1 -NieuweGeneratorsleutel                           aparte sleutel voor de lesgenerator (hervatbaar)
#   beheer.ps1 -Migreer -VanMap <map>                            eenmalig: oude beheer-repo (onondertekend) overzetten
# Rollen: lid (met -Project of -Cel), projectleider (-Project), celleider (-Cel), head (van -Vak, standaard het standaardvak).
# Vakken staan in instellingen.json; zonder -Vak hoort een lid bij het standaardvak (vakgebied).
param(
    [switch]$Init, [switch]$Uitnodigen, [switch]$Aanvragen, [switch]$AutoGoedkeuren, [string]$Goedkeuren, [switch]$Bijwerken, [switch]$Controleer,
    [string]$Wijzig, [string]$Verplaats, [string]$Head, [string]$Vak, [switch]$Migreer, [string]$VanMap, [switch]$NieuweGeneratorsleutel,
    [string]$Naam, [ValidateSet('lid', 'projectleider', 'celleider', 'head')][string]$Rol = 'lid', [string]$Project, [string]$Cel,
    [string]$Controlewoorden, [switch]$Optioneel, [switch]$Beheerder,
    [ValidateSet('', 'verplicht', 'optioneel')][string]$Leren = '',
    [string]$DataMap, [string]$Thuis       # tests: lokale map i.p.v. GitHub
)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'organisatie', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Utf8 = New-Object Text.UTF8Encoding($false)
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
New-Item -ItemType Directory $Thuis -Force | Out-Null
$geheimPad = Join-Path $Thuis 'beheer.dpapi'
$geheim = Read-DlGeheim $geheimPad

function Save-Geheim { Save-DlGeheim $geheimPad $script:geheim }
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

$d = DataOpslag
$V = Vertrouwd
$org = Read-DlBeheer $d 'organisatie.json' $V
if (-not $org -and -not $Migreer) { $org = Get-Content (Join-Path $App 'sjablonen\organisatie-sjabloon.json') -Raw -Encoding UTF8 | ConvertFrom-Json }

$standaardVak = [string]$inst.vakgebied
$vakIds = @($(if ($inst.vakken) { $inst.vakken.id } else { $standaardVak }))
if ($Vak -and $vakIds -notcontains $Vak) { throw "Onbekend vak '$Vak' ($($vakIds -join ', '))" }
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

function Save-Org { Write-DlBeheer $d 'organisatie.json' $script:org (BeheerPrive) }
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
    $geheim.rotaties.PSObject.Properties.Remove($id); Save-Geheim
}

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
    # Nieuwe aanmeldingen zonder controlewoorden goedkeuren: het wachtwoord van zes woorden is genoeg.
    # "Code kwijt" (herstel) blijft handwerk met controlewoorden, anders kan een collega een account overnemen.
    foreach ($f in @(Get-DlOpslagLijst $d 'aanvragen')) {
        $a = Read-DlJson $d "aanvragen/$f"
        if ($f -ne "$($a.id).json" -or -not $org.leden.($a.id)) { Write-Host "Overgeslagen: $f hoort niet bij een lid uit het organogram"; continue }
        if ($a.herstel) { Write-Host "Wacht op handmatige controle (code kwijt): $(Naam $a.id)  controlewoorden: $(Get-DlControlewoorden $a)"; continue }
        if (Read-DlBeheer $d "sleutels/$($a.id).json" $V) { Write-Host "Overgeslagen: $(Naam $a.id) is al goedgekeurd"; continue }
        $extra = @('-Thuis', $Thuis); if ($DataMap) { $extra += @('-DataMap', $DataMap) }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Goedkeuren $a.id -Controlewoorden (Get-DlControlewoorden $a) @extra
    }
}

elseif ($Goedkeuren) {
    $id = $Goedkeuren
    if (-not $org.leden.$id) { throw "$id staat niet in het organogram: eerst uitnodigen" }
    $a = Read-DlOpslag $d "aanvragen/$id.json"; if (-not $a) { throw "Geen aanvraag voor $id" }
    $aanvraag = $script:DlUtf8.GetString($a.bytes) | ConvertFrom-Json
    if ($aanvraag.id -ne $id) { throw 'Aanvraag hoort bij een ander id' }
    if (-not (Test-DlSleutelVorm $aanvraag.publiek)) { throw 'De sleutel in de aanvraag heeft niet de vaste vorm: niet goedkeuren.' }
    $echt = Get-DlControlewoorden $aanvraag
    $gegeven = (($Controlewoorden.ToLower() -split '[\s,\-]+') | Where-Object { $_ }) -join ' '
    if ($gegeven -ne $echt) { throw "Controlewoorden komen NIET overeen. Niet goedkeuren: vraag $(Naam $id) opnieuw aan te melden en de woorden opnieuw door te geven." }
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
        Write-Toegang $id (New-Toegang $id $dk 1)
    }
    Remove-DlOpslag $d "aanvragen/$id.json" $a.sha
    $t = Read-DlBeheer $d "toegang/$id.json" $V
    Write-Host "Goedgekeurd: $(Naam $id). Zichtbaar voor: $((@($t.kopieen.PSObject.Properties.Name) | ForEach-Object { Naam $_ }) -join ', ')" -ForegroundColor Green
    $Bijwerken = $true
}

if ($Bijwerken) {
    foreach ($p in @($(if ($geheim.rotaties) { $geheim.rotaties.PSObject.Properties.Name }) | Where-Object { $_ })) { Write-Host "Afgebroken sleutelwissel hervatten: $(Naam $p)"; Complete-Rotatie $p }
    foreach ($id in @($org.leden.PSObject.Properties.Name)) {
        $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t) { continue }
        $dk = Open-GeneratorKopie $t.kopieen.generator
        $moet = @(Get-DlKijkers $org $id | Where-Object { PubVan $_ })
        $heeft = @($t.kopieen.PSObject.Properties.Name)
        $weg = @($heeft | Where-Object { $moet -notcontains $_ })
        $erbij = @($moet | Where-Object { $heeft -notcontains $_ })
        $anders = @($moet | Where-Object { $heeft -contains $_ -and $t.vingerafdrukken.$_ -ne (Get-DlVingerafdrukHex (PubVan $_)) })
        if (-not ($weg.Count + $erbij.Count + $anders.Count)) { continue }
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

if ($script:kloon) { Push-DlKloon $script:kloon }
