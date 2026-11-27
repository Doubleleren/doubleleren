# Opslag voor DoubleLeren: GitHub (via de contents-API, geen git nodig) of een gewone map (voor tests).
#   $o = New-DlOpslag -Eigenaar doubleleren -Repo doubleleren-data -Token $t -Auteur lid-7f3a
#   $o = New-DlOpslag -Map C:\test\data
#   $b = Read-DlOpslag $o 'data/lid-7f3a/matrix.enc'   -> @{ bytes; sha } of $null
#   Write-DlOpslag $o 'pad' $bytes $b.sha              -> nieuwe sha; gooit 'conflict' als iemand anders er net tussen zat

$script:DlUtf8 = New-Object System.Text.UTF8Encoding($false)
# Expliciet TLS 1.2 (+1.3): de standaard van Windows PowerShell 5.1 biedt ook oude protocollen aan, waarop GitHub de verbinding sluit
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]'Tls13' } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

function New-DlOpslag([string]$Eigenaar, [string]$Repo, [string]$Token, [string]$Map, [string]$Auteur = 'doubleleren', [string]$Tak = 'main', [switch]$Raw, [string]$Portier, [string]$LidId) {
    if ($Map) { if (-not (Test-Path $Map)) { New-Item -ItemType Directory $Map -Force | Out-Null }; return @{ soort = 'map'; map = (Resolve-Path $Map).Path } }
    # Raw: alleen lezen van een publieke repo via raw.githubusercontent.com (geen API-limiet per kantoor-IP)
    if ($Raw) { return @{ soort = 'raw'; eigenaar = $Eigenaar; repo = $Repo; tak = $Tak } }
    # Nieuwe uitnodigingscode (dl1_…): geen eigen GitHub-token, maar een geheim waarmee de portier een token geeft (een uur geldig)
    if ($Token -cmatch '^dl1_[A-Za-z0-9]{48}$') {
        if (-not $Portier -or -not $LidId) { throw 'Deze uitnodigingscode werkt via de portier, maar die is niet ingesteld. Werk DoubleLeren bij of vraag de beheerder.' }
        return @{ soort = 'github'; eigenaar = $Eigenaar; repo = $Repo; token = $null; verloopt = [DateTime]::MinValue; auteur = $Auteur; tak = $Tak; portier = @{ adres = $Portier.TrimEnd('/'); id = $LidId; geheim = $Token } }
    }
    @{ soort = 'github'; eigenaar = $Eigenaar; repo = $Repo; token = $Token; auteur = $Auteur; tak = $Tak }
}

# Aanroep naar de portier (POST met JSON); de foutmelding van de portier komt mee
function Invoke-DlPortier([string]$Adres, [string]$Pad, $Body) {
    try { Invoke-RestMethod -Uri "$Adres$Pad" -Method Post -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers @{ 'User-Agent' = 'DoubleLeren' } -UseBasicParsing -TimeoutSec 30 }
    catch {
        $tekst = $null; try { $tekst = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() | ConvertFrom-Json } catch {}
        if ($tekst.fout) { throw [string]$tekst.fout }
        throw "De portier is even niet bereikbaar ($($_.Exception.Message)). Probeer het over een paar minuten opnieuw."
    }
}
# Token voor GitHub: vast (oude code) of van de portier, vernieuwd vijf minuten voor het verloopt of als GitHub 401 gaf
function Get-DlToken($O, [switch]$Vernieuw) {
    if (-not $O.portier) { return $O.token }
    if ($Vernieuw -or -not $O.token -or ($O.verloopt - [DateTime]::UtcNow).TotalMinutes -lt 5) {
        $t = Invoke-DlPortier $O.portier.adres '/token' @{ id = $O.portier.id; geheim = $O.portier.geheim }
        $O.token = [string]$t.token; $O.verloopt = ([DateTimeOffset]::Parse([string]$t.verloopt)).UtcDateTime
    }
    $O.token
}

