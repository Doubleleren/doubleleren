# Kruistest PowerShell 5.1 <-> WebCrypto (Node). Draai:  powershell -NoProfile -ExecutionPolicy Bypass -File test\kruistest.ps1
# 1. PowerShell maakt testgegevens (ps-vectoren.json)
# 2. Node controleert ze met docs/krypto.js en maakt eigen gegevens (node-vectoren.json)
# 3. PowerShell controleert de Node-gegevens
param([int]$MinVoorloopnullen = 3, [int]$MaxSleutels = 120)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\app\lib\krypto.ps1')
$uit = Join-Path $env:TEMP 'doubleleren-kruistest'; New-Item -ItemType Directory $uit -Force | Out-Null
$fouten = 0
function Controleer([bool]$ok, [string]$wat) { if ($ok) { Write-Host "  OK    $wat" } else { Write-Host "  FOUT  $wat" -ForegroundColor Red; $script:fouten++ } }
function Hex([byte[]]$b) { -join ($b | ForEach-Object { $_.ToString('x2') }) }
function Bytes([int]$van, [int]$n) { , [byte[]]($van..($van + $n - 1)) }

Write-Host "1. PowerShell maakt testgegevens"
$code = 'tafel-wolk-rivier-kompas-vijg-lantaarn'
$salt = Bytes 0 16
$dk = Bytes 1 32
$iv = Bytes 100 16
$tekst = "Hallo DoubleLeren: canonical, INP en A/B-testen. Ë ï é ✓"
$sl = Get-DlSleutelsUitDk $dk

$sw = [Diagnostics.Stopwatch]::StartNew(); $vol = Get-DlPbkdf2 $code $salt 600000 64; $msVol = $sw.ElapsedMilliseconds
Write-Host "  PBKDF2 600k rondes in PowerShell: $msVol ms"

# Sleutelparen tot er genoeg gevallen met voorloopnullen zijn (klassieke JWK-valkuil)
$paren = @(); $metNullen = 0
while (($metNullen -lt $MinVoorloopnullen -or $paren.Count -lt 8) -and $paren.Count -lt $MaxSleutels) {
    $kp = New-DlSleutelpaar 3072
    $n = (ConvertFrom-B64u $kp.prive.n).Length; $h = $n / 2
    $kort = ((ConvertFrom-B64u $kp.prive.d).Length -lt $n) -or (@('p', 'q', 'dp', 'dq', 'qi') | Where-Object { (ConvertFrom-B64u $kp.prive.$_).Length -lt $h }).Count -gt 0
    if ($kort) { $metNullen++ }
    $dkRsa = Get-DlWillekeurig 32
    $paren += [ordered]@{ publiek = $kp.publiek; prive = $kp.prive; dk = (ConvertTo-B64u $dkRsa); verpakt = (ConvertTo-B64u (Protect-DlRsa $kp.publiek $dkRsa)); voorloopnul = $kort }
}
Write-Host "  $($paren.Count) RSA-3072-sleutelparen, waarvan $metNullen met voorloopnullen"

