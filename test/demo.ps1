# Lokale testomgeving met vaste nepdata: 9 testcollega's in alle rollen, ingevulde skilllijsten, activiteit,
# scorebord en feedback. Geen token, geen internet, geen live data. Daarna draait de website op localhost.
#   powershell -ExecutionPolicy Bypass -File test\demo.ps1              opbouwen (een paar minuten) en starten
#   powershell -ExecutionPolicy Bypass -File test\demo.ps1 -Bijwerken   alleen je nieuwste code erin, testdata blijft
# Opties: -Poort 8765, -Werk <map> (standaard %TEMP%\doubleleren-demo), -GeenServer (alleen opbouwen of bijwerken).
param([switch]$Bijwerken, [int]$Poort = 8765, [string]$Werk = (Join-Path $env:TEMP 'doubleleren-demo'), [switch]$GeenServer)
$ErrorActionPreference = 'Stop'
$bron = Split-Path $PSScriptRoot -Parent
$A = Join-Path $Werk 'app'

if ($Bijwerken -and (Test-Path "$Werk\codes.json")) {
    # Code van nu, maar de testsleutel (vertrouwd.json) en de testdata blijven
    Copy-Item (Join-Path $bron '*') $A -Recurse -Force -Exclude '.git', '.github', 'test', 'vertrouwd.json'
    $paden = @(Get-ChildItem -LiteralPath $A -Recurse -File | ForEach-Object { $_.FullName.Substring($A.Length + 1).Replace('\', '/') } | Where-Object { $_ -ne '.lijst.json' })
    [IO.File]::WriteAllText("$A\.lijst.json", ($paden | ConvertTo-Json))
    Write-Host 'Code bijgewerkt; de testdata is gebleven.' -ForegroundColor Green
} else {
    if ($Bijwerken) { Write-Host 'Nog geen testomgeving: die wordt nu eerst opgebouwd.' }
    Write-Host 'Testomgeving opbouwen (de eind-tot-eindtest maakt de testcollega''s; duurt een paar minuten)...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\e2e.ps1" -Werk $Werk | Out-Null
    if ($LASTEXITCODE) { throw "De eind-tot-eindtest gaf fouten; draai test\e2e.ps1 los om ze te zien." }
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\site-demo.ps1" -Werk $Werk | Out-Null
    if ($LASTEXITCODE) { throw 'Activiteit toevoegen (test\site-demo.ps1) mislukt.' }
    Write-Host 'Testomgeving klaar.' -ForegroundColor Green
}

# Wie is wie: rollen uit het (testmatige) organogram
$codes = Get-Content "$Werk\codes.json" -Raw | ConvertFrom-Json
$org = (Get-Content "$Werk\data\beheer\organisatie.json" -Raw -Encoding UTF8 | ConvertFrom-Json).inhoud | ConvertFrom-Json
$rol = @{}
foreach ($p in $org.leden.PSObject.Properties) { $l = $p.Value; $rol[$p.Name] = "lid $(if ($l.project) { $l.project } else { $l.cel })" }
foreach ($c in $org.cellen) {
    if ($c.leider) { $rol[$c.leider] = "celleider $($c.id)" }
    foreach ($pr in $c.projecten) { if ($pr.leider) { $rol[$pr.leider] = "projectleider $($pr.id)" } }
}
if ($org.head) { $rol[$org.head] = "head $($org.vakgebied)" }
if ($org.heads) { foreach ($h in $org.heads.PSObject.Properties) { $rol[$h.Value] = "head $($h.Name)" } }
$url = "http://localhost:$Poort/app/docs/?app=/app&data=/data"
Write-Host "`nInloggen op $url"
Write-Host 'Uitnodigingscode en code per testcollega (alleen deze testomgeving):'
$codes.codes.PSObject.Properties | Sort-Object Name | ForEach-Object {
    $id = $codes.ids.($_.Name)
    [pscustomobject]@{ Naam = $_.Name; Rol = $rol[$id]; Uitnodigingscode = "${id}:$($codes.token)"; Code = $_.Value }
} | Format-Table -AutoSize | Out-String -Width 300 | Write-Host

if ($GeenServer) { return }
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { throw 'Python ontbreekt. Installeer Python 3 (Microsoft Store of python.org) en start dit script opnieuw.' }
Write-Host "Website draait; stoppen met Ctrl+C. Na een wijziging: test\demo.ps1 -Bijwerken (in een tweede venster) en ververs de pagina."
Start-Process $url
& $py.Source "$PSScriptRoot\lokale-server.py" $Poort $Werk
