# DoubleLeren-krypto v1 (Windows PowerShell 5.1 / .NET 4.8). Spiegelbeeld van docs/krypto.js: wijzig nooit één kant alleen.
# Dot-source dit bestand:  . "$PSScriptRoot\lib\krypto.ps1"
#
# Bestandsformaat (DL1):  "DL1" | iv(16) | AES-256-CBC-PKCS7(ct) | HMAC-SHA256 tag(32)
#   tag = HMAC(Kmac, utf8("DL1|" + context + "|") || iv || ct)       encrypt-then-MAC
# Datasleutel (DK, 32 bytes):  Kenc = HMAC(DK, "doubleleren-v1-enc"), Kmac = HMAC(DK, "doubleleren-v1-mac")
# Kluis: PBKDF2-SHA256(code, salt16, iteraties) -> 64 bytes = Kenc | Kmac
# Sleutelpaar: RSA-OAEP-SHA256, 3072 bit, als JWK.

$script:DlUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:DlPbkdf2Iteraties = 600000

function ConvertTo-B64u([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function ConvertFrom-B64u([string]$Tekst) {
    $s = $Tekst.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
    [Convert]::FromBase64String($s)
}
function Get-DlWillekeurig([int]$Aantal) {
    $b = New-Object byte[] $Aantal
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($b); $rng.Dispose()
    , $b
}
function Join-DlBytes {
    $ms = New-Object IO.MemoryStream
    foreach ($deel in $args) { if ($null -ne $deel) { $ms.Write([byte[]]$deel, 0, $deel.Length) } }
    , $ms.ToArray()
}
function Get-DlHmac([byte[]]$Sleutel, [byte[]]$Data) {
    $h = New-Object Security.Cryptography.HMACSHA256(, $Sleutel)
    try { , $h.ComputeHash($Data) } finally { $h.Dispose() }
}
function Test-DlGelijk([byte[]]$A, [byte[]]$B) {
    # Vergelijking in constante tijd
    if ($A.Length -ne $B.Length) { return $false }
    $verschil = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $verschil = $verschil -bor ($A[$i] -bxor $B[$i]) }
    $verschil -eq 0
}

function Get-DlPbkdf2([string]$Code, [byte[]]$Salt, [int]$Iteraties = $script:DlPbkdf2Iteraties, [int]$Lengte = 32) {
    $pw = $script:DlUtf8.GetBytes($Code.Normalize([Text.NormalizationForm]::FormC))
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $Salt, $Iteraties, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { , $kdf.GetBytes($Lengte) } finally { $kdf.Dispose() }
}

function Get-DlSleutelsUitDk([byte[]]$Dk) {
    @{ enc = (Get-DlHmac $Dk $script:DlUtf8.GetBytes('doubleleren-v1-enc')); mac = (Get-DlHmac $Dk $script:DlUtf8.GetBytes('doubleleren-v1-mac')) }
}
# Kluis v2: één PBKDF2-uitvoer van 32 bytes, gesplitst met HMAC (een aanvaller moet de volledige keten doorrekenen)
function Get-DlSleutelsUitAfgeleid([byte[]]$Afgeleid) {
    @{ enc = (Get-DlHmac $Afgeleid $script:DlUtf8.GetBytes('doubleleren-v2-kluis-enc')); mac = (Get-DlHmac $Afgeleid $script:DlUtf8.GetBytes('doubleleren-v2-kluis-mac')) }
}
function Get-DlSha256([byte[]]$B) { $s = [Security.Cryptography.SHA256]::Create(); try { , $s.ComputeHash($B) } finally { $s.Dispose() } }
# Antwoordensleutel: afgeleid uit je eigen privésleutel. Staat nergens als bestand, dus niemand kan hem vervangen.
function Get-DlAk($PriveJwk) {
    $d = Remove-DlVoorloopnullen (ConvertFrom-B64u $PriveJwk.d)
    Get-DlSleutelsUitDk (Get-DlHmac (Get-DlSha256 $d) $script:DlUtf8.GetBytes('doubleleren-v1-ak'))
}
# Opvullen tot een veelvoud van 1024 bytes (spaties; JSON negeert ze), zodat bestandsgroottes weinig verraden
function Add-DlOpvulling([byte[]]$B) {
    $doel = [Math]::Max(1024, [int]([Math]::Ceiling($B.Length / 1024.0) * 1024))
    if ($doel -eq $B.Length) { return , $B }
    $out = New-Object byte[] $doel; [Array]::Copy($B, $out, $B.Length)
    for ($i = $B.Length; $i -lt $doel; $i++) { $out[$i] = 0x20 }
    , $out
}

function Protect-Dl([hashtable]$Sleutels, [string]$Context, [byte[]]$Data, [byte[]]$Iv) {
    if (-not $Iv) { $Iv = Get-DlWillekeurig 16 }
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $Sleutels.enc; $aes.IV = $Iv
        $enc = $aes.CreateEncryptor(); $ct = $enc.TransformFinalBlock($Data, 0, $Data.Length); $enc.Dispose()
    } finally { $aes.Dispose() }
    $tag = Get-DlHmac $Sleutels.mac (Join-DlBytes $script:DlUtf8.GetBytes("DL1|$Context|") $Iv $ct)
    , (Join-DlBytes $script:DlUtf8.GetBytes('DL1') $Iv $ct $tag)
}

