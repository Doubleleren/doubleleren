# Beheer van DoubleLeren (alleen voor de beheerder). Wijzigingen gaan direct naar de privé data-repo,
# ondertekend met de beheersleutel (de publieke helft staat in vertrouwd.json in de openbare app-repo).
#
#   beheer.ps1 -Init                                             eenmalig: beheersleutel; vraagt je beheertoken (niet zichtbaar)
#   beheer.ps1 -Uitnodigen -Naam Alfa -Rol projectleider -Project ecom-b2b [-Optioneel] [-Beheerder]
#   beheer.ps1 -Aanvragen                                        openstaande aanmeldingen
#   beheer.ps1 -Goedkeuren lid-xxxxxx -Controlewoorden "a b c d e f"
#   beheer.ps1 -Verplaats lid-xxxxxx -Project ecom-nationaal     (of -Cel leadgen) en toegang meteen bijwerken
#   beheer.ps1 -Wijzig lid-xxxxxx -Leren verplicht|optioneel
#   beheer.ps1 -Bijwerken                                        toegang opnieuw berekenen
#   beheer.ps1 -Controleer                                       overzicht: wie ziet wie
#   beheer.ps1 -Migreer -VanMap <map>                            eenmalig: oude beheer-repo (onondertekend) overzetten
# Rollen: lid (met -Project of -Cel), projectleider (-Project), celleider (-Cel), head.
param(
    [switch]$Init, [switch]$Uitnodigen, [switch]$Aanvragen, [string]$Goedkeuren, [switch]$Bijwerken, [switch]$Controleer,
    [string]$Wijzig, [string]$Verplaats, [switch]$Migreer, [string]$VanMap,
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
function GenPrive { if (-not $geheim.generatorPrive) { throw 'Geen beheersleutel: draai eerst -Init' }; $geheim.generatorPrive }
function Vertrouwd { $p = GenPrive; [pscustomobject]@{ kty = 'RSA'; n = $p.n; e = $p.e } }
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
    if ($geheim -and $geheim.generatorPrive) { Write-Host 'Beheersleutel bestaat al.' }
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

function Save-Org { Write-DlBeheer $d 'organisatie.json' $script:org (GenPrive) }
function Naam($id) { if ($id -eq 'generator') { return 'generator' }; $n = $org.leden.$id.naam; if ($n) { "$n ($id)" } else { $id } }
function PubVan($id) { if ($id -eq 'generator') { return $V }; $s = Read-DlBeheer $d "sleutels/$id.json" $V; if ($s) { $s.publiek } }

# Toegang: de DK verpakt voor elke kijker met een goedgekeurde sleutel, plus de vingerafdruk van die sleutel
function New-Toegang([string]$id, [byte[]]$dk, [int]$versie) {
    $kop = [ordered]@{}; $vf = [ordered]@{}
    foreach ($k in @(Get-DlKijkers $org $id)) {
        $pub = PubVan $k; if (-not $pub) { continue }
        $kop[$k] = ConvertTo-B64u (Protect-DlRsa $pub $dk); $vf[$k] = Get-DlVingerafdrukHex $pub
    }
    [ordered]@{ v = 2; versie = $versie; kopieen = $kop; vingerafdrukken = $vf }
}
function Write-Toegang([string]$id, $t) { Write-DlBeheer $d "toegang/$id.json" $t (GenPrive) }

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
            Write-DlBeheer $d "$soort/$($f.Name)" ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json) (GenPrive)
            Write-Host "  $soort/$($f.Name) overgezet en ondertekend"
        }
    }
    Write-Host "Organogram met $(@($org.leden.PSObject.Properties).Count) leden overgezet."
}

elseif ($Uitnodigen) {
    if (-not $Naam) { throw 'Geef -Naam' }
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
    Write-Host "Uitnodiging voor $Naam ($id, $Rol$(if ($Optioneel) { ', lessen optioneel' }))" -ForegroundColor Green
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
    } else { throw 'Geef -Project of -Cel' }
    Save-Org
    Write-Host "$(Naam $Verplaats) verplaatst."
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
        $oudDk = Unprotect-DlRsa (GenPrive) (ConvertFrom-B64u $oudT.kopieen.generator)
        $sleutelsObj.eerdere = @(@($oudS.publiek) + @($oudS.eerdere) | Where-Object { $_ })
        Write-DlBeheer $d "sleutels/$id.json" $sleutelsObj (GenPrive)
        Start-Rotatie $id $oudDk; Complete-Rotatie $id
    } else {
        if ($oudS) { throw "$id is al goedgekeurd; gebruik herstel" }
        $dk = Unprotect-DlRsa (GenPrive) (ConvertFrom-B64u $aanvraag.toegang.generator)
        Write-DlBeheer $d "sleutels/$id.json" $sleutelsObj (GenPrive)
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
        $dk = Unprotect-DlRsa (GenPrive) (ConvertFrom-B64u $t.kopieen.generator)
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
    Write-Host ("{0,-30} {1,-20} {2,-22} {3}" -f 'Deelnemer', 'Rol', 'Project / cel', 'Zichtbaar voor')
    foreach ($id in @($org.leden.PSObject.Properties.Name)) {
        $l = $org.leden.$id; $plek = if ($l.project) { $l.project } elseif ($l.cel) { "cel $($l.cel)" } else { '-' }
        $rolTekst = if ($org.head -eq $id) { 'head' } elseif (@($org.cellen | Where-Object leider -eq $id).Count) { 'celleider' } elseif (@($org.cellen.projecten | Where-Object leider -eq $id).Count) { 'projectleider' } else { 'lid' }
        if ($l.leren -eq 'optioneel') { $rolTekst += ' (opt.)' }
        $t = Read-DlBeheer $d "toegang/$id.json" $V
        $kijkers = if ($t) { @($t.kopieen.PSObject.Properties.Name | Where-Object { $_ -ne $id }) | ForEach-Object { Naam $_ } } else { @('(nog niet goedgekeurd)') }
        Write-Host ("{0,-30} {1,-20} {2,-22} {3}" -f (Naam $id), $rolTekst, $plek, ($kijkers -join ', '))
    }
}

if ($script:kloon) { Push-DlKloon $script:kloon }
