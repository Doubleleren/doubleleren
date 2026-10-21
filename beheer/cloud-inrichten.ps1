# Eenmalig (en veilig opnieuw te draaien): de cloud-generator in Doubleleren/doubleleren-generator van geheimen voorzien.
# Draai dit zelf, in een gewoon PowerShell-venster. Alles gaat rechtstreeks naar GitHub en verschijnt nergens op het scherm:
#   DL_GENERATOR_SLEUTEL   de generatorsleutel (nooit de beheersleutel; die blijft op deze laptop)
#   DL_DEPLOY_APP          nieuwe deploy key met schrijfrecht op doubleleren (lessen)
#   DL_DEPLOY_DATA         nieuwe deploy key met schrijfrecht op doubleleren-data (wachtrijen, scorebord)
#   ANTHROPIC_API_KEY      je API-sleutel; gh vraagt erom (plakken, niet zichtbaar)
# Plus de variabelen DL_LIVE = false (eerst proefruns) en DL_MODEL.
#   powershell -ExecutionPolicy Bypass -File beheer\cloud-inrichten.ps1 [-ZonderApiSleutel] [-Model claude-opus-5-5]
param([string]$Repo = 'Doubleleren/doubleleren-generator', [switch]$ZonderApiSleutel, [string]$Model = 'claude-opus-5-5')
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\GitHub.cli_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\gh.exe' }
if (-not (Test-Path $gh)) { throw 'GitHub CLI (gh) niet gevonden.' }
$OutputEncoding = New-Object Text.UTF8Encoding($false)

$g = Read-DlGeheim (Join-Path (Get-DlThuis) 'beheer\beheer.dpapi')
if (-not $g -or -not $g.beheerPrive -or $g.beheerPrive.n -eq $g.generatorPrive.n) { throw 'Eerst beheer.ps1 -NieuweGeneratorsleutel: de beheersleutel mag nooit naar de cloud.' }
& $gh repo view $Repo --json name | Out-Null; if ($LASTEXITCODE) { throw "Repo $Repo niet gevonden of geen toegang." }

function Zet-Secret([string]$Naam, [string]$Waarde) {
    $Waarde | & $gh secret set $Naam --repo $Repo
    if ($LASTEXITCODE) { throw "Secret $Naam zetten mislukt." }
    Write-Host "  secret $Naam gezet"
}

Write-Host '1. Generatorsleutel'
Zet-Secret 'DL_GENERATOR_SLEUTEL' ($g.generatorPrive | ConvertTo-Json -Compress)

Write-Host '2. Deploy keys (per repo, horen niet bij een persoon)'
$titel = 'doubleleren-generator (cloud)'
$tmp = Join-Path $env:TEMP ('dl-sleutels-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
try {
    foreach ($r in @(@($inst.appRepo, 'DL_DEPLOY_APP'), @($inst.dataRepo, 'DL_DEPLOY_DATA'))) {
        $doel = "$($inst.eigenaar)/$($r[0])"; $f = Join-Path $tmp $r[0]
        & ssh-keygen -q -t ed25519 -C $titel -N '""' -f $f | Out-Null
        if (-not (Test-Path $f)) { throw 'ssh-keygen mislukt.' }
        # Oude cloud-sleutel van een eerdere inrichting eerst weghalen
        foreach ($oud in @(& $gh repo deploy-key list --repo $doel --json id,title | ConvertFrom-Json | Where-Object { $_.title -eq $titel })) { & $gh repo deploy-key delete $oud.id --repo $doel | Out-Null }
        & $gh repo deploy-key add "$f.pub" --repo $doel --allow-write --title $titel | Out-Null
        if ($LASTEXITCODE) { throw "Deploy key voor $doel toevoegen mislukt." }
        Write-Host "  deploy key met schrijfrecht op $doel"
        Zet-Secret $r[1] ([IO.File]::ReadAllText($f))
    }
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host '3. Variabelen'
& $gh variable set DL_LIVE --body false --repo $Repo | Out-Null; Write-Host '  DL_LIVE = false (proefruns)'
& $gh variable set DL_MODEL --body $Model --repo $Repo | Out-Null; Write-Host "  DL_MODEL = $Model"

if (-not $ZonderApiSleutel) {
    Write-Host '4. Anthropic API-sleutel: plak hem hieronder (je ziet niets verschijnen) en druk op Enter'
    & $gh secret set ANTHROPIC_API_KEY --repo $Repo
    if ($LASTEXITCODE) { throw 'API-sleutel zetten mislukt.' }
}

& $gh workflow enable generator.yml --repo $Repo 2>$null | Out-Null
Write-Host "`nKlaar. De workflow staat aan (proefruns op werkdagen). Meteen een proefrun starten:" -ForegroundColor Green
Write-Host "  gh workflow run generator.yml --repo $Repo -f proef=true"
