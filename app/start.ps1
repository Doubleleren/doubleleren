# Eén regel om DoubleLeren te installeren of bij te werken:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/thijsbol2004/doubleleren/main/app/start.ps1 | iex"
# Downloadt de nieuwste versie naar %LOCALAPPDATA%\DoubleLeren\programma en start de installer.
# (eigenaar/repo hieronder gelijk houden met instellingen.json)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$eigenaar = 'thijsbol2004'; $repo = 'doubleleren'
$thuis = Join-Path $env:LOCALAPPDATA 'DoubleLeren'
$doel = Join-Path $thuis 'programma'
$zip = Join-Path $env:TEMP "doubleleren-$([guid]::NewGuid()).zip"
$tmp = $zip -replace '\.zip$', ''
Write-Host 'DoubleLeren wordt gedownload...'
Invoke-WebRequest "https://codeload.github.com/$eigenaar/$repo/zip/refs/heads/main" -OutFile $zip -UseBasicParsing
Expand-Archive $zip $tmp
$bron = Get-ChildItem $tmp -Directory | Select-Object -First 1
New-Item -ItemType Directory $thuis -Force | Out-Null
if (Test-Path $doel) { Remove-Item $doel -Recurse -Force }
Move-Item $bron.FullName $doel
Get-ChildItem $doel -Recurse -File | Unblock-File
Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $thuis 'config.json')) { Write-Host 'Bijgewerkt naar de nieuwste versie.'; return }
Start-Process powershell -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$doel\app\installeer.ps1`""
