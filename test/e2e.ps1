# Eind-tot-eindtest met lokale mappen i.p.v. GitHub: uitnodigen, installeren, goedkeuren, toegang per rol,
# aanvalsscenario's, herstel, organogramwijziging, dagcyclus en optioneel leren. Testpersonen hebben neutrale namen.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\e2e.ps1 -Xlsx "C:\...\skilllijst.xlsx"
param([Parameter(Mandatory)][string]$Xlsx, [string]$Werk = (Join-Path $env:TEMP 'doubleleren-e2e'))
$ErrorActionPreference = 'Stop'
$bron = Split-Path $PSScriptRoot -Parent
Remove-Item $Werk -Recurse -Force -ErrorAction SilentlyContinue
$A = Join-Path $Werk 'app'; $B = Join-Path $Werk 'beheer'; $D = Join-Path $Werk 'data'; $T = Join-Path $Werk 'thuis'
New-Item -ItemType Directory $A, $B, $D, $T -Force | Out-Null
Copy-Item (Join-Path $bron '*') $A -Recurse -Exclude '.git', 'test'
$TOKEN = 'github_pat_TESTTOKEN_alleen_lokaal_0000'
$fouten = 0
function Controleer([bool]$ok, [string]$wat) { if ($ok) { Write-Host "  OK    $wat" } else { Write-Host "  FOUT  $wat" -ForegroundColor Red; $script:fouten++ } }
function Beheer { $ErrorActionPreference = 'Continue'; & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\beheer.ps1" @args -DataMap $D -BeheerMap $B -Thuis "$T\beheer" 2>&1 | ForEach-Object { "$_" } }
function Installeer($id, $naam, [string[]]$extra) {
    $json = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\app\installeer.ps1" -Stil -Uitnodiging "${id}:$TOKEN" -Naam $naam -Thuis "$T\$naam" -AppMap $A -BeheerMap $B -DataMap $D -GeenTaak @extra
    $json | Select-Object -Last 1 | ConvertFrom-Json
}
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim', 'client', 'organisatie') { . "$A\app\lib\$l.ps1" }
$dO = New-DlOpslag -Map $D; $bO = New-DlOpslag -Map $B
$maand = (Get-Date).ToString('yyyy-MM')

Write-Host '1. Inrichten en uitnodigen'
Beheer -Init | Out-Null
$personen = [ordered]@{
    Alfa = @('-Rol', 'head'); Bravo = @('-Rol', 'celleider', '-Cel', 'ecom'); Charlie = @('-Rol', 'celleider', '-Cel', 'leadgen')
    Delta = @('-Rol', 'projectleider', '-Project', 'ecom-b2b'); Echo = @('-Rol', 'projectleider', '-Project', 'leadgen-b2c')
    Foxtrot = @('-Rol', 'lid', '-Project', 'ecom-b2b'); Golf = @('-Rol', 'lid', '-Project', 'leadgen-b2c')
}
$ids = @{}
foreach ($n in $personen.Keys) { $uit = Beheer -Uitnodigen -Naam $n @($personen[$n]); $ids[$n] = ([regex]::Match(($uit -join "`n"), 'lid-[0-9a-f]{6}')).Value }
Controleer (@($ids.Values | Where-Object { $_ }).Count -eq 7) '7 uitnodigingen'
Controleer (-not (Test-Path "$A\organisatie.json") -and (Test-Path "$B\organisatie.json")) 'Organogram staat in de (privé) beheer-repo, niet in de app-repo'

Write-Host '2. Installeren (leden vóór leidinggevenden)'
$res = @{}
foreach ($n in 'Foxtrot', 'Golf', 'Delta', 'Bravo', 'Alfa', 'Echo', 'Charlie') { $res[$n] = Installeer $ids[$n] $n @('-Xlsx', $Xlsx) }
Controleer (@($res.Values | Where-Object { $_.controlewoorden -split ' ' | Measure-Object | Where-Object Count -eq 6 }).Count -eq 7) '7 aanvragen met 6 controlewoorden'
Controleer (-not (Get-ChildItem $D -Recurse -Filter 'prive-sleutel.json')) 'Geen antwoordensleutel als bestand'

Write-Host '3. Aanval: een collega wisselt de datasleutel in een wachtende aanvraag'
$aPad = "$D\aanvragen\$($ids.Foxtrot).json"
$origineel = [IO.File]::ReadAllText($aPad)
$aanv = $origineel | ConvertFrom-Json
$dkAanvaller = Get-DlWillekeurig 32
$gen = (Read-DlJson $bO 'sleutels/generator.json').publiek
$aanv.toegang.($ids.Foxtrot) = ConvertTo-B64u (Protect-DlRsa $aanv.publiek $dkAanvaller)
$aanv.toegang.generator = ConvertTo-B64u (Protect-DlRsa $gen $dkAanvaller)
[IO.File]::WriteAllText($aPad, ($aanv | ConvertTo-Json -Depth 6))
$uit = Beheer -Goedkeuren $ids.Foxtrot -Controlewoorden $res.Foxtrot.controlewoorden 2>&1
Controleer ((Test-Path $aPad) -and -not (Test-Path "$B\toegang\$($ids.Foxtrot).json")) 'Goedkeuren geweigerd: controlewoorden passen niet meer bij de gewijzigde aanvraag'
[IO.File]::WriteAllText($aPad, $origineel)
$uit = Beheer -Goedkeuren $ids.Golf -Controlewoorden 'aap noot mies wim zus jet' 2>&1
Controleer (-not (Test-Path "$B\toegang\$($ids.Golf).json")) 'Verkeerde controlewoorden: niet goedgekeurd'

Write-Host '4. Goedkeuren'
foreach ($n in 'Foxtrot', 'Golf', 'Delta', 'Bravo', 'Alfa', 'Echo', 'Charlie') { Beheer -Goedkeuren $ids[$n] -Controlewoorden $res[$n].controlewoorden | Out-Null }
Controleer (-not (Get-ChildItem "$D\aanvragen" -ErrorAction SilentlyContinue)) 'Alle aanvragen verwerkt'
Beheer -Controleer

Write-Host '5. Wie kan wat openen'
function KanOpenen($kijker, $lid, $soort = 'matrix') {
    $c = Get-DlClient -Thuis "$T\$kijker"
    try {
        if ($soort -eq 'prive') { $s = Get-DlAk $c.prive } else { $s = Get-DlSleutelsUitDk (Get-DlDk $c.beheer $ids[$lid] $c.id $c.prive) }
        [bool](Read-DlVersleuteld $c.data $ids[$lid] $soort $s $c.publiek)
    } catch { $false }
}
$verwacht = @{
    Foxtrot = @('Foxtrot', 'Delta', 'Bravo', 'Alfa'); Golf = @('Golf', 'Echo', 'Charlie', 'Alfa'); Delta = @('Delta', 'Bravo', 'Alfa')
    Echo = @('Echo', 'Charlie', 'Alfa'); Bravo = @('Bravo', 'Alfa'); Charlie = @('Charlie', 'Alfa'); Alfa = @('Alfa')
}
$alle = @($personen.Keys)
foreach ($lid in $alle) {
    $kan = @($alle | Where-Object { KanOpenen $_ $lid })
    Controleer ((($kan | Sort-Object) -join ',') -eq (($verwacht[$lid] | Sort-Object) -join ',')) ("{0,-8} zichtbaar voor: {1}" -f $lid, ($kan -join ', '))
}

Write-Host '6. Dagcyclus: generator zet lessen klaar, pop-up rondt af'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -BeheerMap $B -Thuis "$T\beheer" | Out-Null
$ctx = Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json
Controleer (@($ctx.leden.PSObject.Properties).Count -eq 7 -and @($ctx.leden.($ids.Foxtrot).scores.PSObject.Properties).Count -eq 144) 'Generatorcontext: 7 deelnemers met scores'
Controleer (-not ((Get-Content "$T\beheer\generator\context.json" -Raw) -match 'Alfa|Bravo|Foxtrot|antwoord')) 'Context bevat geen namen en geen antwoorden'
[IO.File]::WriteAllText("$T\beheer\generator\wachtrijen.json", (@{ $ids.Foxtrot = @('20261019-srm', '20261019-query-fan-out') } | ConvertTo-Json))
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-publiceer.ps1" -DataMap $D -BeheerMap $B -Thuis "$T\beheer" | Out-Null
Controleer (-not (Test-Path "$T\beheer\generator\context.json")) 'Ontsleutelde context is opgeruimd'
foreach ($i in 1, 2) { & powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Snapshot "$Werk\snap$i" -Opslaan -Thuis "$T\Foxtrot" }
if (Test-Path "$T\Foxtrot\fouten.log") { Get-Content "$T\Foxtrot\fouten.log" }
$c = Get-DlClient -Thuis "$T\Foxtrot"; $s = Get-DlEigenSleutels $c
$log = Read-DlVersleuteld $c.data $c.id "log-$maand" $s $c.publiek
Controleer ((@($log.obj.regels.id) -join ',') -eq '20261019-srm,20261019-query-fan-out') "Logboek: $(@($log.obj.regels | ForEach-Object { "$($_.id)=$($_.resultaat)" }) -join ', ')"
$pr = Read-DlVersleuteld $c.data $c.id 'prive' (Get-DlAk $c.prive) $c.publiek
Controleer (@($pr.obj.antwoorden).Count -eq 1) 'Open antwoord staat in het privébestand'
Controleer ((KanOpenen 'Bravo' 'Foxtrot' "log-$maand") -and -not (KanOpenen 'Bravo' 'Foxtrot' 'prive') -and -not (KanOpenen 'Alfa' 'Foxtrot' 'prive')) 'Leidinggevenden zien resultaten, niet de antwoorden'
$groottes = @(Get-ChildItem "$D\data" -Recurse -Filter *.enc | ForEach-Object { $_.Length % 16 -eq 3 -and ($_.Length - 51) % 1024 -lt 32 })
Controleer (-not ($groottes -contains $false)) 'Alle versleutelde bestanden opgevuld tot vaste blokgroottes'

Write-Host '7. Aanval: leidinggevende vervalst een logboek, collega zet een oude versie terug'
$cb = Get-DlClient -Thuis "$T\Bravo"; $sf = Get-DlSleutelsUitDk (Get-DlDk $cb.beheer $ids.Foxtrot $cb.id $cb.prive)
$vals = [ordered]@{ v = 1; regels = @([ordered]@{ datum = (Get-Date).ToString('s'); id = 'vals'; resultaat = 'fout' }) }
$cur = Read-DlOpslag $dO "data/$($ids.Foxtrot)/log-$maand.enc"
Write-DlVersleuteld $dO $ids.Foxtrot "log-$maand" $sf $vals $cur.sha $cb.id $cb.prive | Out-Null      # Bravo ondertekent als zichzelf
$ok = $true; try { Read-DlVersleuteld $c.data $c.id "log-$maand" $s $c.publiek | Out-Null } catch { $ok = $false }
Controleer (-not $ok) 'Logboek ondertekend door een ander dan het lid wordt geweigerd'
Write-DlOpslag $dO "data/$($ids.Foxtrot)/log-$maand.enc" $cur.bytes (Read-DlOpslag $dO "data/$($ids.Foxtrot)/log-$maand.enc").sha | Out-Null   # herstel

Write-Host '8. Code kwijt: nieuwe sleutel en nieuwe datasleutel'
$oudeC = Get-DlClient -Thuis "$T\Golf"
$h = Installeer $ids.Golf 'Golf' @('-Herstel')
Beheer -Goedkeuren $ids.Golf -Controlewoorden $h.controlewoorden | Out-Null
Controleer (KanOpenen 'Golf' 'Golf') 'Golf leest de eigen scores weer'
Controleer (KanOpenen 'Echo' 'Golf') 'Echo (projectleider) ziet Golf nog steeds'
$ok = $true; try { $dk = Get-DlDk $oudeC.beheer $ids.Golf $ids.Golf $oudeC.prive; Read-DlVersleuteld $oudeC.data $ids.Golf 'matrix' (Get-DlSleutelsUitDk $dk) $oudeC.publiek | Out-Null } catch { $ok = $false }
Controleer (-not $ok) 'De oude sleutel (oude code/laptop) opent niets meer'

Write-Host '9. Nieuwe laptop met dezelfde code'
$r = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\app\installeer.ps1" -Stil -Uitnodiging "$($ids.Foxtrot):$TOKEN" -Code ($res.Foxtrot.code.ToUpper() -replace '-', ' ') -Thuis "$T\Foxtrot-2" -AppMap $A -BeheerMap $B -DataMap $D -GeenTaak | Select-Object -Last 1 | ConvertFrom-Json
$c2 = Get-DlClient -Thuis "$T\Foxtrot-2"; Controleer ([bool](Read-DlVersleuteld $c2.data $c2.id 'matrix' (Get-DlEigenSleutels $c2) $c2.publiek)) 'Tweede laptop leest dezelfde gegevens (code in hoofdletters en met spaties)'

Write-Host '10. Organogram wijzigt: Golf verhuist naar Ecom B2B'
$org = Get-Content "$B\organisatie.json" -Raw | ConvertFrom-Json
$org.leden.($ids.Golf).project = 'ecom-b2b'
[IO.File]::WriteAllText("$B\organisatie.json", ($org | ConvertTo-Json -Depth 10))
Beheer -Bijwerken | Out-Null
Controleer ((KanOpenen 'Delta' 'Golf') -and (KanOpenen 'Bravo' 'Golf')) 'Nieuwe leidinggevenden zien Golf'
Controleer (-not (KanOpenen 'Echo' 'Golf') -and -not (KanOpenen 'Charlie' 'Golf')) 'Oude leidinggevenden niet meer (datasleutel vernieuwd)'
Controleer (KanOpenen 'Golf' 'Golf') 'Golf leest de eigen gegevens na de wissel'

Write-Host '11. Optioneel leren'
$uit = Beheer -Uitnodigen -Naam Hotel -Rol projectleider -Project ecom-internationaal -Optioneel
$ids.Hotel = ([regex]::Match(($uit -join "`n"), 'lid-[0-9a-f]{6}')).Value
$res.Hotel = Installeer $ids.Hotel 'Hotel' @('-GeenLessen')
Controleer ($res.Hotel.code -and $res.Hotel.lessen -eq $false) 'Hotel installeert zonder Excel en zonder lessen'
Beheer -Goedkeuren $ids.Hotel -Controlewoorden $res.Hotel.controlewoorden | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -BeheerMap $B -Thuis "$T\beheer" | Out-Null
Controleer (-not (Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json).leden.($ids.Hotel)) 'Generator slaat Hotel over'
$sw = [Diagnostics.Stopwatch]::StartNew(); & powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Thuis "$T\Hotel" -AutoSluit 8
Controleer ($sw.ElapsedMilliseconds -lt 7500) "Pop-up van Hotel toont geen venster ($($sw.ElapsedMilliseconds) ms)"
Beheer -Wijzig $ids.Hotel -Leren verplicht | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -BeheerMap $B -Thuis "$T\beheer" | Out-Null
Controleer ([bool](Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json).leden.($ids.Hotel)) 'Na -Wijzig verplicht: generator neemt Hotel mee'
Remove-Item "$T\beheer\generator\context.json"

Write-Host '12. Wat staat er in de repo''s'
$rauwD = (Get-ChildItem $D -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
Controleer (-not ($rauwD -match 'Voorbeeldantwoord|Sample Ratio|Alfa|Bravo|Foxtrot|"naam"')) 'Data-repo: geen leesbare antwoorden, lestitels of namen'
$rauwA = (Get-ChildItem $A -Recurse -File -Include *.json, *.ps1, *.js, *.md | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
$sj = Get-Content "$A\sjablonen\organisatie-sjabloon.json" -Raw | ConvertFrom-Json
Controleer (-not ($rauwA -match 'lid-[0-9a-f]{6}') -and -not @($sj.leden.PSObject.Properties).Count ) 'App-repo (openbaar): geen leden-id''s en geen namen'

# Voor test\site-demo.ps1: testcodes (alleen in de tijdelijke testmap)
$res.Golf = $h
$testcodes = @{}; foreach ($k in $res.Keys) { if ($res[$k].code) { $testcodes[$k] = $res[$k].code } }
[IO.File]::WriteAllText("$Werk\codes.json", ([ordered]@{ ids = $ids; codes = $testcodes; token = $TOKEN } | ConvertTo-Json -Depth 4))

if ($fouten) { Write-Host "`n$fouten fout(en)" -ForegroundColor Red; exit 1 } else { Write-Host "`nEind-tot-eindtest geslaagd" -ForegroundColor Green }
