# Voor de lesgenerator: ontsleutelt per deelnemer ALLEEN wat nodig is om lessen te kiezen
# (profielfocus, skilllijst-scores, resultaten van de laatste 3 maanden, huidige wachtrij). Nooit antwoorden, nooit namen.
# Daarnaast voor het leren (fase 4): resultaten per les over het hele team en de feedback van de laatste 60 dagen, zonder afzender.
# Schrijft naar %USERPROFILE%\.doubleleren\beheer\generator\context.json (buiten OneDrive en buiten de repo's).
# Bestanden met een ongeldige handtekening worden overgeslagen en gemeld.
param([string]$DataMap, [string]$Thuis, [string]$Uit, [switch]$Proef)   # -Proef: voorstellen niet verwerken in de data-repo
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
if (-not $Uit) { $Uit = Join-Path $Thuis 'generator' }
New-Item -ItemType Directory $Uit -Force | Out-Null
$pad = Join-Path $Uit 'context.json'
Remove-Item $pad -ErrorAction SilentlyContinue        # restant van een eerder afgebroken run
$geheim = Read-DlGeneratorGeheim $Thuis
# Eerst lessen die de head of SEO op de website maakte opnemen in de kennisbank
& (Join-Path $PSScriptRoot 'voorstellen-opnemen.ps1') -DataMap $DataMap -Thuis $Thuis -Proef:$Proef
. (Join-Path $PSScriptRoot 'kloon.ps1')
if (-not $DataMap) { $k = Get-DlKloon $Thuis; if ($k) { Update-DlKloon $k; $DataMap = $k } }
$d =if ($DataMap) { New-DlOpslag -Map $DataMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token }
$V = (Get-Content (Join-Path $App 'vertrouwd.json') -Raw -Encoding UTF8 | ConvertFrom-Json).beheer   # beheersleutel: controleert alles onder beheer/
$org = Read-DlBeheer $d 'organisatie.json' $V
$pub = New-DlSleutelbron $d $V

$leden = [ordered]@{}; $script:ongeldig = 0; $script:lidOvergeslagen = 0
$stat = [ordered]@{}     # per les: hoe vaak goed, deels en fout (alle deelnemers, alle maanden)
foreach ($id in @($org.leden.PSObject.Properties.Name)) {
    $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t) { continue }    # nog niet goedgekeurd
    $s = Get-DlSleutelsUitDk (Unprotect-DlRsa $geheim.generatorPrive (ConvertFrom-B64u $t.kopieen.generator))
    # Een bestand dat niet te controleren is: tellen en de deelnemer vandaag overslaan (zijn bestaande wachtrij blijft staan)
    $script:lidOngeldig = 0
    $lees = { param($soort) try { Read-DlVersleuteld $d $id $soort $s $pub } catch { $script:ongeldig++; $script:lidOngeldig++; Write-Host "  overgeslagen: $(if ($env:GITHUB_ACTIONS) { 'deelnemer' } else { $id })|$soort ($($_.Exception.Message -replace 'lid-[0-9a-f]{6}', 'lid-…'))"; $null } }
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
        foreach ($g in @($r.obj.regels)) {
            if ("$($g.id)" -notmatch '^[0-9a-z][0-9a-z-]{0,80}$' -or @('goed', 'deels', 'fout') -notcontains $g.resultaat) { continue }
            if (-not $stat.Contains($g.id)) { $stat[$g.id] = [ordered]@{ n = 0; goed = 0; deels = 0; fout = 0 } }
            $stat[$g.id].n++; $stat[$g.id][$g.resultaat]++
        }
        if ($maand -ge $grens) { $resultaten += @($r.obj.regels | ForEach-Object { [ordered]@{ datum = $_.datum; les = $_.id; resultaat = $_.resultaat; matrix = $_.matrix; niveau = $_.niveau; soort = $_.soort } }) }
    }
    $scores = [ordered]@{}
    if ($matrix) { foreach ($p in $matrix.obj.scores.PSObject.Properties) { $laatste = @($p.Value.PSObject.Properties | Sort-Object Name)[-1]; if ($laatste) { $scores[$p.Name] = [int]$laatste.Value } } }
    # Eigen prioriteit per hoofdgebied (eerste cijfer van de vaardigheid-id): 1 hoog, 2 normaal (standaard), 3 laag
    $prioriteit = [ordered]@{}
    if ($matrix -and $matrix.obj.prioriteit) { foreach ($p in $matrix.obj.prioriteit.PSObject.Properties) { if ($p.Name -match '^\d{1,2}$' -and @(1, 2, 3) -contains [int]$p.Value) { $prioriteit[$p.Name] = [int]$p.Value } } }
    if ($script:lidOngeldig) { $script:lidOvergeslagen++; continue }
    $leden[$id] = [ordered]@{
        project = $org.leden.$id.project; cel = $org.leden.$id.cel
        focus = $(if ($profiel) { $profiel.obj.focus }); leerdoelen = $(if ($profiel) { $profiel.obj.leerdoelen })
        scores = $scores; prioriteit = $prioriteit; resultaten = $resultaten; gedaan = @($gedaan | Sort-Object -Unique); wachtrij = @($(if ($wachtrij) { $wachtrij.obj.lessen }))
    }
}
# Feedback van collega's (laatste 60 dagen), zonder afzender: om lessen te verbeteren en onderwerpen te kiezen.
# Alleen met een geldige handtekening; vrije tekst zonder stuur- en richtingstekens. Ouder dan de generatorsleutel: geen kopie, overgeslagen.
$feedback = @(); $fbOverslaan = 0
$grensFb = (Get-Date).AddDays(-60).ToString('yyyyMMdd')
foreach ($naam in @(Get-DlOpslagLijst $d 'feedback' | ForEach-Object { $_ -replace '\.json$', '' } | Where-Object { $_ -match '^\d{8}T\d{6}-[0-9a-f]{8}$' -and $_.Substring(0, 8) -ge $grensFb } | Sort-Object)) {
    try {
        $f = Read-DlFeedback $d "$naam.json" 'generator' $geheim.generatorPrive $pub
        if ($f) { $feedback += [ordered]@{ id = $f.bestand; soort = $f.soort; les = $f.les; datum = $f.datum; tekst = ($f.tekst -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u200E\u200F\u202A-\u202E\u2066-\u2069]', '') } }
    } catch { $fbOverslaan++ }
}
[IO.File]::WriteAllText($pad, ([ordered]@{ v = 1; gemaakt = (Get-Date).ToString('s'); vakgebied = $inst.vakgebied; leden = $leden; lesstatistiek = $stat; feedback = @($feedback) } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host "Context voor $($leden.Count) deelnemer(s), $($stat.Count) les(sen) met resultaten, $($feedback.Count) feedbackbericht(en)$(if ($fbOverslaan) { " ($fbOverslaan niet leesbaar)" }): $pad$(if ($script:ongeldig) { " · $($script:ongeldig) bestand(en) niet te controleren, $($script:lidOvergeslagen) deelnemer(s) vandaag overgeslagen" })"