function Invoke-DlGitHub($O, [string]$Methode, [string]$Pad, $Body, [string]$Api = 'contents', [switch]$Opnieuw) {
    $kop = @{ 'User-Agent' = 'DoubleLeren'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $tk = Get-DlToken $O -Vernieuw:$Opnieuw
    if ($tk) { $kop.Authorization = "Bearer $tk" }
    $url = "https://api.github.com/repos/$($O.eigenaar)/$($O.repo)/$Api/$Pad"
    if ($Methode -eq 'GET') { $url += "?$(if ($Api -eq 'contents') { "ref=$($O.tak)&" })t=$([DateTime]::UtcNow.Ticks)" }   # eigen adres per keer: een bedrijfsproxy geeft anders een verouderde versie
    $p = @{ Uri = $url; Method = $Methode; Headers = $kop; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($Body) { $p.Body = $script:DlUtf8.GetBytes(($Body | ConvertTo-Json -Depth 5 -Compress)); $p.ContentType = 'application/json' }
    # Lezen bij een storing van GitHub (5xx, rate limit 429 of geen verbinding) twee keer opnieuw proberen; schrijven niet (kan al gelukt zijn)
    for ($poging = 0; ; $poging++) {
        try { return (Invoke-RestMethod @p) }
        catch {
            $status = 0; try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            if ($status -eq 404) { return $null }
            # Token van de portier verlopen of ingetrokken: één keer een nieuw vragen en opnieuw proberen
            if ($status -eq 401 -and $O.portier -and -not $Opnieuw) { return (Invoke-DlGitHub $O $Methode $Pad $Body $Api -Opnieuw) }
            if ($status -eq 409 -or $status -eq 422) { throw 'conflict' }
            if ($Methode -eq 'GET' -and ($status -ge 500 -or $status -eq 0 -or $status -eq 429) -and $poging -lt 2) { Start-Sleep -Milliseconds (700 * [math]::Pow(3, $poging)); $p.Uri = $url -replace 't=\d+$', "t=$([DateTime]::UtcNow.Ticks)"; continue }
            throw "GitHub ($Methode $Pad): $status $($_.Exception.Message)"
        }
    }
}

function Get-DlSha1([byte[]]$B) { $s = [Security.Cryptography.SHA1]::Create(); try { -join ($s.ComputeHash($B) | ForEach-Object { $_.ToString('x2') }) } finally { $s.Dispose() } }

function Read-DlOpslag($O, [string]$Pad) {
    if ($O.soort -eq 'map') {
        $f = Join-Path $O.map $Pad
        if (-not (Test-Path $f)) { return $null }
        $b = [IO.File]::ReadAllBytes($f); return @{ bytes = $b; sha = (Get-DlSha1 $b) }
    }
    if ($O.soort -eq 'raw') {
        for ($poging = 0; ; $poging++) {
            try {
                $w = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$($O.eigenaar)/$($O.repo)/$($O.tak)/$Pad" -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'DoubleLeren' }
                $b = $w.RawContentStream.ToArray(); return @{ bytes = $b; sha = (Get-DlSha1 $b) }
            } catch {
                $s = 0; try { $s = [int]$_.Exception.Response.StatusCode } catch {}; if ($s -eq 404) { return $null }
                if (($s -ge 500 -or $s -eq 0) -and $poging -lt 2) { Start-Sleep -Milliseconds (700 * [math]::Pow(3, $poging)); continue }
                throw
            }
        }
    }
    $r = Invoke-DlGitHub $O 'GET' $Pad
    if (-not $r) { return $null }
    if ($r -is [array]) { throw "$Pad is een map" }
    $b = [Convert]::FromBase64String(($r.content -replace '\s', ''))
    # De contents-API houdt sommige versleutelde bestanden voor UTF-16-tekst en levert ze omgezet naar UTF-8 (andere
    # bytes, 'Geen DL1-bestand'). Klopt de lengte niet, dan opnieuw via de git-blob-API: die geeft altijd de echte bytes.
    if ($b.Length -ne [int]$r.size) { $b = [Convert]::FromBase64String(((Invoke-DlGitHub $O 'GET' "$($r.sha)" -Api 'git/blobs').content -replace '\s', '')) }
    @{ bytes = $b; sha = $r.sha }
}

function Write-DlOpslag($O, [string]$Pad, [byte[]]$Bytes, [string]$Sha) {
    if ($O.soort -eq 'map') {
        $f = Join-Path $O.map $Pad
        $huidig = if (Test-Path $f) { Get-DlSha1 ([IO.File]::ReadAllBytes($f)) } else { $null }
        if ($huidig -ne $(if ($Sha) { $Sha } else { $null })) { throw 'conflict' }
        New-Item -ItemType Directory (Split-Path $f) -Force | Out-Null
        [IO.File]::WriteAllBytes($f, $Bytes); return (Get-DlSha1 $Bytes)
    }
    # Neutrale commit onder één algemene naam: geen namen, pseudoniemen of lestitels in de geschiedenis
    $wie = @{ name = 'doubleleren'; email = 'sync@doubleleren.invalid' }
    $body = [ordered]@{ message = 'sync'; content = [Convert]::ToBase64String($Bytes); branch = $O.tak; committer = $wie; author = $wie }
    if ($Sha) { $body.sha = $Sha }
    (Invoke-DlGitHub $O 'PUT' $Pad $body).content.sha
}

function Remove-DlOpslag($O, [string]$Pad, [string]$Sha) {
    if ($O.soort -eq 'map') { $f = Join-Path $O.map $Pad; if (Test-Path $f) { Remove-Item $f }; return }
    $wie = @{ name = 'doubleleren'; email = 'sync@doubleleren.invalid' }
    Invoke-DlGitHub $O 'DELETE' $Pad ([ordered]@{ message = 'sync'; sha = $Sha; branch = $O.tak; committer = $wie; author = $wie }) | Out-Null
}

function Get-DlOpslagLijst($O, [string]$Map) {
    if ($O.soort -eq 'map') {
        $m = Join-Path $O.map $Map
        if (-not (Test-Path $m)) { return @() }
        return @(Get-ChildItem $m | ForEach-Object { $_.Name })
    }
    $r = Invoke-DlGitHub $O 'GET' $Map
    if (-not $r) { return @() }
    @($r | ForEach-Object { $_.name })
}

# JSON-hulpjes
function Read-DlJson($O, [string]$Pad) { $r = Read-DlOpslag $O $Pad; if ($r) { $script:DlUtf8.GetString($r.bytes) | ConvertFrom-Json } }
function Write-DlJson($O, [string]$Pad, $Obj, [string]$Sha) { Write-DlOpslag $O $Pad ($script:DlUtf8.GetBytes(($Obj | ConvertTo-Json -Depth 10))) $Sha }
