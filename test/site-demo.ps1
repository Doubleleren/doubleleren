# Vult de e2e-testomgeving met voorbeeldactiviteit (ondertekend door elk testlid zelf) en maakt bestandslijsten
# voor de lokale website. Eerst test\e2e.ps1 draaien. Daarna een lokale server op de testmap en open:
#   http://localhost:8765/app/docs/?app=/app&beheer=/beheer&data=/data
param([string]$Werk = (Join-Path $env:TEMP 'doubleleren-e2e'))
$ErrorActionPreference = 'Stop'
$Werk = (Get-Item -LiteralPath $Werk).FullName
$A = Join-Path $Werk 'app'; $B = Join-Path $Werk 'beheer'; $D = Join-Path $Werk 'data'; $T = Join-Path $Werk 'thuis'
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim', 'client') { . "$A\app\lib\$l.ps1" }
$codes = Get-Content "$Werk\codes.json" -Raw | ConvertFrom-Json
$lessen = @((Get-Content "$A\lessen\index.json" -Raw -Encoding UTF8 | ConvertFrom-Json).lessen)
$rnd = New-Object Random 7

foreach ($p in $codes.ids.PSObject.Properties) {
    $naam = $p.Name; $id = $p.Value
    $c = Get-DlClient -Thuis "$T\$naam"; if (-not $c) { continue }
    try { $s = Get-DlEigenSleutels $c } catch { continue }
    $m = Read-DlVersleuteld $c.data $id 'matrix' $s $c.publiek
    if ($m) {
        $sterk = $rnd.Next(1, 13)
        foreach ($it in $m.obj.scores.PSObject.Properties) {
            $basis = [int]$it.Value.'2026-06'; $hg = [int]($it.Name.Split('.')[0])
            $v = [Math]::Max(1, [Math]::Min(5, $basis + $rnd.Next(-1, 2) + $(if ($hg -eq $sterk) { 2 } else { 0 })))
            $it.Value = [pscustomobject][ordered]@{ '2026-06' = $v; '2026-09' = $(if ($rnd.NextDouble() -lt 0.35) { [Math]::Min(5, $v + 1) } else { $v }) }
        }
        Write-DlVersleuteld $c.data $id 'matrix' $s $m.obj $m.sha $id $c.prive | Out-Null
    }
    $regels = @{}
    for ($dag = 50; $dag -ge 1; $dag--) {
        $dt = (Get-Date).Date.AddDays(-$dag).AddHours(9 + $rnd.Next(0, 8))
        if ($dt.DayOfWeek -in 'Saturday', 'Sunday' -or $rnd.NextDouble() -lt 0.2) { continue }
        $les = $lessen[$rnd.Next(0, $lessen.Count)]; $mk = $dt.ToString('yyyy-MM')
        if (-not $regels[$mk]) { $regels[$mk] = @() }
        $regels[$mk] += [pscustomobject][ordered]@{ datum = $dt.ToString('s'); id = $les.id; resultaat = @('goed', 'goed', 'deels', 'fout')[$rnd.Next(0, 4)]; soort = $les.soort; niveau = @('basis', 'gevorderd')[$rnd.Next(0, 2)]; matrix = @($les.matrix); vakgebied = $les.vakgebied; onderwerp = $les.onderwerp; titel = $les.titel; type = $les.type }
    }
    foreach ($mk in $regels.Keys) {
        $nieuw = @($regels[$mk])
        Update-DlVersleuteld $c.data $id "log-$mk" $s { param($h) [ordered]@{ v = 1; regels = @($nieuw) + @($(if ($h) { $h.regels })) } }.GetNewClosure() $id $c.prive $c.publiek | Out-Null
    }
    Write-Host "  $naam`: $(@($regels.Values | ForEach-Object { $_ }).Count) lessen"
}

# Bestandslijsten (lokaal vervangen deze de GitHub-API)
foreach ($map in $A, $B, $D) {
    $paden = @(Get-ChildItem -LiteralPath $map -Recurse | Where-Object { -not $_.PSIsContainer -and $_.FullName -notmatch '\\\.git\\' } | ForEach-Object { $_.FullName.Substring($map.Length + 1).Replace('\', '/') })
    [IO.File]::WriteAllText("$map\.lijst.json", ($paden | ConvertTo-Json))
}
Write-Host "`nTestcodes en testtoken staan in $Werk\codes.json (alleen testomgeving)."
Write-Host "Open: http://localhost:8765/app/docs/?app=/app&beheer=/beheer&data=/data"