$aanvraag = [ordered]@{ v = 1; id = 'lid-7f3a'; publiek = $paren[0].publiek; kluis = (Lock-DlKluis 'lid-7f3a' $paren[0].prive $code 1000); toegang = [ordered]@{ 'lid-7f3a' = 'abc'; generator = 'def' } }
$ps = [ordered]@{
    code = $code; salt = (ConvertTo-B64u $salt)
    pbkdf2_1000 = (Hex (Get-DlPbkdf2 $code $salt 1000 64)); pbkdf2_600000 = (Hex $vol)
    dk = (ConvertTo-B64u $dk); kenc = (Hex $sl.enc); kmac = (Hex $sl.mac)
    iv = (ConvertTo-B64u $iv); tekst = $tekst; context = 'lid-7f3a|scores'
    blob = (ConvertTo-B64u (Protect-Dl $sl 'lid-7f3a|scores' ([Text.Encoding]::UTF8.GetBytes($tekst)) $iv))
    kluis = (Lock-DlKluis 'lid-7f3a' $paren[0].prive $code 1000)
    nieuweCode = (New-DlCode)
    aanvraag = $aanvraag; controlewoorden = (Get-DlControlewoorden $aanvraag)
    ak = (Hex (Get-DlAk $paren[0].prive).enc)
    getekend = [ordered]@{ context = 'lid-7f3a|matrix'; door = 'lid-7f3a'; inhoud = '{"v":1,"scores":{"1.1.1":{"2026-06":2}}}' }
    sig = (New-DlHandtekening $paren[0].prive 'lid-7f3a|matrix' 'lid-7f3a' '{"v":1,"scores":{"1.1.1":{"2026-06":2}}}')
    vorm = @((Test-DlSleutelVorm $paren[0].publiek), (Test-DlSleutelVorm ([ordered]@{ kty = 'RSA'; e = 'AQAB'; n = 'AA' + $paren[0].publiek.n })), (Test-DlSleutelVorm ([ordered]@{ kty = 'RSA'; e = 'Aw'; n = $paren[0].publiek.n })))
    paren = $paren
}
[IO.File]::WriteAllText("$uit\ps-vectoren.json", ($ps | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

Write-Host "2. Node controleert (WebCrypto)"
& node (Join-Path $PSScriptRoot 'kruistest.mjs') $uit
if ($LASTEXITCODE -ne 0) { $fouten++ }

Write-Host "3. PowerShell controleert de Node-gegevens"
$nv = [IO.File]::ReadAllText("$uit\node-vectoren.json", [Text.Encoding]::UTF8) | ConvertFrom-Json
$nsl = Get-DlSleutelsUitDk (ConvertFrom-B64u $nv.dk)
$pt = [Text.Encoding]::UTF8.GetString((Unprotect-Dl $nsl $nv.context (ConvertFrom-B64u $nv.blob)))
Controleer ($pt -eq $nv.tekst) 'Node-bestand ontsleutelt in PowerShell'
$ok = 0; $nul = 0
foreach ($p in $nv.paren) {
    $terug = Unprotect-DlRsa $p.prive (ConvertFrom-B64u $p.verpakt)
    if ((Hex $terug) -eq (Hex (ConvertFrom-B64u $p.dk))) { $ok++ }
    if ($p.voorloopnul) { $nul++ }
}
Controleer ($ok -eq $nv.paren.Count) "Node-sleutels in PowerShell geopend: $ok/$($nv.paren.Count) (waarvan $nul met voorloopnullen)"
$ok = 0
for ($i = 0; $i -lt $nv.terugNaarPs.Count; $i++) {
    $terug = Unprotect-DlRsa $paren[$i].prive (ConvertFrom-B64u $nv.terugNaarPs[$i].verpakt)
    if ((Hex $terug) -eq (Hex (ConvertFrom-B64u $nv.terugNaarPs[$i].dk))) { $ok++ }
}
Controleer ($ok -eq $nv.terugNaarPs.Count) "Node verpakt voor PowerShell-sleutels: $ok/$($nv.terugNaarPs.Count)"
Controleer ((Get-DlControlewoorden $nv.aanvraag) -eq $nv.controlewoorden) "Controlewoorden (6) gelijk: $($nv.controlewoorden)"
$na = $nv.aanvraag | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $na.toegang.generator = 'xyz'
Controleer ((Get-DlControlewoorden $na) -ne $nv.controlewoorden) 'Omgewisselde sleutelkopie in de aanvraag geeft andere controlewoorden'
Controleer (Test-DlHandtekening $nv.paren[0].publiek $nv.getekend.context $nv.getekend.door $nv.getekend.inhoud $nv.sig) 'WebCrypto-handtekening klopt in PowerShell'
Controleer (-not (Test-DlHandtekening $nv.paren[0].publiek $nv.getekend.context $nv.getekend.door ($nv.getekend.inhoud + ' ') $nv.sig)) 'Gewijzigde inhoud: handtekening ongeldig'
Controleer (-not (Test-DlHandtekening $nv.paren[0].publiek 'lid-ander|matrix' $nv.getekend.door $nv.getekend.inhoud $nv.sig)) 'Ander lid: handtekening ongeldig'
Controleer ((Hex (Get-DlAk $nv.paren[0].prive).enc) -eq $nv.ak) 'Antwoordensleutel uit dezelfde privésleutel is gelijk'
$jwk = Unlock-DlKluis 'lid-node' $nv.kluis $nv.code
Controleer ($jwk.n -eq $nv.paren[0].prive.n -and $jwk.d -eq $nv.paren[0].prive.d) 'Node-kluis opent in PowerShell met de juiste code'
try { Unlock-DlKluis 'lid-node' $nv.kluis ($nv.code + 'x') | Out-Null; Controleer $false 'Verkeerde code wordt geweigerd' } catch { Controleer $true 'Verkeerde code wordt geweigerd' }
$knoei = ConvertFrom-B64u $nv.blob; $knoei[30] = $knoei[30] -bxor 1
try { Unprotect-Dl $nsl $nv.context $knoei | Out-Null; Controleer $false 'Aangepast bestand wordt geweigerd' } catch { Controleer $true 'Aangepast bestand wordt geweigerd' }
try { Unprotect-Dl $nsl 'lid-andere|scores' (ConvertFrom-B64u $nv.blob) | Out-Null; Controleer $false 'Verwisseld lid wordt geweigerd' } catch { Controleer $true 'Verwisseld lid wordt geweigerd' }

if ($fouten) { Write-Host "`n$fouten fout(en)" -ForegroundColor Red; exit 1 } else { Write-Host "`nAlle kruistests geslaagd" -ForegroundColor Green }
