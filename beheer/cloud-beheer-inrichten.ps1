# Goedkeuren in de cloud inrichten: de privé-repo Doubleleren/doubleleren-beheer van sleutels en workflow voorzien, en de
# starter in de data-repo zetten. Draai dit zelf, in een gewoon PowerShell-venster; geheimen gaan rechtstreeks naar GitHub
# en verschijnen nergens op het scherm. Veilig opnieuw te draaien. Zie Leren\plannen\goedkeuren-in-de-cloud.md.
#   powershell -ExecutionPolicy Bypass -File beheer\cloud-beheer-inrichten.ps1 -Omgeving staging -Versie <commit>
#   powershell -ExecutionPolicy Bypass -File beheer\cloud-beheer-inrichten.ps1 -Omgeving live -Versie <merge van zet live> -AlleenVersie
# Per omgeving:
#   <P>BEHEER_SLEUTEL, <P>GENERATOR_SLEUTEL   uit de beheergeheimen op deze laptop (P = DL_ voor live, STAGING_ voor staging)
#   <P>DEPLOY_DATA                             nieuwe deploy key met schrijfrecht op de data-repo
#   DL_APP_COMMIT / STAGING_APP_COMMIT        het vaste commit van de app-repo dat de cloud draait
#   in de data-repo: workflow beheer-starten.yml, secret DL_START (plak je token) en variabele DL_OMGEVING
param(
    [Parameter(Mandatory)][ValidateSet('staging', 'live')][string]$Omgeving,
    [Parameter(Mandatory)][string]$Versie,
    [switch]$AlleenVersie,
    [string]$BeheerRepo = 'Doubleleren/doubleleren-beheer',
    # Fase 2 (portier): eenmalig per omgeving, nadat de GitHub App en het Cloudflare-account er zijn
    [switch]$MetPortier, [string]$AppId, [string]$InstallatieId, [string]$AppSleutelBestand, [string]$CfAccountId
)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\GitHub.cli_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\gh.exe' }
if (-not (Test-Path $gh)) { throw 'GitHub CLI (gh) niet gevonden.' }
$OutputEncoding = New-Object Text.UTF8Encoding($false)
# gh zonder foutmelding (Windows PowerShell maakt van stderr anders een stoppende fout)
function Stil { $ErrorActionPreference = 'Continue'; & $gh @args 2>$null }
$live = $Omgeving -eq 'live'
$P = if ($live) { 'DL_' } else { 'STAGING_' }
$dataRepo = if ($live) { 'Doubleleren/doubleleren-data' } else { 'Doubleleren/doubleleren-data-staging' }
$appBranch = if ($live) { 'main' } else { 'staging' }

Stil auth status | Out-Null
if ($LASTEXITCODE) { throw "gh is niet ingelogd. Draai eerst:  & '$gh' auth login --web --scopes repo,workflow" }
Stil repo view $BeheerRepo --json name | Out-Null
if ($LASTEXITCODE) { throw "Repo $BeheerRepo niet gevonden of geen toegang. Maak hem eerst aan (privé)." }

