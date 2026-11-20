# Eind-tot-eindtest met lokale mappen i.p.v. GitHub: uitnodigen, installeren, goedkeuren, toegang per rol,
# aanvalsscenario's, herstel, organogramwijziging, dagcyclus en optioneel leren. Testpersonen hebben neutrale namen.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\e2e.ps1 [-Xlsx "C:\...\skilllijst.xlsx"]
# Zonder -Xlsx gebruikt de test een nep-skilllijst uit het sjabloon (test\nep-skilllijst.ps1).
param([string]$Xlsx, [string]$Werk = (Join-Path $env:TEMP 'doubleleren-e2e'))
$ErrorActionPreference = 'Stop'
$bron = Split-Path $PSScriptRoot -Parent
if (-not $Xlsx) {
    $Xlsx = Join-Path $env:TEMP 'doubleleren-nep-skilllijst.xlsx'
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\nep-skilllijst.ps1" -Uit $Xlsx | Out-Null
    if (-not (Test-Path $Xlsx)) { throw 'Nep-skilllijst maken mislukt' }
}
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
foreach ($n in 'Foxtrot', 'Golf', 'Delta', 'Bravo') { Beheer -Goedkeuren $ids[$n] -Controlewoorden $res[$n].controlewoorden | Out-Null }
Beheer -AutoGoedkeuren | Out-Null
Controleer (@('Alfa', 'Echo', 'Charlie' | Where-Object { Test-Path "$D\beheer\toegang\$($ids[$_]).json" }).Count -eq 0 -and @(Get-ChildItem "$D\aanvragen").Count -eq 3) 'AutoGoedkeuren laat heads en leiders liggen: die keurt de beheerder goed met controlewoorden'
foreach ($n in 'Alfa', 'Echo', 'Charlie') { Beheer -Goedkeuren $ids[$n] -Controlewoorden $res[$n].controlewoorden | Out-Null }
Controleer (-not (Get-ChildItem "$D\aanvragen" -ErrorAction SilentlyContinue)) 'Alle aanvragen verwerkt'
$orgG = Read-DlBeheer $dO 'organisatie.json' $V
Controleer (@($ids.Keys | Where-Object { $orgG.leden.($ids[$_]).goedgekeurd }).Count -eq 7 -and [int]$orgG.versie -gt 0) 'Elke goedkeuring staat ondertekend in het organogram (markering), met een versienummer'
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
# Nieuwslessen gaan vooraan (laatste 14 dagen): uit de testkopie, zodat de test niet van de datum afhangt
Get-ChildItem "$A\lessen" -Filter *.json | Where-Object Name -ne 'index.json' | Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).type -eq 'nieuws' } | Remove-Item
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\lessen-index.ps1" | Out-Null
# De testlessen hebben een cel nodig (anders krijgt iemand in een cel ze niet): zoals de generator ze labelt
foreach ($l in '20261019-srm', '20261019-query-fan-out') { $o = Get-Content "$A\lessen\$l.json" -Raw -Encoding UTF8 | ConvertFrom-Json; $o | Add-Member cel 'alle' -Force; [IO.File]::WriteAllText("$A\lessen\$l.json", ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false))) }
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
Beheer -AutoGoedkeuren | Out-Null
Controleer (Test-Path "$D\aanvragen\$($ids.Golf).json") 'AutoGoedkeuren laat herstel (code kwijt) liggen voor handmatige controle'
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

# De generator werkt ieders stand bij (ook wie nooit de nieuwe website opende), en respecteert verbergen
$ce = Get-DlClient -Thuis "$T\Echo"; $sE = Get-DlEigenSleutels $ce
Update-DlVersleuteld $ce.data $ce.id 'profiel' $sE { param($h) $o = [ordered]@{}; foreach ($p in $h.PSObject.Properties) { $o[$p.Name] = $p.Value }; $o.scorebord = $false; $o } $ce.id $ce.prive $ce.publiek | Out-Null
$sbUit = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\scorebord-bijwerken.ps1" -DataMap $D -Thuis "$T\beheer"
$sbD = Read-DlScore $dO $maand $ids.Delta $null $V; $sbE = Read-DlScore $dO $maand $ids.Echo $null $V
Controleer ($sbD -and $sbD.obj.zichtbaar -and $sbD.obj.goed -eq 0 -and $sbE -and $sbE.obj.zichtbaar -eq $false -and -not $sbE.obj.PSObject.Properties['goed']) "Generator zet iedereen op het scorebord, verborgen blijft verborgen ($(@($sbUit) -join ' '))"
$ok = $true; try { Read-DlScore $dO $maand $ids.Delta $null ([pscustomobject]@{ kty = 'RSA'; n = $cg.prive.n; e = $cg.prive.e }) | Out-Null } catch { $ok = $false }
Controleer (-not $ok) 'Scorebord namens de generator met een andere sleutel wordt geweigerd'

# Eigen prioriteit per hoofdgebied (zoals de website hem in de skilllijst zet) komt mee in de generatorcontext
Update-DlVersleuteld $cf.data $cf.id 'matrix' $sF { param($h) $o = [ordered]@{}; foreach ($p in $h.PSObject.Properties) { $o[$p.Name] = $p.Value }; $o.prioriteit = [ordered]@{ '9' = 3; '2' = 1; 'x' = 1; '4' = 7 }; $o } $cf.id $cf.prive $cf.publiek | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
$prioF = (Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json).leden.($ids.Foxtrot).prioriteit; Remove-Item "$T\beheer\generator\context.json"
Controleer ($prioF.'9' -eq 3 -and $prioF.'2' -eq 1 -and -not $prioF.x -and -not $prioF.'4') 'Eigen prioriteit per hoofdgebied komt mee in de generatorcontext (ongeldige waarden niet)'

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

