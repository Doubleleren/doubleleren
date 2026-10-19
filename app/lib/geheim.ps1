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
# Bewust NIET in AppData: Windows leidt AppData-schrijfacties van pakket-apps (zoals de Claude-app) om naar
# een eigen pakketmap, waardoor scripts uit verschillende bronnen elkaars bestanden niet zien.
function Get-DlThuis { Join-Path $env:USERPROFILE '.doubleleren' }
