# Lessen die de head of SEO (of een lesmaker uit organisatie.json) op de website maakte, opnemen in de kennisbank.
# Een voorstel staat in doubleleren-data/voorstellen/<les-id>.json als {"v":2,"door":<id>,"inhoud":<les als JSON-tekst>,"sig"}.
# Alleen opgenomen met een geldige handtekening van een lesmaker en als de les de controle doorstaat; daarna verwijderd.
# Draait automatisch aan het begin van generator-context.ps1. De nieuwe lessen gaan mee met generator-publiceer.ps1 -Push.
param([string]$DataMap, [string]$Thuis, [switch]$Proef)   # -Proef: niets verwijderen of versturen
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
. (Join-Path $PSScriptRoot 'lescontrole.ps1'); . (Join-Path $PSScriptRoot 'kloon.ps1')
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
$geheim = Read-DlGeneratorGeheim $Thuis
$kloon = $null
if (-not $DataMap) { $kloon = Get-DlKloon $Thuis; if ($kloon) { Update-DlKloon $kloon; $DataMap = $kloon } }
$d = if ($DataMap) { New-DlOpslag -Map $DataMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token }
$V = (Get-Content (Join-Path $App 'vertrouwd.json') -Raw -Encoding UTF8 | ConvertFrom-Json).beheer   # beheersleutel: controleert alles onder beheer/
$org = Read-DlBeheer $d 'organisatie.json' $V
$makers = @(@($org.head) + @($org.lesmakers) | Where-Object { $_ })

$opgenomen = 0; $afgewezen = 0
foreach ($naam in @(Get-DlOpslagLijst $d 'voorstellen' | Where-Object { $_ -like '*.json' })) {
    $r = Read-DlOpslag $d "voorstellen/$naam"; if (-not $r) { continue }
    $id = [IO.Path]::GetFileNameWithoutExtension($naam)
    try {
        $env = $script:DlUtf8.GetString($r.bytes) | ConvertFrom-Json
        if ([int]$env.v -ne 2 -or $makers -notcontains $env.door -or $env.inhoud -isnot [string]) { throw 'niet van een lesmaker' }
        $s = Read-DlBeheer $d "sleutels/$($env.door).json" $V
        $geldig = $false
        foreach ($pub in @(@($s.publiek) + @($s.eerdere) | Where-Object { $_ })) { if (Test-DlHandtekening $pub "voorstel|$id" $env.door $env.inhoud $env.sig) { $geldig = $true; break } }
        if (-not $geldig) { throw 'handtekening ongeldig' }
        $les = $env.inhoud | ConvertFrom-Json
        $fouten = Test-DlLes $les $id $env.inhoud.Length
        if ($les.herkomst -ne 'team') { $fouten += 'herkomst moet team zijn' }
        if ($fouten.Count) { throw ($fouten -join '; ') }
        $doel = Join-Path $App "lessen\$id.json"
        if (Test-Path $doel) { throw 'er bestaat al een les met dit id' }
        [IO.File]::WriteAllText($doel, $env.inhoud, (New-Object Text.UTF8Encoding($false)))
        Write-Host "  les van het team opgenomen: $id"; $opgenomen++
    } catch { Write-Host "  voorstel $naam afgewezen: $($_.Exception.Message)"; $afgewezen++ }
    if (-not $Proef) { Remove-DlOpslag $d "voorstellen/$naam" $r.sha }
}
if ($kloon -and -not $Proef) { Push-DlKloon $kloon }
if ($opgenomen) { & (Join-Path $PSScriptRoot 'lessen-index.ps1') }
if ($opgenomen -or $afgewezen) { Write-Host "Voorstellen: $opgenomen opgenomen, $afgewezen afgewezen." }
