# Test van beheer in de cloud met een echte git-kopie (zoals op een GitHub-runner), met een lokale kale repo als origin:
# goedkeuren met een mislukte stap ertussen, gelijktijdig versturen, een botsing, en een teruggezet ouder organogram.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\cloud-git.ps1
param([string]$Werk = (Join-Path $env:TEMP 'doubleleren-cloud-git'))
$ErrorActionPreference = 'Stop'
$bron = Split-Path $PSScriptRoot -Parent
Remove-Item $Werk -Recurse -Force -ErrorAction SilentlyContinue
$A = Join-Path $Werk 'app'; $O = Join-Path $Werk 'origin.git'; $Z = Join-Path $Werk 'zaad'; $TB = Join-Path $Werk 'beheer'; $T = Join-Path $Werk 'thuis'
New-Item -ItemType Directory $A, $Z, $TB, $T -Force | Out-Null
Copy-Item (Join-Path $bron '*') $A -Recurse -Exclude '.git', 'test'
$TOKEN = 'github_pat_TESTTOKEN_alleen_lokaal_0000'
$fouten = 0
function Controleer([bool]$ok, [string]$wat) { if ($ok) { Write-Host "  OK    $wat" } else { Write-Host "  FOUT  $wat" -ForegroundColor Red; $script:fouten++ } }
function G { $ErrorActionPreference = 'Continue'; & git @args 2>&1 | ForEach-Object { "$_" } }
function Zet([string]$Map, [string]$Bericht) { G -C $Map add -A | Out-Null; G -C $Map -c user.name=test -c user.email=test@test.invalid commit -q -m $Bericht | Out-Null; G -C $Map push -q | Out-Null }
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim', 'organisatie') { . "$A\app\lib\$l.ps1" }
. "$A\beheer\kloon.ps1"

