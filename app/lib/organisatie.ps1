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
# Rolhouder: head, celleider, projectleider of beheerder. Die zien anderen of beheren, dus nooit automatisch goedkeuren.
# Dezelfde regel staat in docs/app.js (heeftRol).
function Test-DlRolhouder($Org, [string]$Id) {
    if ((Get-DlHeads $Org) -contains $Id) { return $true }
    foreach ($c in @($Org.cellen)) {
        if ($c.leider -eq $Id) { return $true }
        foreach ($p in @($c.projecten)) { if ($p.leider -eq $Id) { return $true } }
    }
    @($Org.beheerders) -contains $Id
}
# Mag $Door het bestaande lid $Id uitnodigen? De beheerder iedereen; een kijker (projectleider, celleider, head) alleen
# gewone leden die hij ziet. Heads, leiders en beheerders alleen de beheerder: wie uitnodigt, ziet de code.
# Dezelfde regels staan in docs/regels.js (magUitnodigen, magToevoegen); test\regelstest.ps1 vergelijkt ze.
function Test-DlMagUitnodigen($Org, [string]$Door, [string]$Id) {
    if ($Door -cnotmatch '^lid-[0-9a-f]{6}$' -or $Id -cnotmatch '^lid-[0-9a-f]{6}$' -or $Door -eq $Id) { return $false }
    if (-not $Org.leden.$Door -or -not $Org.leden.$Id) { return $false }
    if (@($Org.beheerders) -contains $Door) { return $true }
    if (Test-DlRolhouder $Org $Id) { return $false }
    @(Get-DlKijkers $Org $Id) -contains $Door
}
# Mag $Door een nieuw gewoon lid toevoegen op deze plek (-Project of -Cel of geen) met dit vak? Zelfde regel als
# hierboven, voor een lid dat er nog niet is.
function Test-DlMagToevoegen($Org, [string]$Door, [string]$Project, [string]$Cel, [string]$Vak) {
    $kopie = $Org | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $lid = [ordered]@{}
    if ($Project) { $lid.project = $Project } elseif ($Cel) { $lid.cel = $Cel }
    if ($Vak -and $Vak -ne $kopie.vakgebied) { $lid.vak = $Vak }
    if (-not $kopie.leden) { $kopie | Add-Member -NotePropertyName leden -NotePropertyValue ([pscustomobject]@{}) -Force }
    $proef = 'lid-' + ('0' * 6)      # samengesteld: in de openbare code staat bewust geen leden-id (e2e controleert dat)
    $kopie.leden | Add-Member -NotePropertyName $proef -NotePropertyValue ([pscustomobject]$lid) -Force
    Test-DlMagUitnodigen $kopie $Door $proef
}
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
