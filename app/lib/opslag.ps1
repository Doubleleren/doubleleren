# Opslag voor DoubleLeren: GitHub (via de contents-API, geen git nodig) of een gewone map (voor tests).
#   $o = New-DlOpslag -Eigenaar thijsbol2004 -Repo doubleleren-data -Token $t -Auteur lid-7f3a
#   $o = New-DlOpslag -Map C:\test\data
#   $b = Read-DlOpslag $o 'data/lid-7f3a/matrix.enc'   -> @{ bytes; sha } of $null
#   Write-DlOpslag $o 'pad' $bytes $b.sha              -> nieuwe sha; gooit 'conflict' als iemand anders er net tussen zat

$script:DlUtf8 = New-Object System.Text.UTF8Encoding($false)
# Expliciet TLS 1.2 (+1.3): de standaard van Windows PowerShell 5.1 biedt ook oude protocollen aan, waarop GitHub de verbinding sluit
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]'Tls13' } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

function New-DlOpslag([string]$Eigenaar, [string]$Repo, [string]$Token, [string]$Map, [string]$Auteur = 'doubleleren', [string]$Tak = 'main', [switch]$Raw) {
    if ($Map) { if (-not (Test-Path $Map)) { New-Item -ItemType Directory $Map -Force | Out-Null }; return @{ soort = 'map'; map = (Resolve-Path $Map).Path } }
    # Raw: alleen lezen van een publieke repo via raw.githubusercontent.com (geen API-limiet per kantoor-IP)
    if ($Raw) { return @{ soort = 'raw'; eigenaar = $Eigenaar; repo = $Repo; tak = $Tak } }
    @{ soort = 'github'; eigenaar = $Eigenaar; repo = $Repo; token = $Token; auteur = $Auteur; tak = $Tak }
}

function Invoke-DlGitHub($O, [string]$Methode, [string]$Pad, $Body) {
    $kop = @{ 'User-Agent' = 'DoubleLeren'; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($O.token) { $kop.Authorization = "Bearer $($O.token)" }
    $url = "https://api.github.com/repos/$($O.eigenaar)/$($O.repo)/contents/$Pad"
    if ($Methode -eq 'GET') { $url += "?ref=$($O.tak)" }
    $p = @{ Uri = $url; Method = $Methode; Headers = $kop; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($Body) { $p.Body = $script:DlUtf8.GetBytes(($Body | ConvertTo-Json -Depth 5 -Compress)); $p.ContentType = 'application/json' }
    try { Invoke-RestMethod @p }
    catch {
        $status = 0; try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 404) { return $null }
        if ($status -eq 409 -or $status -eq 422) { throw 'conflict' }
        throw "GitHub ($Methode $Pad): $status $($_.Exception.Message)"
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
        try {
            $w = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$($O.eigenaar)/$($O.repo)/$($O.tak)/$Pad" -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'DoubleLeren' }
            $b = $w.RawContentStream.ToArray(); return @{ bytes = $b; sha = (Get-DlSha1 $b) }
        } catch { $s = 0; try { $s = [int]$_.Exception.Response.StatusCode } catch {}; if ($s -eq 404) { return $null }; throw }
    }
    $r = Invoke-DlGitHub $O 'GET' $Pad
    if (-not $r) { return $null }
    if ($r -is [array]) { throw "$Pad is een map" }
    @{ bytes = [Convert]::FromBase64String(($r.content -replace '\s', '')); sha = $r.sha }
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