Write-Host '1. Opzetten: kale repo, organogram, drie aanmeldingen'
G init -q --bare -b main $O | Out-Null
G -C $Z init -q -b main | Out-Null; G -C $Z remote add origin $O | Out-Null
function BeheerZaad { $ErrorActionPreference = 'Continue'; & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\beheer.ps1" @args -DataMap $Z -Thuis $TB 2>&1 | ForEach-Object { "$_" } }
BeheerZaad -Init | Out-Null
BeheerZaad -NieuweGeneratorsleutel | Out-Null
$ids = @{}
foreach ($n in 'Een', 'Twee', 'Drie') { $u = BeheerZaad -Uitnodigen -Naam $n -Rol lid -Project ecom-b2b; $ids[$n] = ([regex]::Match(($u -join "`n"), 'lid-[0-9a-f]{6}')).Value }
foreach ($n in 'Een', 'Twee', 'Drie') { & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\app\installeer.ps1" -Stil -Uitnodiging "$($ids[$n]):$TOKEN" -Naam $n -Thuis "$T\$n" -AppMap $A -DataMap $Z -GeenTaak | Out-Null }
G -C $Z add -A | Out-Null; G -C $Z -c user.name=test -c user.email=test@test.invalid commit -q -m start | Out-Null; G -C $Z push -q -u origin main | Out-Null
$K = Join-Path $T 'cloud\data-kloon'; G clone -q $O $K | Out-Null
$gb = Read-DlGeheim "$TB\beheer.dpapi"; $V = (Get-Content "$A\vertrouwd.json" -Raw | ConvertFrom-Json).beheer
Controleer ((Test-Path "$K\.git") -and @(Get-ChildItem "$K\aanvragen").Count -eq 3 -and $gb.beheerPrive.n -ne $gb.generatorPrive.n) 'Kale repo met organogram en drie aanvragen; cloudkopie gekloond'
function BeheerCloud {
    $env:DL_BEHEER_SLEUTEL = ($gb.beheerPrive | ConvertTo-Json -Compress); $env:DL_GENERATOR_SLEUTEL = ($gb.generatorPrive | ConvertTo-Json -Compress)
    try {
        $ErrorActionPreference = 'Continue'
        $uit = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\beheer.ps1" @args -Thuis "$T\cloud" 2>&1 | ForEach-Object { "$_" }
        $script:code = $LASTEXITCODE; $uit
    } finally { Remove-Item Env:\DL_BEHEER_SLEUTEL, Env:\DL_GENERATOR_SLEUTEL -ErrorAction SilentlyContinue }
}
$C = Join-Path $Werk 'controle'; G clone -q $O $C | Out-Null
function Origin([string]$Pad) { G -C $C pull -q | Out-Null; Test-Path (Join-Path $C $Pad) }
# Zoals op een runner: geen git-naam (een rebase heeft die nodig; de scripts geven hem zelf mee)
$env:GIT_CONFIG_GLOBAL = (New-Item (Join-Path $Werk 'leeg.gitconfig') -ItemType File -Force).FullName

Write-Host '2. Drie aanvragen, de middelste mislukt halverwege'
$env:DL_TEST_FOUT_NA_SLEUTEL = $ids.Twee     # het goedkeuren van Twee mislukt net na het schrijven van zijn sleutel
try { $uit = BeheerCloud -AutoGoedkeuren } finally { Remove-Item Env:\DL_TEST_FOUT_NA_SLEUTEL }
$schoon = -not (G -C $K status --porcelain)
Controleer ($script:code -eq 1) "Exitcode 1 (er ging iets mis)"
Controleer ((Origin "beheer\sleutels\$($ids.Een).json") -and (Origin "beheer\sleutels\$($ids.Drie).json") -and (Origin "beheer\toegang\$($ids.Drie).json")) 'Een en Drie zijn goedgekeurd en verstuurd'
Controleer (-not (Origin "beheer\sleutels\$($ids.Twee).json") -and (Origin "aanvragen\$($ids.Twee).json")) 'Van Twee is niets half verstuurd (geen sleutel zonder toegang); zijn aanvraag ligt er nog'
Controleer $schoon 'De cloudkopie is daarna schoon (niets achtergebleven)'
if ($fouten) { Write-Host '  Uitvoer van de run:'; $uit | Where-Object { $_ -notmatch '^\s*(\+|At |    \+)' } | ForEach-Object { Write-Host "    $_" } }
# Zonder de fout keurt de volgende run Twee alsnog goed
$uit = BeheerCloud -AutoGoedkeuren
Controleer ($script:code -eq 0 -and (Origin "beheer\toegang\$($ids.Twee).json") -and -not (Origin "aanvragen\$($ids.Twee).json")) 'Volgende run keurt Twee alsnog goed (exitcode 0)'
$orgC = Read-DlBeheer (New-DlOpslag -Map $C) 'organisatie.json' $V
Controleer (@($ids.Values | Where-Object { $orgC.leden.$_.goedgekeurd }).Count -eq 3 -and [int]$orgC.versie -ge 4) 'Alle drie gemarkeerd als goedgekeurd; versie van het organogram loopt op'

Write-Host '3. Gelijktijdig versturen (bijv. de generator) en een botsing'
[IO.File]::WriteAllText("$K\data\cloud.txt", 'cloud'); [IO.File]::WriteAllText("$C\data\generator.txt", 'generator'); Zet $C 'generator'
$ok = $true; try { Push-DlKloon $K } catch { $ok = $false }
Controleer ($ok -and (Origin 'data\cloud.txt') -and (Origin 'data\generator.txt')) 'Andere bestanden: eerst ophalen, dan versturen lukt'
[IO.File]::WriteAllText("$K\data\samen.txt", 'cloud'); [IO.File]::WriteAllText("$C\data\samen.txt", 'generator'); Zet $C 'botsing'
$ok = $true; try { Push-DlKloon $K } catch { $ok = $false }
$gd = Join-Path $K '.git'
Controleer (-not $ok -and -not (Test-Path "$gd\rebase-merge") -and -not (Test-Path "$gd\rebase-apply")) 'Botsing: netjes gestopt, geen half afgemaakte rebase'
Reset-DlKloon $K
Controleer (-not (G -C $K status --porcelain) -and ([IO.File]::ReadAllText("$K\data\samen.txt") -eq 'generator')) 'Daarna terug naar de versie op GitHub'

Write-Host '4. Een ouder organogram teruggezet (git-geschiedenis)'
G -C $C pull -q | Out-Null
$oud = G -C $C log --format=%H -n 1 --skip 2 -- beheer/organisatie.json
# Eerst een niet-ondertekende versie met een hoog nummer (die mag niets blokkeren), dan de echte terug
$echt = [IO.File]::ReadAllText("$C\beheer\organisatie.json")
$nep = $echt | ConvertFrom-Json; $nep.inhoud = (($nep.inhoud | ConvertFrom-Json) | Add-Member -NotePropertyName versie -NotePropertyValue 999 -Force -PassThru | ConvertTo-Json -Depth 12 -Compress)
[IO.File]::WriteAllText("$C\beheer\organisatie.json", ($nep | ConvertTo-Json -Compress)); Zet $C 'nep'
[IO.File]::WriteAllText("$C\beheer\organisatie.json", $echt); Zet $C 'echt terug'
$uit = BeheerCloud -Aanvragen
Controleer ($script:code -eq 0) 'Een niet-ondertekende versie met een hoog nummer in de geschiedenis blokkeert niets'
G -C $C checkout -q $oud -- beheer/organisatie.json | Out-Null; Zet $C 'collega zet oud organogram terug'
$uit = BeheerCloud -AutoGoedkeuren
Controleer ($script:code -ne 0 -and ($uit -join ' ') -match 'oudere versie') 'Teruggezet ouder (wel ondertekend) organogram: de cloud weigert'

Write-Host '5. Laptop: werk dat nog niet verstuurd is, blijft bewaard als een goedkeuring mislukt'
G -C $C pull -q | Out-Null
# Het nieuwste ondertekende organogram terugzetten (stap 4 liet een oude versie achter)
$nieuwste = @(G -C $C log --format=%H -- beheer/organisatie.json)
foreach ($h in $nieuwste) {
    $tekst = (G -C $C show "${h}:beheer/organisatie.json") -join "`n"      # let op: niet $t, dat is $T (hoofdletterongevoelig)
    try { $e = $tekst | ConvertFrom-Json; if (Test-DlHandtekening $V 'beheer|organisatie.json' 'beheer' $e.inhoud $e.sig) { if ([int]($e.inhoud | ConvertFrom-Json).versie -ge [int]$orgC.versie) { [IO.File]::WriteAllText("$C\beheer\organisatie.json", $tekst); break } } } catch {}
}
Zet $C 'nieuwste organogram terug'
$u = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\beheer.ps1" -Uitnodigen -Naam Vier -Rol lid -Project ecom-b2b -DataMap $C -Thuis $TB 2>&1 | ForEach-Object { "$_" }
$ids.Vier = ([regex]::Match(($u -join "`n"), 'lid-[0-9a-f]{6}')).Value
if (-not ($u -join ' ' -match 'Uitnodiging voor Vier')) { Write-Host "  Uitnodigen mislukt:"; $u | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" } }
$ErrorActionPreference = 'Continue'
$iV = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\app\installeer.ps1" -Stil -Uitnodiging "$($ids.Vier):$TOKEN" -Naam Vier -Thuis "$T\Vier" -AppMap $A -DataMap $C -GeenTaak 2>&1 | ForEach-Object { "$_" }
$ErrorActionPreference = 'Stop'
if (-not (Test-Path "$C\aanvragen\$($ids.Vier).json")) { Write-Host "  Aanmelden Vier mislukt (Uitnodiging $($ids.Vier)):"; $iV | Select-Object -First 4 | ForEach-Object { Write-Host "    $_" } }
Zet $C 'Vier meldt zich aan'
$L = Join-Path $TB 'data-kloon'; G clone -q $O $L | Out-Null
[IO.File]::WriteAllText("$L\data\lokaal.txt", 'nog niet verstuurd'); G -C $L add -A | Out-Null; G -C $L -c user.name=test -c user.email=test@test.invalid commit -q -m lokaal | Out-Null
$env:DL_TEST_FOUT_NA_SLEUTEL = $ids.Vier
$ErrorActionPreference = 'Continue'
try { $uitL = & powershell -NoProfile -ExecutionPolicy Bypass -File "$A\beheer\beheer.ps1" -AutoGoedkeuren -Thuis $TB 2>&1 | ForEach-Object { "$_" }; $codeL = $LASTEXITCODE } finally { Remove-Item Env:\DL_TEST_FOUT_NA_SLEUTEL; $ErrorActionPreference = 'Stop' }
Controleer ($codeL -eq 1 -and (Origin 'data\lokaal.txt') -and -not (Origin "beheer\sleutels\$($ids.Vier).json") -and (Origin "aanvragen\$($ids.Vier).json")) 'Mislukte goedkeuring op de laptop: eerder lokaal werk blijft bewaard en gaat alsnog mee; niets half van Vier'
Controleer (-not (G -C $L status --porcelain)) 'Laptopkopie daarna schoon'

if ($fouten) { Write-Host "`n$fouten fout(en)" -ForegroundColor Red; exit 1 } else { Write-Host "`nCloud-git-test geslaagd" -ForegroundColor Green }