# Halfjaarlijkse check: blokkeert de pop-up niet meer (de website herinnert eraan); er komt gewoon een les
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Snapshot "$Werk\snap-ronde" -Thuis "$T\Echo"
Controleer ((Test-Path "$Werk\snap-ronde\2-opdracht.png") -and -not (Test-Path "$Werk\snap-ronde\0-skilllijst.png")) 'Halfjaarlijkse check blokkeert de pop-up niet: gewoon een les'
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$A\app\dagelijkse-les.ps1" -Snapshot "$Werk\snap-ronde2" -Datum '2027-01-15' -Thuis "$T\Echo"
Controleer ((Test-Path "$Werk\snap-ronde2\2-opdracht.png") -and -not (Test-Path "$Werk\snap-ronde2\0-skilllijst.png")) 'Vóór de deadline: gewoon de les (de website toont een melding)'
$rD = Get-DlRonde ([pscustomobject]@{ scores = [pscustomobject]@{ '1.1.1' = [pscustomobject]@{ '2027-01' = 3 } } }) '2026-10-19' ([datetime]'2027-02-03')
$rN = Get-DlRonde $null '2026-12-01' ([datetime]'2027-02-03')
Controleer ($rD.voldaan -and -not $rD.teLaat -and $rN.vrij -and -not $rN.teLaat) 'Bijgewerkt in januari of pas in december aangemeld: niet geblokkeerd'

