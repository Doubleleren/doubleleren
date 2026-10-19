# Voor de lesgenerator: ontsleutelt per deelnemer ALLEEN wat nodig is om lessen te kiezen
# (profielfocus, skilllijst-scores, resultaten van de laatste 3 maanden, huidige wachtrij). Nooit antwoorden, nooit namen.
# Schrijft naar %USERPROFILE%\.doubleleren\beheer\generator\context.json (buiten OneDrive en buiten de repo's).
# Bestanden met een ongeldige handtekening worden overgeslagen en gemeld.
param([string]$DataMap, [string]$Thuis, [string]$Uit)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
if (-not $Uit) { $Uit = Join-Path $Thuis 'generator' }
New-Item -ItemType Directory $Uit -Force | Out-Null
$pad = Join-Path $Uit 'context.json'
Remove-Item $pad -ErrorAction SilentlyContinue        # restant van een eerder afgebroken run
$geheim = Read-DlGeheim (Join-Path $Thuis 'beheer.dpapi'); if (-not $geheim) { throw 'Geen beheergeheimen: draai beheer.ps1 -Init' }
. (Join-Path $PSScriptRoot 'kloon.ps1')
if (-not $DataMap) { $k = Get-DlKloon $Thuis; if ($k) { Update-DlKloon $k; $DataMap = $k } }
$d =if ($DataMap) { New-DlOpslag -Map $DataMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token }
$V = [pscustomobject]@{ kty = 'RSA'; n = $geheim.generatorPrive.n; e = $geheim.generatorPrive.e }
$org = Read-DlBeheer $d 'organisatie.json' $V
$pub = New-DlSleutelbron $d $V

$leden = [ordered]@{}; $script:ongeldig = 0
foreach ($id in @($org.leden.PSObject.Properties.Name)) {
    $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t) { continue }    # nog niet goedgekeurd
    $s = Get-DlSleutelsUitDk (Unprotect-DlRsa $geheim.generatorPrive (ConvertFrom-B64u $t.kopieen.generator))
    $lees = { param($soort) try { Read-DlVersleuteld $d $id $soort $s $pub } catch { $script:ongeldig++; Write-Host "  overgeslagen: $id|$soort ($($_.Exception.Message))"; $null } }
    $profiel = & $lees 'profiel'
    if ($org.leden.$id.leren -eq 'optioneel' -and -not ($profiel -and $profiel.obj.lessen)) { continue }   # koos (nog) geen lessen
    $matrix = & $lees 'matrix'
    $wachtrij = & $lees 'wachtrij'
    $resultaten = @()
    foreach ($m in 0, -1, -2) {
        $r = & $lees ('log-' + (Get-Date).AddMonths($m).ToString('yyyy-MM'))
        if ($r) { $resultaten += @($r.obj.regels | ForEach-Object { [ordered]@{ datum = $_.datum; les = $_.id; resultaat = $_.resultaat; matrix = $_.matrix; niveau = $_.niveau; soort = $_.soort } }) }
    }
    $scores = [ordered]@{}
    if ($matrix) { foreach ($p in $matrix.obj.scores.PSObject.Properties) { $laatste = @($p.Value.PSObject.Properties | Sort-Object Name)[-1]; if ($laatste) { $scores[$p.Name] = [int]$laatste.Value } } }
    $leden[$id] = [ordered]@{
        project = $org.leden.$id.project; cel = $org.leden.$id.cel
        focus = $(if ($profiel) { $profiel.obj.focus }); leerdoelen = $(if ($profiel) { $profiel.obj.leerdoelen })
        scores = $scores; resultaten = $resultaten; wachtrij = @($(if ($wachtrij) { $wachtrij.obj.lessen }))
    }
}
[IO.File]::WriteAllText($pad, ([ordered]@{ v = 1; gemaakt = (Get-Date).ToString('s'); vakgebied = $inst.vakgebied; leden = $leden } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host "Context voor $($leden.Count) deelnemer(s): $pad$(if ($script:ongeldig) { " · $($script:ongeldig) bestand(en) met ongeldige handtekening overgeslagen" })"