function Unprotect-Dl([hashtable]$Sleutels, [string]$Context, [byte[]]$Blob) {
    if ($Blob.Length -lt 67 -or $script:DlUtf8.GetString($Blob, 0, 3) -ne 'DL1') { throw 'Geen DL1-bestand' }
    $iv = [byte[]]$Blob[3..18]
    $ct = New-Object byte[] ($Blob.Length - 19 - 32); [Array]::Copy($Blob, 19, $ct, 0, $ct.Length)
    $tag = New-Object byte[] 32; [Array]::Copy($Blob, $Blob.Length - 32, $tag, 0, 32)
    $verwacht = Get-DlHmac $Sleutels.mac (Join-DlBytes $script:DlUtf8.GetBytes("DL1|$Context|") $iv $ct)
    if (-not (Test-DlGelijk $tag $verwacht)) { throw 'Controle mislukt: verkeerde sleutel, verkeerde context of aangepast bestand' }
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $Sleutels.enc; $aes.IV = $iv
        $dec = $aes.CreateDecryptor(); $pt = $dec.TransformFinalBlock($ct, 0, $ct.Length); $dec.Dispose()
    } finally { $aes.Dispose() }
    , $pt
}

# --- RSA-OAEP-SHA256 / JWK -------------------------------------------------
function Remove-DlVoorloopnullen([byte[]]$B) {
    $i = 0; while ($i -lt $B.Length - 1 -and $B[$i] -eq 0) { $i++ }
    if ($i -eq 0) { return , $B }
    $out = New-Object byte[] ($B.Length - $i); [Array]::Copy($B, $i, $out, 0, $out.Length); , $out
}
function Add-DlVoorloopnullen([byte[]]$B, [int]$Lengte) {
    # .NET eist vaste lengtes (D = len(n), P/Q/DP/DQ/InverseQ = len(n)/2); JWK laat voorloopnullen soms weg
    $B = Remove-DlVoorloopnullen $B
    if ($B.Length -gt $Lengte) { throw "JWK-veld is langer dan verwacht ($($B.Length) > $Lengte)" }
    if ($B.Length -eq $Lengte) { return , $B }
    $out = New-Object byte[] $Lengte; [Array]::Copy($B, 0, $out, $Lengte - $B.Length, $B.Length); , $out
}

