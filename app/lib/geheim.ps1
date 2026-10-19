# Lokale geheimen (privésleutel, token) beschermd met Windows DPAPI: alleen dit Windows-account op deze laptop kan ze lezen.
Add-Type -AssemblyName System.Security

function Save-DlGeheim([string]$Pad, $Obj) {
    $json = [Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Depth 6 -Compress))
    $b = [Security.Cryptography.ProtectedData]::Protect($json, [Text.Encoding]::UTF8.GetBytes('DoubleLeren'), 'CurrentUser')
    New-Item -ItemType Directory (Split-Path $Pad) -Force | Out-Null
    [IO.File]::WriteAllBytes($Pad, $b)
}
function Read-DlGeheim([string]$Pad) {
    if (-not (Test-Path $Pad)) { return $null }
    $b = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Pad), [Text.Encoding]::UTF8.GetBytes('DoubleLeren'), 'CurrentUser')
    [Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json
}

# Standaardmappen: buiten OneDrive, per Windows-gebruiker
function Get-DlThuis { Join-Path $env:LOCALAPPDATA 'DoubleLeren' }
