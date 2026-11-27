# Zet een skilllijst-Excel (zelfde opzet als de SEO-sheet) om naar sjablonen/<vak>/skilllijst.csv, zodat het vak meedoet.
#   beheer\skilllijst-omzetten.ps1 -Xlsx "C:\...\CRO skills.xlsx" -Vak cro            schrijft sjablonen\cro\skilllijst.csv
#   beheer\skilllijst-omzetten.ps1 -Xlsx ... -Vak cro -Toon                              alleen laten zien, niets schrijven
# Opzet sheet: rij 1 = kop; A = hoofdgebied, B = onderwerp, C = vaardigheid met een streepje ervoor ("- met GA4"),
# of zonder streepje een inleidende zin (wordt de context van de vaardigheden eronder). Scores in de sheet doen niet mee.
# Kolommen na J met de kop Niveau, Wat je concreet kunt, Bewijs, Ontwikkelactie, Uitleg of Toelichting worden de uitleg
# bij die vaardigheid (csv-kolom uitleg; niet notitie, want een notitie betekent "verouderd").
# Meer tabbladen (uitleg, een blad per persoon, zoals bij SEA) mag: een blad met vaardigheden telt, bij meer de meeste scores, anders het eerste (zie Read-DlXlsx).
# Id's: hoofdgebied.onderwerp.vaardigheid (1.2.3), op volgorde. Bestaat de csv al, dan blijven notities bij dezelfde
# vaardigheid staan; let op dat id's verschuiven als je in het midden iets toevoegt (oude scores en lessen verwijzen naar id's).
param([Parameter(Mandatory)][string]$Xlsx, [Parameter(Mandatory)][string]$Vak, [switch]$Toon)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
. (Join-Path $App 'app\lib\skilllijst.ps1')
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($inst.vakken | Where-Object { $_.id -eq $Vak -and $_.soort -eq 'groep' }).Count) { throw "'$Vak' is een groep in het organogram, zonder eigen lessen of skilllijst." }
if (@($inst.vakken.id) -notcontains $Vak) { throw "Onbekend vak '$Vak'. Voeg het eerst toe aan instellingen.json ($(@($inst.vakken.id) -join ', '))." }
$uit = Join-Path $App "sjablonen\$Vak\skilllijst.csv"

# Notities uit een bestaande lijst bewaren (sleutel: onderwerp + vaardigheid)
$notities = @{}
if (Test-Path $uit) { foreach ($r in Import-Csv $uit -Delimiter ';' -Encoding UTF8) { if ($r.notitie) { $notities["$(Get-DlSleutelTekst $r.onderwerp)|$(Get-DlSleutelTekst $r.vaardigheid)"] = $r.notitie } } }

$schoon = { param($t) ((Repair-DlTekst "$t") -replace ';', ',' -replace '\s+', ' ').Trim() }
$rijen = Read-DlXlsx (Resolve-Path $Xlsx).Path
# Uitlegkolommen (na J, zoals bij CRO): kop Niveau, Wat je concreet kunt, Bewijs, Ontwikkelactie, Uitleg of Toelichting.
# Per vaardigheid worden ze "Kop: tekst", gescheiden door " | ", in de kolom uitleg (de website toont ze als uitleg).
$uitlegKol = @($rijen[1].Keys | Where-Object { $_ -notmatch '^[A-J]$' -and "$($rijen[1][$_])" -match '^\s*(niveau|wat je|bewijs|ontwikkel|uitleg|toelichting)' } |
    Sort-Object { $_.Length }, { $_ })
$lijst = @(); $hg = ''; $ond = ''; $ctx = ''; $nHg = 0; $nOnd = 0; $nIt = 0; $zonderPlek = 0
foreach ($r in ($rijen.Keys | Sort-Object)) {
    if ($r -eq 1) { continue }
    $c = $rijen[$r]
    if ($c.A) { $hg = & $schoon $c.A; $nHg++; $nOnd = 0; $ond = ''; $ctx = '' }
    if ($c.B) { $ond = & $schoon $c.B; $nOnd++; $nIt = 0; $ctx = '' }
    if (-not $c.C) { continue }
    $t = & $schoon $c.C
    if ($t -notmatch '^[-–•]') { $ctx = $t -replace '[:,]\s*$', ''; continue }    # inleidende zin
    if (-not $nHg -or -not $nOnd) { $zonderPlek++; continue }
    $nIt++
    $vaardigheid = ($t -replace '^[-–•]\s*', '')
    $lijst += [pscustomobject][ordered]@{
        id = "$nHg.$nOnd.$nIt"; hoofdgebied = $hg; onderwerp = $ond; context = $ctx; vaardigheid = $vaardigheid
        notitie = [string]$notities["$(Get-DlSleutelTekst $ond)|$(Get-DlSleutelTekst $vaardigheid)"]
        uitleg = (@($uitlegKol | Where-Object { $c[$_] } | ForEach-Object { "$(& $schoon $rijen[1][$_]): $(& $schoon $c[$_])" -replace '\s*\|\s*', ' / ' }) -join ' | ')
    }
}
if (-not $lijst.Count) { throw 'Geen vaardigheden gevonden. Staan ze in kolom C met een streepje ervoor ("- ...")?' }
if ($zonderPlek) { Write-Warning "$zonderPlek vaardigheid(en) overgeslagen: geen hoofdgebied (kolom A) of onderwerp (kolom B) erboven." }

$hgs = @($lijst | Group-Object hoofdgebied)
Write-Host "$($lijst.Count) vaardigheden in $($hgs.Count) hoofdgebieden, $(@($lijst | Select-Object -Unique onderwerp).Count) onderwerpen:"
foreach ($g in $hgs) { Write-Host ("  {0,-40} {1,4}" -f $g.Name, $g.Count) }
$metUitleg = [bool]@($lijst | Where-Object uitleg).Count
if ($metUitleg) { Write-Host "Met uitleg per vaardigheid uit: $(@($uitlegKol | ForEach-Object { $rijen[1][$_] }) -join ', ')" }
if ($Toon) { $lijst | Format-Table id, onderwerp, context, vaardigheid, uitleg -AutoSize | Out-String -Width 220 | Write-Host; return }

New-Item -ItemType Directory (Split-Path $uit) -Force | Out-Null
$velden = @('id', 'hoofdgebied', 'onderwerp', 'context', 'vaardigheid', 'notitie') + @(if ($metUitleg) { 'uitleg' })
$tekst = (@($velden -join ';') + @($lijst | ForEach-Object { $it = $_; ($velden | ForEach-Object { $it.$_ }) -join ';' })) -join "`n"
[IO.File]::WriteAllText($uit, $tekst + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Geschreven: $uit" -ForegroundColor Green
Write-Host "Daarna: committen op staging, testen in de demo, en een head aanwijzen: beheer\beheer.ps1 -Head lid-xxxxxx -Vak $Vak"
