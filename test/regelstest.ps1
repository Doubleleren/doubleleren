# Regelstest: wie mag wie zien en uitnodigen, in PowerShell (app/lib/organisatie.ps1) en JavaScript (docs/regels.js),
# op een organogram met alle lastige gevallen. Beide moeten exact hetzelfde antwoord geven.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\regelstest.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\app\lib\organisatie.ps1')
$uit = Join-Path $env:TEMP 'doubleleren-regelstest'; New-Item -ItemType Directory $uit -Force | Out-Null
$fouten = 0
function Controleer([bool]$ok, [string]$wat) { if ($ok) { Write-Host "  OK    $wat" } else { Write-Host "  FOUT  $wat" -ForegroundColor Red; $script:fouten++ } }

# Testorganogram: head van het standaardvak en van een ander vak, head in een cel, head van een groep, cel- en
# projectleiders, lid zonder plek, beheerder, iemand met twee rollen
$org = @'
{
  "v": 1, "vakgebied": "seo", "head": "lid-0000a1", "heads": { "sea": "lid-0000a2", "base": "lid-0000a3" },
  "beheerders": ["lid-0000b1"],
  "cellen": [
    { "id": "ecom", "leider": "lid-0000c1", "projecten": [ { "id": "ecom-b2b", "leider": "lid-0000d1" }, { "id": "ecom-nat", "leider": null } ] },
    { "id": "leadgen", "leider": null, "projecten": [ { "id": "lg-b2c", "leider": "lid-0000d2" } ] }
  ],
  "leden": {
    "lid-0000a1": { "naam": "HeadSeo", "project": "ecom-b2b" },
    "lid-0000a2": { "naam": "HeadSea", "vak": "sea", "cel": "ecom" },
    "lid-0000a3": { "naam": "HeadBase", "vak": "base" },
    "lid-0000b1": { "naam": "Beheer", "project": "ecom-nat" },
    "lid-0000c1": { "naam": "CelEcom", "cel": "ecom" },
    "lid-0000d1": { "naam": "PlB2b", "project": "ecom-b2b" },
    "lid-0000d2": { "naam": "PlB2c", "project": "lg-b2c", "vak": "sea" },
    "lid-0000e1": { "naam": "LidB2b", "project": "ecom-b2b" },
    "lid-0000e2": { "naam": "LidSeaNat", "project": "ecom-nat", "vak": "sea" },
    "lid-0000e3": { "naam": "LidBase", "vak": "base" },
    "lid-0000e4": { "naam": "LidGeenPlek" },
    "lid-0000e5": { "naam": "LidLeadgen", "cel": "leadgen" }
  }
}
'@ | ConvertFrom-Json
[IO.File]::WriteAllText((Join-Path $uit 'org.json'), ($org | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))

$ids = @($org.leden.PSObject.Properties.Name) + @('generator', 'lid-zzzzzz', 'lid-999999')
$ps = [ordered]@{ kijkers = [ordered]@{}; rol = [ordered]@{}; uitnodigen = [ordered]@{}; toevoegen = [ordered]@{} }
foreach ($id in @($org.leden.PSObject.Properties.Name)) { $ps.kijkers[$id] = @(Get-DlKijkers $org $id); $ps.rol[$id] = [bool](Test-DlRolhouder $org $id) }
foreach ($door in $ids) { foreach ($id in $ids) { $ps.uitnodigen["$door>$id"] = [bool](Test-DlMagUitnodigen $org $door $id) } }
$plekken = @(@{ p = 'ecom-b2b' }, @{ p = 'ecom-nat' }, @{ p = 'lg-b2c' }, @{ c = 'ecom' }, @{ c = 'leadgen' }, @{})
foreach ($door in $ids) { foreach ($pl in $plekken) { foreach ($vak in 'seo', 'sea', 'base', '') {
    $k = "$door>$($pl.p)|$($pl.c)|$vak"; $ps.toevoegen[$k] = [bool](Test-DlMagToevoegen $org $door $pl.p $pl.c $vak)
} } }
[IO.File]::WriteAllText((Join-Path $uit 'ps.json'), ($ps | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

Write-Host '1. Verwachte uitkomsten (PowerShell)'
Controleer ($ps.uitnodigen['lid-0000d1>lid-0000e1'] -and -not $ps.uitnodigen['lid-0000d1>lid-0000e2']) 'Projectleider nodigt een lid van het eigen project uit, niet van een ander project'
Controleer ($ps.uitnodigen['lid-0000c1>lid-0000e2'] -and $ps.uitnodigen['lid-0000a2>lid-0000e2']) 'Celleider en head van het vak (SEA) zien en nodigen dat lid uit'
Controleer (-not $ps.uitnodigen['lid-0000c1>lid-0000a2'] -and -not $ps.uitnodigen['lid-0000c1>lid-0000d1']) 'Celleider nodigt geen head of projectleider in zijn cel uit'
Controleer ($ps.uitnodigen['lid-0000b1>lid-0000a2'] -and $ps.uitnodigen['lid-0000b1>lid-0000e4']) 'De beheerder nodigt iedereen uit, ook heads en leden zonder plek'
Controleer ($ps.uitnodigen['lid-0000a3>lid-0000e3'] -and -not $ps.uitnodigen['lid-0000a1>lid-0000e3']) 'Head van een groep (Base) nodigt Base-leden uit; head van SEO niet'
Controleer (-not $ps.uitnodigen['generator>lid-0000e1'] -and -not $ps.uitnodigen['lid-0000e1>lid-0000e1'] -and -not $ps.uitnodigen['lid-zzzzzz>lid-0000e1']) 'De generator, het lid zelf en een onbekend id mogen niet'
Controleer ($ps.toevoegen['lid-0000d1>ecom-b2b||seo'] -and -not $ps.toevoegen['lid-0000d1>lg-b2c||seo']) 'Nieuw lid: projectleider alleen in het eigen project'
Controleer ($ps.toevoegen['lid-0000a2>|ecom|sea'] -and -not $ps.toevoegen['lid-0000a2>|ecom|seo']) 'Nieuw lid: head SEA voegt een SEA-collega toe in cel Ecom, geen SEO-collega'

Write-Host '2. JavaScript geeft exact hetzelfde'
$js = & node (Join-Path $PSScriptRoot 'regelstest.mjs') $uit
if ($LASTEXITCODE) { throw "Node-deel mislukt: $js" }
$jsr = Get-Content (Join-Path $uit 'js.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$verschil = @()
foreach ($deel in 'rol', 'uitnodigen', 'toevoegen') { foreach ($k in $ps[$deel].Keys) { if ([bool]$jsr.$deel.$k -ne [bool]$ps[$deel][$k]) { $verschil += "$deel $k" } } }
foreach ($k in $ps.kijkers.Keys) { if ((@($jsr.kijkers.$k) -join ',') -ne (@($ps.kijkers[$k]) -join ',')) { $verschil += "kijkers $k" } }
Controleer (-not $verschil.Count) "Kijkers, rollen, uitnodigen en toevoegen gelijk in PowerShell en JavaScript ($($ps.uitnodigen.Count + $ps.toevoegen.Count) gevallen)$(if ($verschil.Count) { ': ' + (($verschil | Select-Object -First 5) -join '; ') })"

if ($fouten) { Write-Host "`n$fouten fout(en)" -ForegroundColor Red; exit 1 } else { Write-Host "`nRegelstest geslaagd" -ForegroundColor Green }