# 1. Het vaste commit: moet op GitHub bestaan; voor live ook op main, en na dat commit mag er op main buiten lessen/ niets
#    veranderd zijn (de generator pusht elke dag lessen naar main; al het andere komt alleen via "zet live")
if ($Versie -notmatch '^[0-9a-f]{40}$') { throw 'Geef -Versie als volledig commit (40 tekens), bijv. uit: git rev-parse origin/main' }
$ErrorActionPreference = 'Continue'
$null = git -C $App fetch -q origin 2>&1
git -C $App cat-file -e "$Versie^{commit}" 2>$null; $bestaat = -not $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if (-not $bestaat) { throw "Commit $Versie is niet bekend in de app-repo (na git fetch)." }
# Moet op GitHub staan (anders faalt de checkout in de cloud): op main voor live, op staging voor de testomgeving
git -C $App merge-base --is-ancestor $Versie "origin/$appBranch"; if ($LASTEXITCODE) { throw "Commit $Versie staat (nog) niet op $appBranch op GitHub." }
if ($live) {
    $daarna = @(git -C $App diff --name-only "$Versie" origin/main | Where-Object { $_ -and $_ -notlike 'lessen/*' })
    if ($daarna.Count) { throw "Na $($Versie.Substring(0, 7)) is er op main buiten lessen/ iets veranderd ($($daarna -join ', ')). Zet het commit van je laatste 'zet live' vast, na controle." }
}
$naam = if ($live) { 'DL_APP_COMMIT' } else { 'STAGING_APP_COMMIT' }
$oud = (Stil variable get $naam --repo $BeheerRepo)
if ($oud -and $oud -match '^[0-9a-f]{40}$' -and $oud -ne $Versie) {
    Write-Host "Wijzigingen buiten lessen/ sinds de vorige vaste versie ($($oud.Substring(0, 7))):"
    git -C $App diff --stat $oud $Versie -- . ':!lessen'
}
& $gh variable set $naam --body $Versie --repo $BeheerRepo | Out-Null
if ($LASTEXITCODE) { throw "Variabele $naam zetten mislukt." }
Write-Host "  $naam = $($Versie.Substring(0, 7)) ($Omgeving)" -ForegroundColor Green

# Workflows altijd van het vaste commit (nooit uit de werkmap), per omgeving een eigen bestand: een test op staging raakt
# zo nooit de workflow van live. gh heeft daarvoor de scope 'workflow' nodig.
function Get-Versiebestand([string]$Pad) {
    $ErrorActionPreference = 'Continue'
    $oudE = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8
    try { $t = (git -C $App show "$($Versie):$Pad" 2>$null) -join "`n" } finally { [Console]::OutputEncoding = $oudE }
    if ($LASTEXITCODE -or -not $t) { throw "$Pad staat niet in commit $($Versie.Substring(0, 7))." }
    $t + "`n"
}
function Zet-Workflow([string]$Repo, [string]$Tekst, [string]$Doel) {
    $inhoud = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($Tekst))
    $sha = (Stil api "repos/$Repo/contents/$Doel" --jq .sha)
    $a = @('api', '-X', 'PUT', "repos/$Repo/contents/$Doel", '-f', "message=Workflow bijgewerkt naar $($Versie.Substring(0, 7))", '-f', "content=$inhoud")
    if ($sha) { $a += @('-f', "sha=$sha") }
    & $gh @a | Out-Null
    if ($LASTEXITCODE) { throw "Workflow $Doel in $Repo zetten mislukt. Heeft gh de scope 'workflow'? Draai: & '$gh' auth refresh -s workflow" }
    Write-Host "  workflow $Doel ($Repo)"
}
Write-Host 'Workflows'
Zet-Workflow $BeheerRepo ((Get-Versiebestand 'beheer/cloud/goedkeuren.yml').Replace('{{OMGEVING}}', $Omgeving).Replace('{{P}}', $P).Replace('{{DATA}}', ($dataRepo -split '/')[1])) ".github/workflows/goedkeuren-$Omgeving.yml"
Zet-Workflow $dataRepo (Get-Versiebestand 'beheer/cloud/beheer-starten.yml') '.github/workflows/beheer-starten.yml'
$worker = if ($live) { 'portier' } else { 'portier-staging' }
Zet-Workflow $BeheerRepo ((Get-Versiebestand 'beheer/cloud/portier.yml').Replace('{{OMGEVING}}', $Omgeving).Replace('{{P}}', $P).Replace('{{DATA}}', ($dataRepo -split '/')[1]).Replace('{{WORKER}}', $worker)) ".github/workflows/portier-$Omgeving.yml"
Zet-Workflow $BeheerRepo ((Get-Versiebestand 'beheer/cloud/intrekken.yml').Replace('{{OMGEVING}}', $Omgeving).Replace('{{P}}', $P)) ".github/workflows/intrekken-$Omgeving.yml"
if ($AlleenVersie) { return }

