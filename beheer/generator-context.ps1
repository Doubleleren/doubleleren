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
# Eerst lessen die de head of SEO op de website maakte opnemen in de kennisbank
& (Join-Path $PSScriptRoot 'voorstellen-opnemen.ps1') -DataMap $DataMap -Thuis $Thuis
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
    # Alle maanden: 'gedaan' (ooit gedane les-id's, die komen nooit terug); details alleen van de laatste 3 maanden
    $resultaten = @(); $gedaan = @()
    $grens = (Get-Date).AddMonths(-2).ToString('yyyy-MM')
    foreach ($bestand in @(Get-DlOpslagLijst $d "data/$id" | Where-Object { $_ -match '^log-(\d{4}-\d{2})\.enc$' } | Sort-Object)) {
        $maand = $bestand.Substring(4, 7)
        $r = & $lees "log-$maand"; if (-not $r) { continue }
        $gedaan += @($r.obj.regels | ForEach-Object { $_.id })
        if ($maand -ge $grens) { $resultaten += @($r.obj.regels | ForEach-Object { [ordered]@{ datum = $_.datum; les = $_.id; resultaat = $_.resultaat; matrix = $_.matrix; niveau = $_.niveau; soort = $_.soort } }) }
    }
    $scores = [ordered]@{}
    if ($matrix) { foreach ($p in $matrix.obj.scores.PSObject.Properties) { $laatste = @($p.Value.PSObject.Properties | Sort-Object Name)[-1]; if ($laatste) { $scores[$p.Name] = [int]$laatste.Value } } }
    # Eigen prioriteit per hoofdgebied (eerste cijfer van de vaardigheid-id): 1 hoog, 2 normaal (standaard), 3 laag
    $prioriteit = [ordered]@{}
    if ($matrix -and $matrix.obj.prioriteit) { foreach ($p in $matrix.obj.prioriteit.PSObject.Properties) { if ($p.Name -match '^\d{1,2}$' -and @(1, 2, 3) -contains [int]$p.Value) { $prioriteit[$p.Name] = [int]$p.Value } } }
    $leden[$id] = [ordered]@{
        project = $org.leden.$id.project; cel = $org.leden.$id.cel
        focus = $(if ($profiel) { $profiel.obj.focus }); leerdoelen = $(if ($profiel) { $profiel.obj.leerdoelen })
        scores = $scores; prioriteit = $prioriteit; resultaten = $resultaten; gedaan = @($gedaan | Sort-Object -Unique); wachtrij = @($(if ($wachtrij) { $wachtrij.obj.lessen }))
    }
}
[IO.File]::WriteAllText($pad, ([ordered]@{ v = 1; gemaakt = (Get-Date).ToString('s'); vakgebied = $inst.vakgebied; leden = $leden } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host "Context voor $($leden.Count) deelnemer(s): $pad$(if ($script:ongeldig) { " · $($script:ongeldig) bestand(en) met ongeldige handtekening overgeslagen" })"
