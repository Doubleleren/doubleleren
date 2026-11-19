# Wie mag wie zien, volgens organisatie.json. Dezelfde regels staan in docs/app.js.
#   lid zelf · projectleider van het project · celleider van de cel · head van het vak van het lid · generator
# Vak: leden.<id>.vak (zonder = het standaardvak, instellingen.vakgebied); head van het standaardvak = head,
# heads van andere vakken staan in heads.<vak>.
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
function Get-DlVakVanLid($Org, [string]$Id) { $v = $Org.leden.$Id.vak; if ($v) { [string]$v } else { [string]$Org.vakgebied } }
function Get-DlHeadVanVak($Org, [string]$Vak) {
    if ($Org.heads -and $Org.heads.$Vak) { return [string]$Org.heads.$Vak }
    if ($Vak -eq $Org.vakgebied) { return $Org.head }
    $null
}
function Get-DlHeads($Org) { @(@($Org.head) + @($(if ($Org.heads) { $Org.heads.PSObject.Properties.Value })) | Where-Object { $_ } | Select-Object -Unique) }
function Get-DlKijkers($Org, [string]$Id) {
    $k = New-Object System.Collections.Generic.List[string]
    $voeg = { param($x) if ($x -and -not $k.Contains($x)) { $k.Add($x) } }
    & $voeg $Id
    $p = Get-DlProjectVanLid $Org $Id; if ($p) { & $voeg $p.leider }
    $c = Get-DlCelVanLid $Org $Id; if ($c) { & $voeg $c.leider }
    & $voeg (Get-DlHeadVanVak $Org (Get-DlVakVanLid $Org $Id))
    & $voeg 'generator'
    $k.ToArray()   # bewust zonder komma: losse strings, aanroepers gebruiken @(...)
}