# 2. Sleutels uit de beheergeheimen van deze omgeving (nooit met elkaar verwisselen: het script controleert vertrouwd.json)
$thuis = Join-Path (Get-DlThuis) $(if ($live) { 'beheer' } else { 'staging-beheer' })
$g = Read-DlGeheim (Join-Path $thuis 'beheer.dpapi')
if (-not $g -or -not $g.beheerPrive -or -not $g.generatorPrive -or $g.beheerPrive.n -eq $g.generatorPrive.n) {
    throw "Geen aparte beheer- en generatorsleutel in $thuis. Draai eerst beheer.ps1 -NieuweGeneratorsleutel -Thuis `"$thuis`"."
}
$vt = Get-Versiebestand $(if ($live) { 'vertrouwd.json' } else { 'staging/vertrouwd.json' }) | ConvertFrom-Json
if ($vt.beheer.n -ne $g.beheerPrive.n) { throw "De beheersleutel in $thuis past niet bij de vertrouwd.json van $Omgeving. Niets gezet." }

function Zet-Secret([string]$Naam, [string]$Waarde, [string]$Repo = $BeheerRepo) {
    $Waarde | & $gh secret set $Naam --repo $Repo
    if ($LASTEXITCODE) { throw "Secret $Naam zetten mislukt." }
    Write-Host "  secret $Naam gezet ($Repo)"
}
Write-Host "Sleutels voor $Omgeving"
Zet-Secret "$($P)BEHEER_SLEUTEL" ($g.beheerPrive | ConvertTo-Json -Compress)
Zet-Secret "$($P)GENERATOR_SLEUTEL" ($g.generatorPrive | ConvertTo-Json -Compress)

# 3. Eigen deploy key op de data-repo (eigen titel: cloud-inrichten.ps1 wist de sleutel van de generator op zijn titel)
$titel = 'doubleleren-beheer (cloud)'
$tmp = Join-Path $env:TEMP ('dl-sleutels-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
try {
    $f = Join-Path $tmp 'data'
    & ssh-keygen -q -t ed25519 -C $titel -N '""' -f $f | Out-Null
    if (-not (Test-Path $f)) { throw 'ssh-keygen mislukt.' }
    # Let op: ConvertFrom-Json geeft een JSON-lijst als één object door; eerst uitpakken, dan filteren
    $lijst = & $gh repo deploy-key list --repo $dataRepo --json id,title; if ($LASTEXITCODE) { throw "Deploy keys van $dataRepo lezen mislukt." }
    foreach ($o in @(($lijst | ConvertFrom-Json) | ForEach-Object { $_ } | Where-Object { $_.title -eq $titel })) {
        & $gh repo deploy-key delete $o.id --repo $dataRepo | Out-Null
        if ($LASTEXITCODE) { throw "Oude deploy key $($o.id) op $dataRepo verwijderen mislukt: verwijder hem zelf (Settings → Deploy keys)." }
    }
    & $gh repo deploy-key add "$f.pub" --repo $dataRepo --allow-write --title $titel | Out-Null
    if ($LASTEXITCODE) { throw "Deploy key voor $dataRepo toevoegen mislukt." }
    Write-Host "  deploy key met schrijfrecht op $dataRepo"
    Zet-Secret "$($P)DEPLOY_DATA" ([IO.File]::ReadAllText($f))
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# 4. De starter in de data-repo weet welke omgeving hij is
& $gh variable set DL_OMGEVING --body $Omgeving --repo $dataRepo | Out-Null
if ($LASTEXITCODE) { throw "Variabele DL_OMGEVING zetten mislukt ($dataRepo)." }
Write-Host "  DL_OMGEVING = $Omgeving ($dataRepo)"

# 4b. Portier (fase 2): geheimen en variabelen. De app-sleutel komt van GitHub als PKCS#1; Cloudflare wil PKCS#8 (openssl
#     uit Git for Windows zet hem om). Het beheergeheim van de portier maakt het script zelf en zet het alleen bij GitHub.
if ($MetPortier) {
    if ($AppId -notmatch '^\d+$' -or $InstallatieId -notmatch '^\d+$' -or -not $AppSleutelBestand -or -not (Test-Path $AppSleutelBestand) -or $CfAccountId -notmatch '^[0-9a-f]{32}$') {
        throw 'Geef -AppId, -InstallatieId, -AppSleutelBestand (het .pem-bestand van de app) en -CfAccountId (32 tekens, uit het Cloudflare-dashboard).'
    }
    Write-Host 'Portier'
    $openssl = @((Get-Command openssl -ErrorAction SilentlyContinue).Source, 'C:\Program Files\Git\usr\bin\openssl.exe', 'C:\Program Files\Git\mingw64\bin\openssl.exe') | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $openssl) { throw 'openssl niet gevonden (zit in Git for Windows).' }
    $tmp8 = Join-Path $env:TEMP ('dl-app-' + [guid]::NewGuid().ToString('N') + '.pem')
    try {
        $ErrorActionPreference = 'Continue'      # Windows PowerShell maakt van stderr anders een stoppende fout
        & $openssl pkcs8 -topk8 -nocrypt -in $AppSleutelBestand -out $tmp8 2>$null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -or -not (Test-Path $tmp8)) { throw 'De app-sleutel omzetten naar PKCS#8 mislukt.' }
        Zet-Secret 'APP_SLEUTEL' ([IO.File]::ReadAllText($tmp8))
    } finally { Remove-Item $tmp8 -ErrorAction SilentlyContinue }
    $tekens = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    Zet-Secret "$($P)PORTIER_GEHEIM" (-join ((Get-DlWillekeurig 48) | ForEach-Object { $tekens[$_ % 62] }))
    foreach ($kv in @(@('APP_ID', $AppId), @('INSTALLATIE_ID', $InstallatieId), @('CF_ACCOUNT_ID', $CfAccountId), @("$($P)PORTIER_URL", "https://$worker.green-feather-b83e.workers.dev"))) {
        & $gh variable set $kv[0] --body $kv[1] --repo $BeheerRepo | Out-Null; if ($LASTEXITCODE) { throw "Variabele $($kv[0]) zetten mislukt." }
        Write-Host "  $($kv[0]) = $($kv[1])"
    }
    Write-Host 'Plak nu je Cloudflare API-token (alleen "Workers bewerken"; je ziet niets verschijnen) en druk op Enter:'
    & $gh secret set CF_API_TOKEN --repo $BeheerRepo
    if ($LASTEXITCODE) { throw 'CF_API_TOKEN zetten mislukt.' }
    Write-Host "Rol daarna de portier uit: Actions → Portier uitrollen ($Omgeving) → Run workflow." -ForegroundColor Green
    return
}

# 5. Het starttoken (fine-grained, alleen doubleleren-beheer, Actions: Read and write)
Write-Host "Plak nu je token DL_START (je ziet niets verschijnen) en druk op Enter:"
& $gh secret set DL_START --repo $dataRepo
if ($LASTEXITCODE) { throw 'DL_START zetten mislukt.' }

Write-Host "`nKlaar voor $Omgeving. Eerste controle (start een run zonder aanvragen; die stopt na 'kijk'):" -ForegroundColor Green
Write-Host "  & '$gh' workflow run goedkeuren-$Omgeving.yml --repo $BeheerRepo -f bron=handmatig"
if ($live) { Write-Host "Vergeet niet: eerst eenmalig beheer.ps1 -AutoGoedkeuren -OokOpLaptop (markering 'goedgekeurd' voor iedereen met een sleutel), dan de Windows-taak 'DoubleLeren goedkeuren' uit, en in instellingen.json beheerRepo = 'doubleleren-beheer' (dan pauzeert laptopbeheer de cloud)." }
