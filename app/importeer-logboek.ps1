# Eenmalig: lesresultaten uit de oude, persoonlijke DoubleLeren (logboek.jsonl) overzetten naar je versleutelde team-logboek.
# Antwoorden gaan naar je privébestand. Draai op je eigen laptop, na installeren en goedkeuring:
#   powershell -ExecutionPolicy Bypass -File importeer-logboek.ps1 -Logboek "<pad naar je oude logboek.jsonl>"
param([Parameter(Mandatory)][string]$Logboek, [string]$Thuis)
$ErrorActionPreference = 'Stop'
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim', 'client') { . (Join-Path $PSScriptRoot "lib\$l.ps1") }
$c = Get-DlClient -Thuis $Thuis; if (-not $c) { throw 'Installeer DoubleLeren eerst.' }
$s = Get-DlEigenSleutels $c
$oud = @([IO.File]::ReadAllLines($Logboek, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
foreach ($g in ($oud | Group-Object { ([string]$_.datum).Substring(0, 7) })) {
    $nieuw = @($g.Group | ForEach-Object {
        [pscustomobject][ordered]@{ datum = [string]$_.datum; id = $_.id; resultaat = $_.resultaat; soort = $_.soort; niveau = 'basis'
            matrix = @(([string]$_.matrix) -split ',' | Where-Object { $_ }); vakgebied = $_.vakgebied; onderwerp = $_.onderwerp; titel = $_.titel; type = $_.type }
    })
    $samen = { param($h) $l = @(); if ($h) { $l = @($h.regels) }; foreach ($n in $nieuw) { if (-not ($l | Where-Object { $_.id -eq $n.id -and $_.datum -eq $n.datum })) { $l += $n } }; [ordered]@{ v = 1; regels = $l } }.GetNewClosure()
    Update-DlVersleuteld $c.data $c.id "log-$($g.Name)" $s $samen $c.id $c.prive $c.publiek | Out-Null
    Write-Host "  $($g.Name): $($nieuw.Count) les(sen)"
}
$antwoorden = @($oud | Where-Object { $_.soort -ne 'meerkeuze' -and $_.antwoord } | ForEach-Object { [pscustomobject]@{ datum = [string]$_.datum; id = $_.id; antwoord = $_.antwoord } })
if ($antwoorden.Count) {
    $samenA = { param($h) $l = @(); if ($h) { $l = @($h.antwoorden) }; foreach ($n in $antwoorden) { if (-not ($l | Where-Object { $_.id -eq $n.id -and $_.datum -eq $n.datum })) { $l += $n } }; [ordered]@{ v = 1; antwoorden = $l } }.GetNewClosure()
    Update-DlVersleuteld $c.data $c.id 'prive' (Get-DlAk $c.prive) $samenA $c.id $c.prive $c.publiek | Out-Null
    Write-Host "  $($antwoorden.Count) antwoord(en) naar je privébestand"
}
Write-Host 'Klaar.'