function New-DlSleutelpaar([int]$Bits = 3072) {
    $rsa = New-Object Security.Cryptography.RSACng($Bits)
    try {
        $p = $rsa.ExportParameters($true)
        $n = ConvertTo-B64u (Remove-DlVoorloopnullen $p.Modulus); $e = ConvertTo-B64u (Remove-DlVoorloopnullen $p.Exponent)
        [pscustomobject]@{
            publiek = [ordered]@{ kty = 'RSA'; n = $n; e = $e }
            prive   = [ordered]@{
                kty = 'RSA'; n = $n; e = $e
                d  = ConvertTo-B64u (Remove-DlVoorloopnullen $p.D);  p  = ConvertTo-B64u (Remove-DlVoorloopnullen $p.P)
                q  = ConvertTo-B64u (Remove-DlVoorloopnullen $p.Q);  dp = ConvertTo-B64u (Remove-DlVoorloopnullen $p.DP)
                dq = ConvertTo-B64u (Remove-DlVoorloopnullen $p.DQ); qi = ConvertTo-B64u (Remove-DlVoorloopnullen $p.InverseQ)
            }
        }
    } finally { $rsa.Dispose() }
}

function ConvertFrom-DlJwk($Jwk) {
    $p = New-Object Security.Cryptography.RSAParameters
    $p.Modulus = Remove-DlVoorloopnullen (ConvertFrom-B64u $Jwk.n)
    $p.Exponent = Remove-DlVoorloopnullen (ConvertFrom-B64u $Jwk.e)
    if ($Jwk.d) {
        $len = $p.Modulus.Length; $half = [int][Math]::Ceiling($len / 2)
        $p.D = Add-DlVoorloopnullen (ConvertFrom-B64u $Jwk.d) $len
        $p.P = Add-DlVoorloopnullen (ConvertFrom-B64u $Jwk.p) $half
        $p.Q = Add-DlVoorloopnullen (ConvertFrom-B64u $Jwk.q) $half
        $p.DP = Add-DlVoorloopnullen (ConvertFrom-B64u $Jwk.dp) $half
        $p.DQ = Add-DlVoorloopnullen (ConvertFrom-B64u $Jwk.dq) $half
        $p.InverseQ = Add-DlVoorloopnullen (ConvertFrom-B64u $Jwk.qi) $half
    }
    $rsa = New-Object Security.Cryptography.RSACng
    $rsa.ImportParameters($p)
    $rsa
}

function Protect-DlRsa($PubliekJwk, [byte[]]$Dk) {
    $rsa = ConvertFrom-DlJwk $PubliekJwk
    try { , $rsa.Encrypt($Dk, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256) } finally { $rsa.Dispose() }
}
function Unprotect-DlRsa($PriveJwk, [byte[]]$Verpakt) {
    $rsa = ConvertFrom-DlJwk $PriveJwk
    try { , $rsa.Decrypt($Verpakt, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256) } finally { $rsa.Dispose() }
}

# --- Kluis (v2) ------------------------------------------------------------------
function Lock-DlKluis([string]$Id, $PriveJwk, [string]$Code, [int]$Iteraties = $script:DlPbkdf2Iteraties, [byte[]]$Salt) {
    if (-not $Salt) { $Salt = Get-DlWillekeurig 16 }
    $s = Get-DlSleutelsUitAfgeleid (Get-DlPbkdf2 $Code $Salt $Iteraties)
    $velden = [ordered]@{}; foreach ($v in 'kty', 'n', 'e', 'd', 'p', 'q', 'dp', 'dq', 'qi') { $velden[$v] = $PriveJwk.$v }
    $json = [pscustomobject]$velden | ConvertTo-Json -Compress
    $blob = Protect-Dl $s "$Id|kluis" $script:DlUtf8.GetBytes($json)
    [ordered]@{ v = 2; salt = (ConvertTo-B64u $Salt); iteraties = $Iteraties; kluis = (ConvertTo-B64u $blob) }
}
function Unlock-DlKluis([string]$Id, $Kluis, [string]$Code) {
    if ([int]$Kluis.v -ne 2) { throw 'Onbekende kluisversie' }
    $it = [int]$Kluis.iteraties
    if ($it -lt 1000 -or $it -gt 2000000) { throw 'Ongeldig aantal iteraties' }
    $s = Get-DlSleutelsUitAfgeleid (Get-DlPbkdf2 $Code (ConvertFrom-B64u $Kluis.salt) $it)
    $script:DlUtf8.GetString((Unprotect-Dl $s "$Id|kluis" (ConvertFrom-B64u $Kluis.kluis))) | ConvertFrom-Json
}

