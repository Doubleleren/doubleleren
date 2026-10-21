# Eind-tot-eindtest met lokale mappen i.p.v. GitHub: uitnodigen, installeren, goedkeuren, toegang per rol,
# aanvalsscenario's, herstel, organogramwijziging, dagcyclus en optioneel leren. Testpersonen hebben neutrale namen.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\e2e.ps1 -Xlsx "C:\...\skilllijst.xlsx"
param([Parameter(Mandatory)][string]$Xlsx, [string]$Werk = (Join-Path $env:TEMP 'doubleleren-e2e'))
$ErrorActionPreference = 'Stop'
$bron = Split-Path $PSScriptRoot -Parent
Remove-Item $Werk -Recurse -Force -ErrorAction SilentlyContinue
$A = Join-Path $Werk 'app'; $D = Join-Path $Werk 'data'; $T = Join-Path $Werk 'thuis'
New-Item -ItemType Directory $A, $D, $T -Force | Out-Null
Copy-Item (Join-Path $bron '*') $A -Recurse -Exclude '.git', 'test'
$TOKEN = 'github_pat_TESTTOKEN_alleen_lokaal_0000'
$fouten = 0
function Controleer([bool]$ok, [string]$wat) { if ($ok) { Write-Host "  OK    $wat" } else { Write-Host "  FOUT  $wat" -ForegroundColor Red; $script:fouten++ } }
function Beheer { $ErrorActionPreference = 'Continue'; & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\beheer.ps1" @args -DataMap $D -Thuis "$T\beheer" 2>&1 | ForEach-Object { "$_" } }
function Installeer($id, $naam, [string[]]$extra) {
    $json = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\app\installeer.ps1" -Stil -Uitnodiging "${id}:$TOKEN" -Naam $naam -Thuis "$T\$naam" -AppMap $A -DataMap $D -GeenTaak @extra
    $json | Select-Object -Last 1 | ConvertFrom-Json
}
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim', 'client', 'organisatie') { . "$A\app\lib\$l.ps1" }
$dO = New-DlOpslag -Map $D
$maand = (Get-Date).ToString('yyyy-MM')

Write-Host '1. Inrichten en uitnodigen'
Beheer -Init | Out-Null
$V = (Get-Content "$A\vertrouwd.json" -Raw | ConvertFrom-Json).beheer
Controleer ([bool]$V.n) 'vertrouwd.json met de publieke beheersleutel staat in de app-repo'
$personen = [ordered]@{
    Alfa = @('-Rol', 'head'); Bravo = @('-Rol', 'celleider', '-Cel', 'ecom'); Charlie = @('-Rol', 'celleider', '-Cel', 'leadgen')
    Delta = @('-Rol', 'projectleider', '-Project', 'ecom-b2b'); Echo = @('-Rol', 'projectleider', '-Project', 'leadgen-b2c')
    Foxtrot = @('-Rol', 'lid', '-Project', 'ecom-b2b'); Golf = @('-Rol', 'lid', '-Project', 'leadgen-b2c')
}
$ids = @{}
foreach ($n in $personen.Keys) { $uit = Beheer -Uitnodigen -Naam $n @($personen[$n]); $ids[$n] = ([regex]::Match(($uit -join "`n"), 'lid-[0-9a-f]{6}')).Value }
Controleer (@($ids.Values | Where-Object { $_ }).Count -eq 7) '7 uitnodigingen'
Controleer (-not (Test-Path "$A\organisatie.json") -and [bool](Read-DlBeheer $dO 'organisatie.json' $V)) 'Organogram staat ondertekend in de privé data-repo, niet in de app-repo'

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
$gen = $V
$aanv.toegang.($ids.Foxtrot) = ConvertTo-B64u (Protect-DlRsa $aanv.publiek $dkAanvaller)
$aanv.toegang.generator = ConvertTo-B64u (Protect-DlRsa $gen $dkAanvaller)
[IO.File]::WriteAllText($aPad, ($aanv | ConvertTo-Json -Depth 6))
$uit = Beheer -Goedkeuren $ids.Foxtrot -Controlewoorden $res.Foxtrot.controlewoorden 2>&1
Controleer ((Test-Path $aPad) -and -not (Test-Path "$D\beheer\toegang\$($ids.Foxtrot).json")) 'Goedkeuren geweigerd: controlewoorden passen niet meer bij de gewijzigde aanvraag'
[IO.File]::WriteAllText($aPad, $origineel)
$uit = Beheer -Goedkeuren $ids.Golf -Controlewoorden 'aap noot mies wim zus jet' 2>&1
Controleer (-not (Test-Path "$D\beheer\toegang\$($ids.Golf).json")) 'Verkeerde controlewoorden: niet goedgekeurd'

Write-Host '4. Goedkeuren'
foreach ($n in 'Foxtrot', 'Golf', 'Delta', 'Bravo', 'Alfa', 'Echo', 'Charlie') { Beheer -Goedkeuren $ids[$n] -Controlewoorden $res[$n].controlewoorden | Out-Null }
Controleer (-not (Get-ChildItem "$D\aanvragen" -ErrorAction SilentlyContinue)) 'Alle aanvragen verwerkt'
Beheer -Controleer

Write-Host '5. Wie kan wat openen'
function KanOpenen($kijker, $lid, $soort = 'matrix') {
    $c = Get-DlClient -Thuis "$T\$kijker"
    try {
        if ($soort -eq 'prive') { $s = Get-DlAk $c.prive } else { $s = Get-DlSleutelsUitDk (Get-DlDk $c.data $ids[$lid] $c.id $c.prive $c.vertrouwd) }
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
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
$ctx = Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json
Controleer (@($ctx.leden.PSObject.Properties).Count -eq 7 -and @($ctx.leden.($ids.Foxtrot).scores.PSObject.Properties).Count -eq 144) 'Generatorcontext: 7 deelnemers met scores'
Controleer (-not ((Get-Content "$T\beheer\generator\context.json" -Raw) -match 'Alfa|Bravo|Foxtrot|antwoord')) 'Context bevat geen namen en geen antwoorden'
[IO.File]::WriteAllText("$T\beheer\generator\wachtrijen.json", (@{ $ids.Foxtrot = @('20261019-srm', '20261019-query-fan-out') } | ConvertTo-Json))
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-publiceer.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
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
$cb = Get-DlClient -Thuis "$T\Bravo"; $sf = Get-DlSleutelsUitDk (Get-DlDk $cb.data $ids.Foxtrot $cb.id $cb.prive $cb.vertrouwd)
$vals = [ordered]@{ v = 1; regels = @([ordered]@{ datum = (Get-Date).ToString('s'); id = 'vals'; resultaat = 'fout' }) }
$cur = Read-DlOpslag $dO "data/$($ids.Foxtrot)/log-$maand.enc"
Write-DlVersleuteld $dO $ids.Foxtrot "log-$maand" $sf $vals $cur.sha $cb.id $cb.prive | Out-Null      # Bravo ondertekent als zichzelf
$ok = $true; try { Read-DlVersleuteld $c.data $c.id "log-$maand" $s $c.publiek | Out-Null } catch { $ok = $false }
Controleer (-not $ok) 'Logboek ondertekend door een ander dan het lid wordt geweigerd'
Write-DlOpslag $dO "data/$($ids.Foxtrot)/log-$maand.enc" $cur.bytes (Read-DlOpslag $dO "data/$($ids.Foxtrot)/log-$maand.enc").sha | Out-Null   # herstel
# Aanval: een collega met token geeft zichzelf toegang tot Foxtrot door de toegang (beheerbestand) te overschrijven
$tPad = "$D\beheer\toegang\$($ids.Foxtrot).json"; $origT = [IO.File]::ReadAllText($tPad)
$cg = Get-DlClient -Thuis "$T\Golf"
$nep = [ordered]@{ v = 2; door = 'beheer'; inhoud = ([ordered]@{ v = 2; versie = 9; kopieen = @{ $cg.id = 'x' } } | ConvertTo-Json -Compress); sig = (New-DlHandtekening $cg.prive "beheer|toegang/$($ids.Foxtrot).json" 'beheer' 'x') }
[IO.File]::WriteAllText($tPad, ($nep | ConvertTo-Json -Compress))
$ok = $true; try { Read-DlBeheer $dO "toegang/$($ids.Foxtrot).json" $V | Out-Null } catch { $ok = $false }
Controleer (-not $ok) 'Vervalst beheerbestand (toegang) wordt geweigerd: alleen de beheersleutel is geldig'
[IO.File]::WriteAllText($tPad, $origT)

Write-Host '8. Code kwijt: nieuwe sleutel en nieuwe datasleutel'
$oudeC = Get-DlClient -Thuis "$T\Golf"
$h = Installeer $ids.Golf 'Golf' @('-Herstel')
Beheer -Goedkeuren $ids.Golf -Controlewoorden $h.controlewoorden | Out-Null
Controleer (KanOpenen 'Golf' 'Golf') 'Golf leest de eigen scores weer'
Controleer (KanOpenen 'Echo' 'Golf') 'Echo (projectleider) ziet Golf nog steeds'
$ok = $true; try { $dk = Get-DlDk $oudeC.data $ids.Golf $ids.Golf $oudeC.prive $oudeC.vertrouwd; Read-DlVersleuteld $oudeC.data $ids.Golf 'matrix' (Get-DlSleutelsUitDk $dk) $oudeC.publiek | Out-Null } catch { $ok = $false }
Controleer (-not $ok) 'De oude sleutel (oude code/laptop) opent niets meer'

Write-Host '9. Nieuwe laptop met dezelfde code'
$r = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\app\installeer.ps1" -Stil -Uitnodiging "$($ids.Foxtrot):$TOKEN" -Code ($res.Foxtrot.code.ToUpper() -replace '-', ' ') -Thuis "$T\Foxtrot-2" -AppMap $A -DataMap $D -GeenTaak | Select-Object -Last 1 | ConvertFrom-Json
$c2 = Get-DlClient -Thuis "$T\Foxtrot-2"; Controleer ([bool](Read-DlVersleuteld $c2.data $c2.id 'matrix' (Get-DlEigenSleutels $c2) $c2.publiek)) 'Tweede laptop leest dezelfde gegevens (code in hoofdletters en met spaties)'

Write-Host '10. Organogram wijzigt: Golf verhuist naar Ecom B2B'
Beheer -Verplaats $ids.Golf -Project ecom-b2b | Out-Null
Controleer ((KanOpenen 'Delta' 'Golf') -and (KanOpenen 'Bravo' 'Golf')) 'Nieuwe leidinggevenden zien Golf'
Controleer (-not (KanOpenen 'Echo' 'Golf') -and -not (KanOpenen 'Charlie' 'Golf')) 'Oude leidinggevenden niet meer (datasleutel vernieuwd)'
Controleer (KanOpenen 'Golf' 'Golf') 'Golf leest de eigen gegevens na de wissel'

Write-Host '11. Optioneel leren'
$uit = Beheer -Uitnodigen -Naam Hotel -Rol projectleider -Project ecom-internationaal -Optioneel
$ids.Hotel = ([regex]::Match(($uit -join "`n"), 'lid-[0-9a-f]{6}')).Value
$res.Hotel = Installeer $ids.Hotel 'Hotel' @('-GeenLessen')
Controleer ($res.Hotel.code -and $res.Hotel.lessen -eq $false) 'Hotel installeert zonder Excel en zonder lessen'
Beheer -Goedkeuren $ids.Hotel -Controlewoorden $res.Hotel.controlewoorden | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
Controleer (-not (Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json).leden.($ids.Hotel)) 'Generator slaat Hotel over'
$sw = [Diagnostics.Stopwatch]::StartNew(); & powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Thuis "$T\Hotel" -AutoSluit 8
Controleer ($sw.ElapsedMilliseconds -lt 7500) "Pop-up van Hotel toont geen venster ($($sw.ElapsedMilliseconds) ms)"
Beheer -Wijzig $ids.Hotel -Leren verplicht | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
Controleer ([bool](Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json).leden.($ids.Hotel)) 'Na -Wijzig verplicht: generator neemt Hotel mee'
Remove-Item "$T\beheer\generator\context.json"

Write-Host '12. Wat staat er in de repo''s'
$rauwD = (Get-ChildItem $D -Recurse -File | Where-Object { $_.FullName -notmatch '\\data\\beheer\\' } | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
Controleer (-not ($rauwD -match 'Voorbeeldantwoord|Sample Ratio|Alfa|Bravo|Foxtrot|"naam"')) 'Data-repo (buiten beheer/): geen leesbare antwoorden, lestitels of namen'
$rauwB = (Get-ChildItem "$D\beheer" -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
Controleer (-not ($rauwB -match 'Voorbeeldantwoord|Sample Ratio')) 'Beheerbestanden (privé repo): alleen organogram en sleutels, geen antwoorden of lestitels'
$rauwA = (Get-ChildItem $A -Recurse -File -Include *.json, *.ps1, *.js, *.md | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
$sj = Get-Content "$A\sjablonen\organisatie-sjabloon.json" -Raw | ConvertFrom-Json
Controleer (-not ($rauwA -match 'lid-[0-9a-f]{6}') -and -not @($sj.leden.PSObject.Properties).Count ) 'App-repo (openbaar): geen leden-id''s en geen namen'

Write-Host '13. Scorebord, feedback en halfjaarlijkse check'
$cf = Get-DlClient -Thuis "$T\Foxtrot"; $pubF = & $cf.publiek $ids.Foxtrot
$sbPad = "$D\scorebord\$maand\$($ids.Foxtrot).json"
$sb = Read-DlScore $dO $maand $ids.Foxtrot $pubF
Controleer ($sb -and $sb.obj.zichtbaar -and $sb.obj.goed -eq 0 -and $sb.obj.langsteReeks -eq 1) "Pop-up schreef bij het afronden het scorebord (goed $($sb.obj.goed), langste reeks $($sb.obj.langsteReeks))"
Controleer (-not ([IO.File]::ReadAllText($sbPad) -match 'Foxtrot|"naam"|antwoord|titel')) 'Scorebord bevat geen naam, lestitels of antwoorden'
$voor = Get-DlSha1 ([IO.File]::ReadAllBytes($sbPad)); $logVoor = Get-DlSha1 ([IO.File]::ReadAllBytes("$D\data\$($ids.Foxtrot)\log-$maand.enc"))
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Test -LesBestand "$bron\test\testles.json" -AutoSluit 3 -Thuis "$T\Foxtrot"
Controleer ((Get-DlSha1 ([IO.File]::ReadAllBytes($sbPad))) -eq $voor -and (Get-DlSha1 ([IO.File]::ReadAllBytes("$D\data\$($ids.Foxtrot)\log-$maand.enc"))) -eq $logVoor) 'Test-pop-up verandert scorebord en logboek niet'
# Aanval: Golf zet een vals scorebord neer namens Foxtrot
$cg = Get-DlClient -Thuis "$T\Golf"; $echt = [IO.File]::ReadAllText($sbPad)
$valsIn = "{`"v`":1,`"maand`":`"$maand`",`"zichtbaar`":true,`"goed`":99,`"langsteReeks`":20,`"huidigeReeks`":20,`"laatsteDag`":null}"
[IO.File]::WriteAllText($sbPad, ([ordered]@{ v = 2; door = $ids.Foxtrot; inhoud = $valsIn; sig = (New-DlHandtekening $cg.prive "scorebord|$maand|$($ids.Foxtrot)" $ids.Foxtrot $valsIn) } | ConvertTo-Json -Compress))
$ok = $true; try { Read-DlScore $dO $maand $ids.Foxtrot $pubF | Out-Null } catch { $ok = $false }
Controleer (-not $ok) 'Scorebord ondertekend door een ander dan het lid wordt geweigerd'
# Verbergen (zoals de schakelaar op de website): de keuze staat in het eigen, versleutelde profiel; daarna houdt ook de
# pop-up de cijfers weg, ook als een collega de openbare scorebordbestanden verwijdert
[IO.File]::WriteAllText($sbPad, $echt)
$sF = Get-DlEigenSleutels $cf
Update-DlVersleuteld $cf.data $cf.id 'profiel' $sF { param($h) $o = [ordered]@{}; foreach ($p in $h.PSObject.Properties) { $o[$p.Name] = $p.Value }; $o.scorebord = $false; $o } $cf.id $cf.prive $cf.publiek | Out-Null
Remove-Item "$D\scorebord" -Recurse -Force
$logsF = @((Read-DlVersleuteld $cf.data $cf.id "log-$maand" $sF $cf.publiek).obj.regels)
Write-DlScorebord $cf $logsF (Get-DlScorebordZichtbaar $cf $sF)
$sb = Read-DlScore $dO $maand $ids.Foxtrot $pubF
Controleer ((-not (Get-DlScorebordZichtbaar $cf $sF)) -and $sb.obj.zichtbaar -eq $false -and -not $sb.obj.PSObject.Properties['goed']) 'Verborgen blijft verborgen (keuze in het eigen profiel): geen cijfers in het bestand'
Update-DlVersleuteld $cf.data $cf.id 'profiel' $sF { param($h) $o = [ordered]@{}; foreach ($p in $h.PSObject.Properties) { if ($p.Name -ne 'scorebord') { $o[$p.Name] = $p.Value } }; $o } $cf.id $cf.prive $cf.publiek | Out-Null
[IO.File]::WriteAllText($sbPad, $echt)

# Feedback: versleuteld naar de beheerder, met naam alleen voor de beheerder
$cd = Get-DlClient -Thuis "$T\Delta"
$fb1 = New-DlFeedback $dO $ids.Delta $cd.prive @{ beheer = $V } 'bug' 'De knop Afronden reageert niet op mijn laptop' ''
Controleer (-not ([IO.File]::ReadAllText("$D\feedback\$fb1.json") -match 'Afronden|Delta|bug')) 'Feedbackbestand verraadt geen naam, soort of tekst'
$fbUit1 = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\feedback.ps1" -Nieuw -DataMap $D -Thuis "$T\beheer") -join "`n"
$fbUit2 = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\feedback.ps1" -Nieuw -DataMap $D -Thuis "$T\beheer") -join "`n"
Controleer ($fbUit1 -match '1 nieuw' -and $fbUit1 -match 'Delta' -and $fbUit1 -match 'Afronden reageert niet' -and $fbUit2 -match 'niets nieuws') 'Beheerder ziet nieuwe feedback met naam, één keer'
New-DlFeedback $dO $ids.Foxtrot $cg.prive @{ beheer = $V } 'goed' 'Vals namens Foxtrot' '' | Out-Null
$fbUit3 = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\feedback.ps1" -Nieuw -DataMap $D -Thuis "$T\beheer") -join "`n"
Controleer ($fbUit3 -match '1 overgeslagen' -and -not ($fbUit3 -match 'Vals namens')) 'Feedback met een valse handtekening wordt overgeslagen en gemeld'

# Halfjaarlijkse check: na de deadline toont de pop-up geen les maar de weg naar de skilllijst, en telt niets mee
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Snapshot "$Werk\snap-ronde" -Opslaan -Datum '2027-02-03' -Thuis "$T\Echo"
Controleer ((Test-Path "$Werk\snap-ronde\0-skilllijst.png") -and -not (Test-Path "$Werk\snap-ronde\2-opdracht.png") -and -not (Test-Path "$D\data\$($ids.Echo)\log-$maand.enc")) 'Na 31 januari zonder bijgewerkte skilllijst: geen les, niets opgeslagen'
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Snapshot "$Werk\snap-ronde2" -Datum '2027-01-15' -Thuis "$T\Echo"
Controleer ((Test-Path "$Werk\snap-ronde2\2-opdracht.png") -and -not (Test-Path "$Werk\snap-ronde2\0-skilllijst.png")) 'Vóór de deadline: gewoon de les (de website toont een melding)'
$rD = Get-DlRonde ([pscustomobject]@{ scores = [pscustomobject]@{ '1.1.1' = [pscustomobject]@{ '2027-01' = 3 } } }) '2026-10-19' ([datetime]'2027-02-03')
$rN = Get-DlRonde $null '2026-12-01' ([datetime]'2027-02-03')
Controleer ($rD.voldaan -and -not $rD.teLaat -and $rN.vrij -and -not $rN.teLaat) 'Bijgewerkt in januari of pas in december aangemeld: niet geblokkeerd'

# Voor test\site-demo.ps1: testcodes (alleen in de tijdelijke testmap)
$res.Golf = $h
$testcodes = @{}; foreach ($k in $res.Keys) { if ($res[$k].code) { $testcodes[$k] = $res[$k].code } }
[IO.File]::WriteAllText("$Werk\codes.json", ([ordered]@{ ids = $ids; codes = $testcodes; token = $TOKEN } | ConvertTo-Json -Depth 4))

if ($fouten) { Write-Host "`n$fouten fout(en)" -ForegroundColor Red; exit 1 } else { Write-Host "`nEind-tot-eindtest geslaagd" -ForegroundColor Green }
