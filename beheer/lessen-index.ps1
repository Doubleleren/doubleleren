# Bouwt lessen/index.json uit alle lessen in de pool. De pop-up gebruikt hem als reserve als een wachtrij leeg is,
# de website voor de kennisbank. Lessen zijn niet persoonlijk en staan daarom leesbaar in de app-repo.
$App = Split-Path $PSScriptRoot -Parent
$lessen = foreach ($f in Get-ChildItem (Join-Path $App 'lessen') -Filter *.json | Where-Object Name -ne 'index.json' | Sort-Object Name) {
    $l = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    [ordered]@{
        id = $l.id; titel = $l.titel; vakgebied = $l.vakgebied; onderwerp = $l.onderwerp; type = $l.type
        niveau = $(if ($l.niveau) { $l.niveau } else { 'basis' }); matrix = @($l.matrix | Where-Object { $_ })
        kernpunt = $l.kernpunt; bron = $l.bron; video = $l.video; soort = $l.opdracht.soort
        herkomst = $(if ($l.herkomst -eq 'team') { 'team' } else { 'generator' })
    }
}
$index = [ordered]@{ v = 1; bijgewerkt = (Get-Date).ToString('s'); lessen = @($lessen) }
[IO.File]::WriteAllText((Join-Path $App 'lessen\index.json'), ($index | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
Write-Host "lessen/index.json: $(@($lessen).Count) lessen"