Write-Host '14. Aparte generatorsleutel (omzetting op een draaiend systeem)'
$wFox = Read-DlOpslag $dO "data/$($ids.Foxtrot)/wachtrij.enc"            # nog ondertekend met de oude (gedeelde) sleutel
Beheer -NieuweGeneratorsleutel | Out-Null
$G = Get-DlGeneratorPubliek $dO $V
$vNa = (Get-Content "$A\vertrouwd.json" -Raw | ConvertFrom-Json).beheer
Controleer ($G -and $G.n -ne $V.n -and $vNa.n -eq $V.n) 'Nieuwe generatorsleutel ondertekend gepubliceerd; beheersleutel en vertrouwd.json ongewijzigd'
$gvf = Get-DlVingerafdrukHex $G
$alleT = @($ids.Keys | ForEach-Object { Read-DlBeheer $dO "toegang/$($ids[$_]).json" $V } | Where-Object { $_ })
Controleer (@($alleT | Where-Object { $_.vingerafdrukken.generator -ne $gvf }).Count -eq 0) "Generatorkopie van alle $($alleT.Count) deelnemers omgezet"
$alle = @($personen.Keys)
$okZicht = $true; foreach ($lid in 'Foxtrot', 'Delta', 'Alfa') { $kan = @($alle | Where-Object { KanOpenen $_ $lid }); if ((($kan | Sort-Object) -join ',') -ne (($verwacht[$lid] | Sort-Object) -join ',') -and $lid -ne 'Golf') { $okZicht = $false } }
Controleer $okZicht 'Wie wat kan openen is onveranderd'
$cf = Get-DlClient -Thuis "$T\Foxtrot"; $sF = Get-DlEigenSleutels $cf
$ok = $true; try { Read-DlVersleuteld $cf.data $cf.id 'wachtrij' $sF $cf.publiek | Out-Null } catch { $ok = $false }
Controleer $ok 'Oude wachtrij (oude sleutel) wordt nog geaccepteerd'
$uitB = Beheer -NieuweGeneratorsleutel
Controleer (-not (($uitB -join ' ') -match 'omgezet')) 'Opnieuw draaien verandert niets (hervatbaar)'
# Dagcyclus met de nieuwe sleutel
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
$ctx = Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json
[IO.File]::WriteAllText("$T\beheer\generator\wachtrijen.json", (@{ $ids.Delta = @('20261019-srm') } | ConvertTo-Json))
$sbOud = Read-DlScore $dO $maand $ids.Delta $null $V                        # door de generator met de oude sleutel: blijft geldig
Remove-Item "$D\scorebord\$maand\$($ids.Delta).json"                       # zodat de generator hem nu met de nieuwe sleutel schrijft
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-publiceer.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
$cd = Get-DlClient -Thuis "$T\Delta"; $sD = Get-DlEigenSleutels $cd
$wD = Read-DlVersleuteld $cd.data $cd.id 'wachtrij' $sD $cd.publiek
$envD = $script:DlUtf8.GetString((Unprotect-Dl $sD "$($cd.id)|wachtrij" (Read-DlOpslag $dO "data/$($cd.id)/wachtrij.enc").bytes)).Trim() | ConvertFrom-Json
Controleer (@($ctx.leden.PSObject.Properties).Count -ge 7 -and $wD.obj.lessen -contains '20261019-srm' -and (Test-DlHandtekening $G "$($cd.id)|wachtrij" 'generator' $envD.inhoud $envD.sig)) 'Generator draait met de nieuwe sleutel; wachtrij ondertekend met de nieuwe sleutel en geaccepteerd'
$sbD = Read-DlScore $dO $maand $ids.Delta $null $G
Controleer ($sbOud -and $sbD -and $sbD.obj.zichtbaar) 'Scorebord: oude handtekening bleef geldig, nieuw bestand ondertekend met de nieuwe generatorsleutel'
# Nieuwe deelnemer na de omzetting
$uit = Beheer -Uitnodigen -Naam India -Rol lid -Project ecom-b2b
$ids.India = ([regex]::Match(($uit -join "`n"), 'lid-[0-9a-f]{6}')).Value
$res.India = Installeer $ids.India 'India' @('-Xlsx', $Xlsx)
$aI = Read-DlJson $dO "aanvragen/$($ids.India).json"
$ok = $true; try { Unprotect-DlRsa (Read-DlGeheim "$T\beheer\beheer.dpapi").generatorPrive (ConvertFrom-B64u $aI.toegang.generator) | Out-Null } catch { $ok = $false }
Beheer -Goedkeuren $ids.India -Controlewoorden $res.India.controlewoorden | Out-Null
$tI = Read-DlBeheer $dO "toegang/$($ids.India).json" $V
Controleer ($ok -and $tI -and $tI.vingerafdrukken.generator -eq $gvf -and (KanOpenen 'India' 'India') -and (KanOpenen 'Delta' 'India')) 'Nieuwe aanmelding: kopie voor de nieuwe generatorsleutel, goedgekeurd, leidinggevende ziet India'
# Feedback na de omzetting: beheerder én generator kunnen hem lezen
$fbN = New-DlFeedback $dO $ids.Delta $cd.prive @{ beheer = $V; generator = $G } 'toevoeging' 'Na de omzetting' ''
$gh = Read-DlGeheim "$T\beheer\beheer.dpapi"
$fG = Read-DlFeedback $dO "$fbN.json" 'generator' $gh.generatorPrive $cd.publiek; $fB = Read-DlFeedback $dO "$fbN.json" 'beheer' $gh.beheerPrive $cd.publiek
$fbUit = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\feedback.ps1" -Nieuw -DataMap $D -Thuis "$T\beheer") -join "`n"
Controleer ($fG.tekst -eq 'Na de omzetting' -and $fB.tekst -eq 'Na de omzetting' -and $fbUit -match 'Na de omzetting') 'Feedback leesbaar voor beheerder en generator'
Controleer ($gh.beheerPrive.n -eq $V.n -and $gh.generatorPrive.n -eq $G.n -and -not $gh.generatorNieuw) 'Beheergeheimen: beheersleutel en generatorsleutel apart bewaard'

Write-Host '15. Cloudmodus: generatorsleutel uit de omgeving, proefrun publiceert niets'
$C = Join-Path $Werk 'cloud'; New-Item -ItemType Directory $C -Force | Out-Null      # geen beheer.dpapi: zoals op een GitHub-runner
$env:DL_GENERATOR_SLEUTEL = ((Read-DlGeheim "$T\beheer\beheer.dpapi").generatorPrive | ConvertTo-Json -Compress)
try {
    New-Item -ItemType Directory "$D\voorstellen" -Force | Out-Null
    [IO.File]::WriteAllText("$D\voorstellen\proef-test.json", '{"v":2,"door":"lid-000000","inhoud":"{}","sig":"x"}')
    $wVoor = Get-DlSha1 ([IO.File]::ReadAllBytes("$D\data\$($ids.Delta)\wachtrij.enc"))
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis $C -Proef | Out-Null
    $ctxC = Get-Content "$C\generator\context.json" -Raw | ConvertFrom-Json
    [IO.File]::WriteAllText("$C\generator\wachtrijen.json", (@{ $ids.Delta = @('20261019-query-fan-out') } | ConvertTo-Json))
    $uitP = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-publiceer.ps1" -DataMap $D -Thuis $C -Proef) -join ' '
    Controleer (@($ctxC.leden.PSObject.Properties).Count -ge 8 -and $uitP -match 'PROEF: [1-9]\d* wachtrij' -and (Get-DlSha1 ([IO.File]::ReadAllBytes("$D\data\$($ids.Delta)\wachtrij.enc"))) -eq $wVoor -and (Test-Path "$D\voorstellen\proef-test.json") -and -not (Test-Path "$C\generator\context.json")) 'Proefrun met de sleutel uit de omgeving: alles gecontroleerd, niets gewijzigd, context opgeruimd'
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis $C | Out-Null
    [IO.File]::WriteAllText("$C\generator\wachtrijen.json", (@{ $ids.Delta = @('20261019-query-fan-out') } | ConvertTo-Json))
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-publiceer.ps1" -DataMap $D -Thuis $C | Out-Null
    $wD = Read-DlVersleuteld $cd.data $cd.id 'wachtrij' $sD $cd.publiek
    Controleer ($wD.obj.lessen -contains '20261019-query-fan-out' -and -not (Test-Path "$D\voorstellen\proef-test.json") -and -not (Get-ChildItem $C -Recurse -Filter *.dpapi)) 'Echte run in cloudmodus: wachtrij geplaatst, voorstellen verwerkt, nergens een DPAPI-bestand nodig'
} finally { Remove-Item Env:\DL_GENERATOR_SLEUTEL -ErrorAction SilentlyContinue }

Write-Host '16. Leren van feedback: context, lessen herzien en uit de roulatie, bescherming van teamlessen'
. "$A\beheer\lescontrole.ps1"
# Reactie na de les, zoals de site en de pop-up hem in de eigen logregel zetten: Foxtrot vond zijn eerste les te makkelijk
$cR = Get-DlClient -Thuis "$T\Foxtrot"; $sR = Get-DlEigenSleutels $cR
$curR = Read-DlOpslag $dO "data/$($ids.Foxtrot)/log-$maand.enc"; $regR = @((Read-DlVersleuteld $cR.data $cR.id "log-$maand" $sR $cR.publiek).obj.regels)
$regR[0] | Add-Member reactie 'makkelijk' -Force
Write-DlVersleuteld $dO $ids.Foxtrot "log-$maand" $sR ([ordered]@{ v = 1; regels = $regR }) $curR.sha $cR.id $cR.prive | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
$ctx = Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json
Controleer ($ctx.lesstatistiek.($regR[0].id).makkelijk -ge 1 -and @($ctx.leden.($ids.Foxtrot).resultaten | Where-Object { $_.reactie -eq 'makkelijk' }).Count -eq 1) 'Context: reactie na de les per les geteld en bij de eigen resultaten'
$fbC = @($ctx.feedback)
Controleer ($ctx.lesstatistiek.'20261019-srm'.n -ge 1 -and $ctx.lesstatistiek.'20261019-srm'.fout -ge 1) 'Context: resultaten per les over het hele team'
Controleer (@($fbC | Where-Object tekst -eq 'Na de omzetting').Count -eq 1 -and -not ($fbC | Where-Object { $_.PSObject.Properties.Name -contains 'door' }) -and -not ((ConvertTo-Json $fbC -Depth 4) -match 'lid-[0-9a-f]{6}')) 'Context: feedback zonder afzender en zonder pseudoniemen'
Controleer (-not ($fbC | Where-Object tekst -eq 'Vals namens Foxtrot') -and -not ($fbC | Where-Object tekst -match 'Afronden reageert')) 'Context: vervalste feedback en feedback zonder generatorkopie overgeslagen'
Controleer ($ctx.leden.($ids.Delta).cel -eq 'ecom' -and @($ctx.cellen) -contains 'leadgen') 'Context: cel per deelnemer (ook via het project) en de lijst met cellen'
Remove-Item "$T\beheer\generator\context.json"
# Vaste beginstand voor de checks hieronder: les 20261019-srm zoals hij oorspronkelijk was (nooit herzien, het juiste
# antwoord ruim het langst). Zo hangt de test niet af van wat de generator later aan de echte les verandert.
$srm = Get-Content "$A\lessen\20261019-srm.json" -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($v in 'herzien', 'wijziging', 'actief', 'cel') { $srm.PSObject.Properties.Remove($v) }
$jSrm = [int]$srm.opdracht.juist
$maxSrm = (@(0..3 | Where-Object { $_ -ne $jSrm } | ForEach-Object { "$($srm.opdracht.opties[$_])".Length }) | Measure-Object -Maximum).Maximum
while ("$($srm.opdracht.opties[$jSrm])".Length -le 1.1 * $maxSrm) { $srm.opdracht.opties[$jSrm] += ', ook als het verschil klein lijkt' }
[IO.File]::WriteAllText("$A\lessen\20261019-srm.json", ($srm | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
# Controle van herzien-velden
$basis = Get-Content "$A\lessen\20261019-srm.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$l1 = $basis.PSObject.Copy(); $l1 | Add-Member actief $false -Force
$l2 = $basis.PSObject.Copy(); $l2 | Add-Member herzien '2026-10-21' -Force; $l2 | Add-Member wijziging "Gemeld door $($ids.Delta)" -Force
$l3 = $basis.PSObject.Copy(); $l3 | Add-Member actief $false -Force; $l3 | Add-Member herzien '2026-10-21' -Force; $l3 | Add-Member wijziging 'Verouderd' -Force
Controleer ((Test-DlLes $l1 $basis.id 1000).Count -gt 0 -and (Test-DlLes $l2 $basis.id 1000).Count -gt 0 -and (Test-DlLes $l3 $basis.id 1000).Count -eq 0) 'Lescontrole: uit roulatie alleen met datum, geen pseudoniem in de reden'
# Publiceren met een git-kopie van de app-repo, zoals in de cloud
$teamLes = $basis.PSObject.Copy(); $teamLes.id = '20261020-teamles'; $teamLes | Add-Member herkomst 'team' -Force
[IO.File]::WriteAllText("$A\lessen\20261020-teamles.json", ($teamLes | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
function G { $ErrorActionPreference = 'Continue'; git -C $A @args 2>&1 | Out-Null }
G init -q; G config user.email test@test.invalid; G config user.name test; G config core.autocrlf false; G add -A; G commit -q -m basis
function Publiceer($wachtrij) {
    $ErrorActionPreference = 'Continue'
    [IO.File]::WriteAllText("$T\beheer\generator\wachtrijen.json", (@{ $ids.Delta = $wachtrij } | ConvertTo-Json))
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-publiceer.ps1" -DataMap $D -Thuis "$T\beheer" 2>&1 | ForEach-Object { "$_" }) -join ' '
    [pscustomobject]@{ ok = $LASTEXITCODE -eq 0; uit = $o }
}
function ZetLes($id, [hashtable]$velden) { $l = Get-Content "$A\lessen\$id.json" -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in $velden.Keys) { $l | Add-Member $k $velden[$k] -Force }; [IO.File]::WriteAllText("$A\lessen\$id.json", ($l | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false))) }
function Titel($id) { (Get-Content "$A\lessen\$id.json" -Raw -Encoding UTF8 | ConvertFrom-Json).titel }
$tTeam = Titel '20261020-teamles'; $tSrm = Titel '20261019-srm'
ZetLes '20261020-teamles' @{ titel = 'Aangepast door de generator'; herzien = '2026-10-21' }
$p1 = Publiceer @('20261019-srm')
Controleer ($p1.ok -and $p1.uit -match 'teruggedraaid: 20261020-teamles.json \(een teamles wordt nooit' -and (Titel '20261020-teamles') -eq $tTeam) 'Teamles aangepast: teruggedraaid, de rest wordt gewoon gepubliceerd'
$idx1 = (Get-Content "$A\lessen\index.json" -Raw -Encoding UTF8 | ConvertFrom-Json).lessen
Controleer (($idx1 | Where-Object id -eq '20261019-srm').juistLangst -eq $true -and -not ($idx1 | Where-Object id -eq '20261019-query-fan-out').juistLangst) 'Index: meerkeuze met het juiste antwoord ruim het langst gemarkeerd als te raden'
ZetLes '20261019-srm' @{ titel = 'Stil aangepast' }
$p2 = Publiceer @('20261019-srm')
$ok2 = $p2.ok -and $p2.uit -match 'herzien-datum' -and (Titel '20261019-srm') -eq $tSrm
ZetLes '20261019-srm' @{ herkomst = 'team'; herzien = '2026-10-21' }
$p3 = Publiceer @('20261019-srm')
$ok3 = $p3.ok -and $p3.uit -match 'herkomst' -and -not (Get-Content "$A\lessen\20261019-srm.json" -Raw | ConvertFrom-Json).herkomst
Remove-Item "$A\lessen\20261019-srm.json"
$p4 = Publiceer @('20261019-query-fan-out')
$ok4 = $p4.ok -and $p4.uit -match 'nooit verwijderd' -and (Test-Path "$A\lessen\20261019-srm.json")
ZetLes '20261019-srm' @{ actief = $false }
$p6 = Publiceer @('20261019-query-fan-out')
$ok6 = $p6.ok -and $p6.uit -match 'herzien-datum nodig' -and (Get-Content "$A\lessen\20261019-srm.json" -Raw | ConvertFrom-Json).actief -ne $false
Controleer ($ok2 -and $ok3 -and $ok4 -and $ok6) 'Eigen les zonder herzien-datum, met andere herkomst, verwijderd of ongeldig: teruggedraaid, run gaat door'
# Cel van de case: alleen 'cel' erbij is geen herziening; een ongeldige cel of cel plus een andere wijziging wel
ZetLes '20261019-srm' @{ cel = 'Leadgen B2B' }
$p7 = Publiceer @('20261019-query-fan-out')
$ok7 = $p7.ok -and $p7.uit -match 'teruggedraaid: 20261019-srm.json \(cel moet' -and -not (Get-Content "$A\lessen\20261019-srm.json" -Raw | ConvertFrom-Json).cel
ZetLes '20261019-srm' @{ cel = 'ecom'; titel = 'Stil aangepast' }
$p9 = Publiceer @('20261019-query-fan-out')
$ok9 = $p9.ok -and $p9.uit -match 'herzien-datum nodig' -and (Titel '20261019-srm') -eq $tSrm
ZetLes '20261019-srm' @{ cel = 'leadgen' }
$p8 = Publiceer @('20261019-query-fan-out')
$lCel = Get-Content "$A\lessen\20261019-srm.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$ok8 = $p8.ok -and $p8.uit -match 'cel bepaald: 20261019-srm.json \(leadgen\)' -and $lCel.cel -eq 'leadgen' -and -not $lCel.herzien -and ((Get-Content "$A\lessen\index.json" -Raw -Encoding UTF8 | ConvertFrom-Json).lessen | Where-Object id -eq '20261019-srm').cel -eq 'leadgen'
Controleer ($ok7 -and $ok8 -and $ok9) 'Cel van een les: alleen cel erbij mag zonder herzien-datum; ongeldige cel of meer veranderd: teruggedraaid'
ZetLes '20261019-srm' @{ actief = $false; herzien = '2026-10-21'; wijziging = 'Vraag was dubbelzinnig; vervangen door een nieuwe les.' }
$p5 = Publiceer @('20261019-srm', '20261019-query-fan-out')
$idxA = Get-Content "$A\lessen\index.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wD = Read-DlVersleuteld $cd.data $cd.id 'wachtrij' $sD $cd.publiek
Controleer ($p5.ok -and $p5.uit -match 'uit de roulatie' -and ($idxA.lessen | Where-Object id -eq '20261019-srm').actief -eq $false -and $wD.obj.lessen -notcontains '20261019-srm' -and $wD.obj.lessen -contains '20261019-query-fan-out') 'Les uit de roulatie: in de index gemarkeerd en uit de wachtrij gehaald'
Remove-Item "$A\.git" -Recurse -Force

Write-Host '17. Regelaar: plan per persoon, werkbestand zonder scores, cel en regels bij het toewijzen'
$G = "$T\beheer\generator"
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
$werkT = Get-Content "$G\werk.json" -Raw -Encoding UTF8; $werkO = $werkT | ConvertFrom-Json
Controleer ((Test-Path "$G\regelaar.json") -and $werkT -notmatch '"(scores|resultaten|gedaan|prioriteit|antwoord|antwoorden)"\s*:' -and $werkT -notmatch 'Alfa|Bravo|Foxtrot' -and @($werkO.personen.PSObject.Properties).Count -ge 1) 'Werkbestand voor Claude: zonder scores, resultaten, namen of antwoorden'
$rpO = Get-Content "$G\regelaar.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$planOk = $true
foreach ($p in $rpO.leden.PSObject.Properties) {
    $pl = @($p.Value.plekken)
    if (@($pl | Where-Object type -eq 'herhaling').Count -gt 1 -or @($pl | Where-Object type -eq 'verdieping').Count -gt 1 -or @($pl | Where-Object { -not $_.vaardigheid -or $_.niveau -notin 'basis', 'gevorderd', 'expert' }).Count -or (@($p.Value.open).Count + $pl.Count) -gt 5) { $planOk = $false }
}
Controleer $planOk 'Plan: hooguit 5 lessen, één herhaling en één verdieping per persoon, elke plek met vaardigheid en niveau'
# Twee lessen een cel geven en Delta (cel ecom) beide als wens geven: de leadgen-les valt af, de les voor alle cellen staat vooraan
$vrij = @((Get-Content "$A\lessen\index.json" -Raw -Encoding UTF8 | ConvertFrom-Json).lessen | Where-Object { $_.soort -eq 'meerkeuze' -and $_.actief -ne $false -and -not $_.juistLangst -and -not $_.vormAfwijkend -and @($_.matrix).Count -and -not @($_.matrix | Where-Object { "$_" -like '*:*' }).Count -and @($rpO.leden.($ids.Delta).gedaan) -notcontains $_.id } | Select-Object -First 2)
foreach ($x in @(@($vrij[0].id, 'leadgen'), @($vrij[1].id, 'alle'))) { $o = Get-Content "$A\lessen\$($x[0]).json" -Raw -Encoding UTF8 | ConvertFrom-Json; $o | Add-Member cel $x[1] -Force; [IO.File]::WriteAllText("$A\lessen\$($x[0]).json", ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false))) }
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\lessen-index.ps1" | Out-Null
[IO.File]::WriteAllText("$G\wachtrijen.json", (@{ $ids.Delta = @{ wensen = @($vrij[0].id, $vrij[1].id) } } | ConvertTo-Json -Depth 4))
$uitR = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\regelaar.ps1" -Stap toewijzen -Map $G -App $A 2>&1 | ForEach-Object { "$_" }) -join ' '
$qR = Get-Content "$G\wachtrijen.json" -Raw | ConvertFrom-Json
$idxR = @((Get-Content "$A\lessen\index.json" -Raw -Encoding UTF8 | ConvertFrom-Json).lessen)
$regelsOk = $true
foreach ($p in $qR.PSObject.Properties) {
    $cel = $rpO.leden.($p.Name).cel; $ls = @($p.Value | ForEach-Object { $x = $_; $idxR | Where-Object id -eq $x })
    if ($ls.Count -ne @($p.Value).Count -or @($ls | Where-Object { $cel -and $_.herkomst -ne 'team' -and $_.cel -ne 'alle' -and $_.cel -ne $cel }).Count -or @($ls | Where-Object { @($rpO.leden.($p.Name).gedaan) -contains $_.id }).Count -or @($ls | Where-Object soort -ne 'meerkeuze').Count -gt 1) { $regelsOk = $false }
}
Controleer ($regelsOk -and $qR.($ids.Delta) -contains $vrij[1].id -and $qR.($ids.Delta) -notcontains $vrij[0].id -and $uitR -match '1 wens\(en\) genegeerd') 'Toewijzen: alleen eigen cel of alle, nooit een gedane les, hooguit één schrijfopdracht; wens voor alle cellen erin, wens van een andere cel geweigerd'
Remove-Item "$G\context.json", "$G\werk.json", "$G\regelaar.json", "$G\wachtrijen.json" -ErrorAction SilentlyContinue

Write-Host '18. Reactie na de les in de regelaar: meer, te makkelijk en niet relevant'
$vids = @(([IO.File]::ReadAllText("$A\sjablonen\seo\skilllijst.csv", [Text.Encoding]::UTF8) | ConvertFrom-Csv -Delimiter ';') | Select-Object -First 30 | ForEach-Object { $_.id })
$X = $vids[0]; $Y = $vids[10]; $Z = $vids[20]
function Res($dag, $vid, $uitslag, $reactie) { $o = [ordered]@{ datum = "${dag}T09:00:00"; les = "test-$dag-$vid"; resultaat = $uitslag; matrix = @($vid); niveau = 'basis'; soort = 'meerkeuze' }; if ($reactie) { $o.reactie = $reactie }; $o }
function LidMet($res) { [ordered]@{ cel = $null; vakken = @{ seo = 1 }; scores = @{}; prioriteit = @{}; resultaten = @($res); gedaan = @(); wachtrij = @() } }
# Persoon 1: wil meer over X (10 dagen geleden), vindt Y niet relevant en Z te makkelijk (40 dagen geleden: anders altijd verdieping
# of herhaling). Persoon 2: wilde meer over X, maar kreeg er daarna al een les over.
$ctxR = [ordered]@{ v = 1; vakgebied = 'seo'; vakken = @('seo'); cellen = @(); lesstatistiek = @{}; feedback = @(); leden = [ordered]@{
    'lid-aaaaa1' = (LidMet @((Res '2026-11-21' $X 'goed' 'meer'), (Res '2026-10-22' $Y 'goed' 'niet-relevant'), (Res '2026-10-22' $Z 'fout' 'makkelijk')))
    'lid-aaaaa2' = (LidMet @((Res '2026-11-21' $X 'goed' 'meer'), (Res '2026-11-26' $X 'goed' $null))) } }
$MR = "$Werk\regelaar-reactie"; New-Item -ItemType Directory $MR -Force | Out-Null
[IO.File]::WriteAllText("$MR\context.json", ($ctxR | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
$okR = $true
foreach ($zaad in 1..5) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\regelaar.ps1" -Stap plan -Map $MR -App $A -Zaad $zaad -Vandaag '2026-12-01' | Out-Null
    $rR = Get-Content "$MR\regelaar.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    $p1 = @($rR.leden.'lid-aaaaa1'.plekken); $p2 = @($rR.leden.'lid-aaaaa2'.plekken); $gv = @($p1 | Where-Object { $_.gevraagd })
    if ($gv.Count -ne 1 -or $gv[0].vaardigheid -ne $X -or $gv[0].type -ne 'verdieping' -or $gv[0].niveau -ne 'gevorderd') { $okR = $false }
    if (@($p1 | Where-Object { $_.vaardigheid -in $Y, $Z -and $_.type -in 'herhaling', 'verdieping' }).Count -or @($p1 | Where-Object type -eq 'verdieping').Count -gt 1) { $okR = $false }
    if (@($p2 | Where-Object { $_.gevraagd }).Count) { $okR = $false }
}
Controleer $okR 'Regelaar: "meer" geeft binnen 10 dagen één verdieping (niet als er al een les over kwam); "niet relevant" en "te makkelijk" geen herhaling of verdieping'
Remove-Item $MR -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '19. Groep zonder eigen lessen: een trainee in cel Ecom'
$uitK = Beheer -Uitnodigen -Naam Kilo -Rol lid -Cel ecom -Vak trainee
$ids.Kilo = ([regex]::Match(($uitK -join "`n"), 'lid-[0-9a-f]{6}')).Value
$res.Kilo = Installeer $ids.Kilo 'Kilo' @()     # zonder skilllijst
Beheer -AutoGoedkeuren | Out-Null
$vertrouwdK = (Get-Content "$A\vertrouwd.json" -Raw | ConvertFrom-Json).beheer   # $V is eerder hergebruikt (PowerShell: $v = $V)
$orgK = Read-DlBeheer $dO 'organisatie.json' $vertrouwdK; $kijkK = @(Get-DlKijkers $orgK $ids.Kilo)
Controleer ($orgK.leden.($ids.Kilo).vak -eq 'trainee' -and $kijkK -contains $ids.Bravo -and $kijkK -notcontains $ids.Alfa -and (Test-Path "$D\beheer\toegang\$($ids.Kilo).json")) 'Trainee: groep als eigen vak, aangemeld zonder skilllijst; celleider ziet hem, de head van SEO niet'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\generator-context.ps1" -DataMap $D -Thuis "$T\beheer" | Out-Null
$ctxK = Get-Content "$T\beheer\generator\context.json" -Raw | ConvertFrom-Json
Controleer ($ctxK.leden.($ids.Kilo).vak -eq 'trainee' -and -not @($ctxK.leden.($ids.Kilo).vakken.PSObject.Properties).Count) 'Context: trainee zonder gekozen vak krijgt (nog) geen lessen'
Remove-Item "$T\beheer\generator\context.json", "$T\beheer\generator\werk.json", "$T\beheer\generator\regelaar.json" -ErrorAction SilentlyContinue

