# Clientkant op de laptop: instellingen, geheimen en opslag samen. Vereist krypto, opslag, lid en geheim.
#   $c = Get-DlClient            # of Get-DlClient -Thuis <testmap>
#   $s = Get-DlEigenSleutels $c  # Kenc/Kmac van je eigen datasleutel (pas na goedkeuring)
# $c.vertrouwd is de publieke beheersleutel, bij installatie vastgelegd; daarmee worden beheerbestanden gecontroleerd.

function Get-DlClient([string]$Thuis) {
    if (-not $Thuis) { $Thuis = Get-DlThuis }
    $cfgPad = Join-Path $Thuis 'config.json'
    if (-not (Test-Path $cfgPad)) { return $null }
    $cfg = Get-Content $cfgPad -Raw -Encoding UTF8 | ConvertFrom-Json
    $g = Read-DlGeheim (Join-Path $Thuis 'geheim.dpapi')
    if (-not $g -or -not $cfg.vertrouwd) { return $null }
    $app = if ($cfg.appMap) { New-DlOpslag -Map $cfg.appMap } else { New-DlOpslag -Eigenaar $cfg.eigenaar -Repo $cfg.appRepo -Raw }
    $data = if ($cfg.dataMap) { New-DlOpslag -Map $cfg.dataMap } else { New-DlOpslag -Eigenaar $cfg.eigenaar -Repo $cfg.dataRepo -Token $g.token }
    @{ id = $cfg.id; prive = $g.prive; app = $app; data = $data; vertrouwd = $cfg.vertrouwd; thuis = $Thuis; cfg = $cfg
       publiek = (New-DlSleutelbron $data $cfg.vertrouwd $cfg.id $g.prive) }
}

function Get-DlEigenSleutels($C) { Get-DlSleutelsUitDk (Get-DlDk $C.data $C.id $C.id $C.prive $C.vertrouwd) }

function Save-DlClient([string]$Thuis, $Cfg, [string]$Id, $Prive, [string]$Token) {
    New-Item -ItemType Directory $Thuis -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Thuis 'config.json'), ($Cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Save-DlGeheim (Join-Path $Thuis 'geheim.dpapi') ([pscustomobject]@{ id = $Id; prive = $Prive; token = $Token })
}
