# Scorebord van iedereen bijwerken (deze en vorige maand), ondertekend door de generator. Draait elke ochtend vanuit
# generator-publiceer.ps1; los te draaien met -Push. Zo staat ook wie de website niet opende of een oude pop-up heeft
# op het bord. Wie zich verborg (scorebord:false in het eigen profiel) krijgt geen cijfers. Schrijft alleen wat veranderde.
param([string]$DataMap, [string]$Thuis, [switch]$Push)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
. (Join-Path $PSScriptRoot 'kloon.ps1')
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
$geheim = Read-DlGeneratorGeheim $Thuis
$kloon = $null
if (-not $DataMap) { $kloon = Get-DlKloon $Thuis; if ($kloon) { Update-DlKloon $kloon; $DataMap = $kloon } }
$d = if ($DataMap) { New-DlOpslag -Map $DataMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token }
$V = (Get-Content (Join-Path $App 'vertrouwd.json') -Raw -Encoding UTF8 | ConvertFrom-Json).beheer   # beheersleutel: controleert alles onder beheer/
$org = Read-DlBeheer $d 'organisatie.json' $V
$pub = New-DlSleutelbron $d $V

$n = 0; $fout = 0
foreach ($id in @($org.leden.PSObject.Properties.Name)) {
    try {
        $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t -or -not $t.kopieen.generator) { continue }   # nog niet goedgekeurd
        $s = Get-DlSleutelsUitDk (Unprotect-DlRsa $geheim.generatorPrive (ConvertFrom-B64u $t.kopieen.generator))
        $profiel = Read-DlVersleuteld $d $id 'profiel' $s $pub
        # Zelfde regel als de website: vrijblijvend lid dat geen lessen koos, staat niet op het bord
        if ($org.leden.$id.leren -eq 'optioneel' -and $profiel -and $profiel.obj.lessen -eq $false) { continue }
        $logs = @()
        foreach ($b in @(Get-DlOpslagLijst $d "data/$id" | Where-Object { $_ -match '^log-\d{4}-\d{2}\.enc$' })) {
            $r = Read-DlVersleuteld $d $id ($b -replace '\.enc$', '') $s $pub; if ($r) { $logs += @($r.obj.regels) }
        }
        $zichtbaar = -not ($profiel -and $profiel.obj.scorebord -eq $false)
        Write-DlScorebord @{ data = $d; id = $id } $logs $zichtbaar (Get-Date) 'generator' $geheim.generatorPrive
        $n++
    } catch { $fout++ }
}
if ($Push -and $kloon) { Push-DlKloon $kloon }
Write-Host "Scorebord bijgewerkt voor $n deelnemer(s)$(if ($fout) { "; $fout overgeslagen (fout bij lezen of ongeldige handtekening)" })."