Write-Host '18. Beheer in de cloud: sleutels uit de omgeving, alleen gewone leden, nooit een sleutelwissel'
$CB = Join-Path $Werk 'cloud-beheer'; New-Item -ItemType Directory $CB -Force | Out-Null      # geen beheer.dpapi: zoals op een runner
$gb = Read-DlGeheim "$T\beheer\beheer.dpapi"; $V = (Get-Content "$A\vertrouwd.json" -Raw | ConvertFrom-Json).beheer
$script:cloudBeheer = $gb.beheerPrive
function BeheerCloud {
    $env:DL_BEHEER_SLEUTEL = ($script:cloudBeheer | ConvertTo-Json -Compress); $env:DL_GENERATOR_SLEUTEL = ($gb.generatorPrive | ConvertTo-Json -Compress)
    try {
        $ErrorActionPreference = 'Continue'
        $uit = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\beheer.ps1" @args -DataMap $D -Thuis $CB 2>&1 | ForEach-Object { "$_" }
        $script:codeCloud = $LASTEXITCODE; $uit
    } finally { Remove-Item Env:\DL_BEHEER_SLEUTEL, Env:\DL_GENERATOR_SLEUTEL -ErrorAction SilentlyContinue }
}
function Nieuw([string]$naam, [string[]]$rol) {
    $u = Beheer -Uitnodigen -Naam $naam @rol; $ids[$naam] = ([regex]::Match(($u -join "`n"), 'lid-[0-9a-f]{6}')).Value
    $res[$naam] = Installeer $ids[$naam] $naam @()
}
# Gewoon lid: goedgekeurd zonder controlewoorden en zonder iets op schijf
Nieuw 'Lima' @('-Rol', 'lid', '-Project', 'ecom-b2b')
BeheerCloud -AutoGoedkeuren | Out-Null
$orgC = Read-DlBeheer $dO 'organisatie.json' $V
Controleer ($script:codeCloud -eq 0 -and (Test-Path "$D\beheer\toegang\$($ids.Lima).json") -and $orgC.leden.($ids.Lima).goedgekeurd -and -not (Get-ChildItem $CB -Recurse -Filter *.dpapi)) 'Cloud keurt een gewoon lid goed, met markering, zonder DPAPI-bestand'
# Head: blijft liggen tot de beheerder het met controlewoorden goedkeurt
Nieuw 'Mike' @('-Rol', 'head', '-Vak', 'cro')
$uitM = BeheerCloud -AutoGoedkeuren
Controleer ($script:codeCloud -eq 2 -and (Test-Path "$D\aanvragen\$($ids.Mike).json") -and -not (Test-Path "$D\beheer\toegang\$($ids.Mike).json") -and ($uitM -join ' ') -match 'controlewoorden') 'Cloud laat een head liggen (exitcode 2)'
$uitM = BeheerCloud -Goedkeuren $ids.Mike -Controlewoorden $res.Mike.controlewoorden
Controleer ($script:codeCloud -ne 0 -and -not (Test-Path "$D\beheer\toegang\$($ids.Mike).json")) 'Ook rechtstreeks keurt de cloud geen head goed'
Beheer -Goedkeuren $ids.Mike -Controlewoorden $res.Mike.controlewoorden | Out-Null
Controleer (Test-Path "$D\beheer\toegang\$($ids.Mike).json") 'De beheerder keurt de head goed op de laptop'
# Herstel (code kwijt) blijft handwerk
$hL = Installeer $ids.Lima 'Lima-2' @('-Herstel')
BeheerCloud -AutoGoedkeuren | Out-Null
Controleer ($script:codeCloud -eq 2 -and (Test-Path "$D\aanvragen\$($ids.Lima).json")) 'Herstel blijft liggen in de cloud (exitcode 2)'
Beheer -Goedkeuren $ids.Lima -Controlewoorden $hL.controlewoorden | Out-Null
# Overname: iemand wist sleutel en toegang van India en meldt zich opnieuw als India aan
$sPad = "$D\beheer\sleutels\$($ids.India).json"; $tPadI = "$D\beheer\toegang\$($ids.India).json"
$sOud = [IO.File]::ReadAllBytes($sPad); $tOud = [IO.File]::ReadAllBytes($tPadI)
$dataI = "$D\data\$($ids.India)"; $kopieI = "$Werk\india-data"; Copy-Item $dataI $kopieI -Recurse      # de aanvaller overschrijft ook zijn profiel
Remove-Item $sPad, $tPadI
Installeer $ids.India 'India-aanvaller' @() | Out-Null
$uitI = BeheerCloud -AutoGoedkeuren
Controleer ($script:codeCloud -eq 2 -and -not (Test-Path $sPad) -and ($uitI -join ' ') -match 'overname') 'Overname geweigerd: India was al eens goedgekeurd (markering in het organogram)'
[IO.File]::WriteAllBytes($sPad, $sOud); [IO.File]::WriteAllBytes($tPadI, $tOud); Remove-Item "$D\aanvragen\$($ids.India).json"
Remove-Item $dataI -Recurse -Force; Copy-Item $kopieI $dataI -Recurse
# Sleutelwissel nodig (Delta is geen projectleider meer, zonder -Bijwerken): de cloud laat die toegang ongemoeid
Nieuw 'November' @('-Rol', 'lid', '-Project', 'ecom-b2b')
$orgR = Read-DlBeheer $dO 'organisatie.json' $V
$pR = @($orgR.cellen | ForEach-Object { $_.projecten } | Where-Object id -eq 'ecom-b2b')[0]; $pR.leider = $null
$orgR | Add-Member -NotePropertyName versie -NotePropertyValue ([int]$orgR.versie + 1) -Force
Write-DlBeheer $dO 'organisatie.json' $orgR $gb.beheerPrive
$tFoxVoor = [IO.File]::ReadAllBytes("$D\beheer\toegang\$($ids.Foxtrot).json")
$uitR = BeheerCloud -AutoGoedkeuren
$tFoxNa = [IO.File]::ReadAllBytes("$D\beheer\toegang\$($ids.Foxtrot).json")
Controleer ($script:codeCloud -eq 2 -and (Test-Path "$D\beheer\toegang\$($ids.November).json") -and [Convert]::ToBase64String($tFoxVoor) -eq [Convert]::ToBase64String($tFoxNa) -and ($uitR -join ' ') -match 'Sleutelwissel nodig') 'Cloud keurt November goed maar laat de toegang van Foxtrot byte voor byte gelijk (wissel nodig, exitcode 2)'
Beheer -Bijwerken | Out-Null
Controleer (-not (KanOpenen 'Delta' 'Foxtrot') -and (KanOpenen 'Foxtrot' 'Foxtrot') -and (KanOpenen 'Bravo' 'Foxtrot')) 'Daarna wisselt de laptop wél: Delta ziet Foxtrot niet meer, Foxtrot en de celleider wel'
$orgR = Read-DlBeheer $dO 'organisatie.json' $V
$pR = @($orgR.cellen | ForEach-Object { $_.projecten } | Where-Object id -eq 'ecom-b2b')[0]; $pR.leider = $ids.Delta
$orgR | Add-Member -NotePropertyName versie -NotePropertyValue ([int]$orgR.versie + 1) -Force
Write-DlBeheer $dO 'organisatie.json' $orgR $gb.beheerPrive
Beheer -Bijwerken | Out-Null
Controleer (KanOpenen 'Delta' 'Foxtrot') 'Delta weer projectleider: ziet Foxtrot weer'
# Verkeerde sleutel (bijv. die van een andere omgeving): stopt vóór er iets verandert
$orgVoor = [IO.File]::ReadAllBytes("$D\beheer\organisatie.json")
$script:cloudBeheer = (New-DlSleutelpaar 3072).prive
$uitW = BeheerCloud -AutoGoedkeuren
$script:cloudBeheer = $gb.beheerPrive
Controleer ($script:codeCloud -ne 0 -and ($uitW -join ' ') -match 'vertrouwd.json' -and [Convert]::ToBase64String($orgVoor) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes("$D\beheer\organisatie.json"))) 'Verkeerde beheersleutel: gestopt, organogram ongewijzigd'
# Een ouder (wel ondertekend) organogram terugzetten
$orgOud = [IO.File]::ReadAllBytes("$D\beheer\organisatie.json")
Beheer -Wijzig $ids.Hotel -Leren optioneel | Out-Null
$orgNieuw = [IO.File]::ReadAllBytes("$D\beheer\organisatie.json")
[IO.File]::WriteAllBytes("$D\beheer\organisatie.json", $orgOud)
$uitO = Beheer -Controleer
$env:DL_ORG_VERSIE_MIN = [string]([int](Read-DlBeheer $dO 'organisatie.json' $V).versie + 1)
try { $uitOC = BeheerCloud -AutoGoedkeuren } finally { Remove-Item Env:\DL_ORG_VERSIE_MIN }
Controleer (($uitO -join ' ') -match 'oudere versie' -and $script:codeCloud -ne 0 -and ($uitOC -join ' ') -match 'oudere versie') 'Teruggezet ouder organogram: laptop en cloud weigeren'
[IO.File]::WriteAllBytes("$D\beheer\organisatie.json", $orgNieuw)
# Wat alleen op de laptop mag
$uitL = BeheerCloud -Bijwerken
Controleer ($script:codeCloud -ne 0 -and ($uitL -join ' ') -match 'alleen op de laptop') 'Cloud weigert acties die alleen op de laptop mogen'

# Voor test\site-demo.ps1: testcodes (alleen in de tijdelijke testmap)
$res.Golf = $h
$testcodes = @{}; foreach ($k in $res.Keys) { if ($res[$k].code) { $testcodes[$k] = $res[$k].code } }
[IO.File]::WriteAllText("$Werk\codes.json", ([ordered]@{ ids = $ids; codes = $testcodes; token = $TOKEN } | ConvertTo-Json -Depth 4))

if ($fouten) { Write-Host "`n$fouten fout(en)" -ForegroundColor Red; exit 1 } else { Write-Host "`nEind-tot-eindtest geslaagd" -ForegroundColor Green }
