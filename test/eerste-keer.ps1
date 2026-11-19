# Eenmalig klaarzetten voor wie aan de code meewerkt (Claude draait dit zelf, zie CLAUDE.md):
# controleert Git en Python, zet deze map op staging en bouwt de lokale demo met nepdata.
#   powershell -ExecutionPolicy Bypass -File test\eerste-keer.ps1              controleren en klaarzetten
#   powershell -ExecutionPolicy Bypass -File test\eerste-keer.ps1 -Installeer  ontbrekende Git/Python installeren (winget)
# Geeft aan het eind een overzicht; wat de persoon zelf moet doen (2FA, inloggen bij GitHub) staat er apart bij.
param([switch]$Installeer)
$ErrorActionPreference = 'Stop'
$bron = Split-Path $PSScriptRoot -Parent
$klaar = @(); $zelf = @(); $mist = @()

function Update-Pad { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
# Python echt aanwezig? (de lege 'python' uit de Microsoft Store opent alleen de Store)
function Test-Python { try { $v = & python --version 2>&1; return ($LASTEXITCODE -eq 0 -and "$v" -match '^Python 3') } catch { return $false } }
function Installeer-Pakket([string]$Id, [string]$Naam) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "winget ontbreekt: installeer $Naam zelf." }
    Write-Host "$Naam installeren..."
    & winget install --id $Id -e --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Update-Pad
}

# 1. Git
if (-not (Get-Command git -ErrorAction SilentlyContinue) -and $Installeer) { Installeer-Pakket 'Git.Git' 'Git' }
if (Get-Command git -ErrorAction SilentlyContinue) { $klaar += "Git: $((git --version) -replace 'git version ', '')" } else { $mist += 'Git' }

# 2. Python 3 (voor de lokale server)
if (-not (Test-Python) -and $Installeer) { Installeer-Pakket 'Python.Python.3.12' 'Python 3' }
if (Test-Python) { $klaar += "Python: $((& python --version 2>&1) -replace 'Python ', '')" } else { $mist += 'Python 3' }

if ($mist.Count) {
    Write-Host "`nOntbreekt: $($mist -join ', '). Draai dit script opnieuw met -Installeer (na akkoord van de gebruiker)." -ForegroundColor Yellow
    exit 2
}

# 3. Git-naam voor commits (commits horen bij je eigen GitHub-account)
$naam = git -C $bron config user.name; $mail = git -C $bron config user.email
if ($naam -and $mail) { $klaar += "Git-naam: $naam <$mail>" }
else { $zelf += 'Git-naam instellen: git config --global user.name "<GitHub-gebruikersnaam>" en git config --global user.email "<id>+<gebruikersnaam>@users.noreply.github.com" (staat op github.com/settings/emails)' }

# 4. Deze map op de nieuwste staging (nooit main)
$tak = git -C $bron branch --show-current
if ($tak -eq 'main') {
    if (git -C $bron status --porcelain) { throw 'Er staan wijzigingen op main. Zet die eerst op een eigen branch; werk nooit op main.' }
    git -C $bron fetch -q origin staging; git -C $bron switch -q staging; $tak = 'staging'
}
if ($tak -eq 'staging') { git -C $bron pull -q --ff-only 2>$null | Out-Null }
$klaar += "Branch: $tak"

# 5. Lokale demo met nepdata (alleen opbouwen als die er nog niet is)
$werk = Join-Path $env:TEMP 'doubleleren-demo'
if (Test-Path "$werk\codes.json") { $klaar += "Lokale demo: staat al klaar in $werk" }
else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\demo.ps1" -GeenServer | Out-Null
    if ($LASTEXITCODE) { throw 'Lokale demo opbouwen mislukt: draai test\demo.ps1 los om de fout te zien.' }
    $klaar += "Lokale demo: opgebouwd in $werk"
}

$zelf += 'Tweestapsverificatie (2FA) aan op je GitHub-account'
$zelf += 'Bij je eerste push opent Git een venster om in te loggen bij GitHub: log in met je eigen account'

Write-Host "`nKlaar:" -ForegroundColor Green; $klaar | ForEach-Object { Write-Host "  - $_" }
Write-Host "`nZelf doen (eenmalig):" -ForegroundColor Yellow; $zelf | ForEach-Object { Write-Host "  - $_" }
Write-Host "`nStarten: powershell -ExecutionPolicy Bypass -File test\demo.ps1"
