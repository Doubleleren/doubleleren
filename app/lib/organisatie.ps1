# Wie mag wie zien, volgens organisatie.json. Dezelfde regels staan in docs/app.js.
#   lid zelf · projectleider van het project · celleider van de cel · head van het vakgebied · generator
# Beheerders zien NIET automatisch iedereen in het dashboard; zij beheren alleen sleutels.

function Get-DlCelVanLid($Org, [string]$Id) {
    $lid = $Org.leden.$Id
    if (-not $lid) { return $null }
    if ($lid.cel) { return @($Org.cellen | Where-Object { $_.id -eq $lid.cel })[0] }
    if ($lid.project) { return @($Org.cellen | Where-Object { @($_.projecten | Where-Object { $_.id -eq $lid.project }).Count })[0] }
    $null
}
function Get-DlProjectVanLid($Org, [string]$Id) {
    $lid = $Org.leden.$Id
    if (-not $lid -or -not $lid.project) { return $null }
    foreach ($c in $Org.cellen) { foreach ($p in $c.projecten) { if ($p.id -eq $lid.project) { return $p } } }
    $null
}
function Get-DlKijkers($Org, [string]$Id) {
    $k = New-Object System.Collections.Generic.List[string]
    $voeg = { param($x) if ($x -and -not $k.Contains($x)) { $k.Add($x) } }
    & $voeg $Id
    $p = Get-DlProjectVanLid $Org $Id; if ($p) { & $voeg $p.leider }
    $c = Get-DlCelVanLid $Org $Id; if ($c) { & $voeg $c.leider }
    & $voeg $Org.head
    & $voeg 'generator'
    $k.ToArray()   # bewust zonder komma: losse strings, aanroepers gebruiken @(...)
}