function Get-DlVingerafdruk($PubliekJwk) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { , $sha.ComputeHash($script:DlUtf8.GetBytes("$($PubliekJwk.e).$($PubliekJwk.n)")) } finally { $sha.Dispose() }
}
function Get-DlVingerafdrukHex($PubliekJwk) { -join ((Get-DlVingerafdruk $PubliekJwk) | ForEach-Object { $_.ToString('x2') }) }

# Alleen sleutels in de vaste vorm accepteren: e = 65537, n = precies 3072 bit zonder voorloopnul.
# Zo kan niemand met een andere e of opgevulde n gericht naar dezelfde controlewoorden zoeken.
function Test-DlSleutelVorm($PubliekJwk) {
    if ($PubliekJwk.kty -ne 'RSA' -or $PubliekJwk.e -ne 'AQAB') { return $false }
    try { $n = ConvertFrom-B64u $PubliekJwk.n } catch { return $false }
    ($n.Length -eq 384 -and $n[0] -ne 0 -and (ConvertTo-B64u $n) -eq $PubliekJwk.n)
}

# --- Handtekeningen (RSA-PSS-SHA256, salt 32) -----------------------------------
function Get-DlTekenBytes([string]$Context, [string]$Door, [string]$Inhoud) { , $script:DlUtf8.GetBytes("DLSIG1|$Context|$Door|$Inhoud") }
function New-DlHandtekening($PriveJwk, [string]$Context, [string]$Door, [string]$Inhoud) {
    $rsa = ConvertFrom-DlJwk $PriveJwk
    try { ConvertTo-B64u $rsa.SignData((Get-DlTekenBytes $Context $Door $Inhoud), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss) } finally { $rsa.Dispose() }
}
function Test-DlHandtekening($PubliekJwk, [string]$Context, [string]$Door, [string]$Inhoud, [string]$Sig) {
    if (-not $PubliekJwk -or -not $Sig) { return $false }
    $rsa = ConvertFrom-DlJwk $PubliekJwk
    try { $rsa.VerifyData((Get-DlTekenBytes $Context $Door $Inhoud), (ConvertFrom-B64u $Sig), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss) }
    catch { $false } finally { $rsa.Dispose() }
}

# --- Woordcodes (lijst van precies 1024 woorden: elk woord = 10 bits) ----------
$script:DlWoorden = @([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'woorden.txt'), $script:DlUtf8) | Where-Object { $_ })
if ($script:DlWoorden.Count -ne 1024) { throw "woorden.txt moet precies 1024 woorden bevatten ($($script:DlWoorden.Count))" }
function Get-DlWoord([byte[]]$B, [int]$I) { $script:DlWoorden[(([int]$B[2 * $I] -shl 8) -bor $B[2 * $I + 1]) -band 1023] }
function New-DlCode {
    $r = Get-DlWillekeurig 12
    (0..5 | ForEach-Object { Get-DlWoord $r $_ }) -join '-'
}
# 6 controlewoorden (60 bits) over de hele aanvraag: sleutel, kluis en beide sleutelkopieën.
# Verandert iemand onderweg iets aan de aanvraag, dan kloppen de woorden niet meer.
function Get-DlAanvraagVingerafdruk($A) {
    $delen = @('DLAANVRAAG1', $A.id, $A.publiek.e, $A.publiek.n, $A.kluis.salt, $A.kluis.kluis, "$($A.kluis.iteraties)",
        "$(if ($A.toegang) { $A.toegang.($A.id) })", "$(if ($A.toegang) { $A.toegang.generator })", $(if ($A.herstel) { 'herstel' } else { 'nieuw' }))
    Get-DlSha256 ($script:DlUtf8.GetBytes(($delen -join '|')))
}
function Get-DlControlewoorden($Aanvraag) {
    $v = Get-DlAanvraagVingerafdruk $Aanvraag
    (0..5 | ForEach-Object { Get-DlWoord $v $_ }) -join ' '
}
function ConvertTo-DlCode([string]$Code) {
    (($Code.Trim().ToLower() -split '[\s\-_.,]+') | Where-Object { $_ }) -join '-'
}
