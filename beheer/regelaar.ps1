# Regelaar van de lesgenerator: de vaste regels per persoon als script, zodat Claude alleen nog schrijft en beoordeelt.
#   -Stap plan       (na generator-context.ps1) Bepaalt per deelnemer de plekken in de wachtrij: vak, vaardigheid, soort,
#                    niveau en cel, met de loting voor herhaling en verdieping. Vult wat kan uit de kennisbank. Schrijft
#                    regelaar.json (voor stap toewijzen) en werk.json (voor Claude: bestellingen, voorraadtips, lessen die eerst
#                    herzien of van een cel voorzien moeten worden, en per persoon alleen wat oordeel vraagt).
#   -Stap toewijzen  (in generator-publiceer.ps1, na de nieuwe index) Vult de open plekken met de lessen die Claude schreef of
#                    herstelde, zet nieuws- en teamlessen en Claudes wensen vooraan en schrijft wachtrijen.json.
# Regels: beheer/generator-instructies.md. Alles blijft in de map van de context (vertrouwelijk, wordt na het publiceren gewist).
param([ValidateSet('plan', 'toewijzen')][string]$Stap = 'plan', [string]$Map, [string]$App, [int]$Zaad = 0, [string]$Vandaag)
$ErrorActionPreference = 'Stop'
if (-not $App) { $App = Split-Path $PSScriptRoot -Parent }
if (-not $Map) { . (Join-Path $App 'app\lib\opslag.ps1'); $Map = Join-Path (Join-Path (Get-DlThuis) 'beheer') 'generator' }
$nu = if ($Vandaag) { [datetime]::ParseExact($Vandaag, 'yyyy-MM-dd', $null) } else { (Get-Date).Date }
$utf8 = New-Object Text.UTF8Encoding($false)
function Lees($pad) { [IO.File]::ReadAllText($pad, [Text.Encoding]::UTF8) | ConvertFrom-Json }
function Schrijf($pad, $obj) { [IO.File]::WriteAllText($pad, ($obj | ConvertTo-Json -Depth 10), $utf8) }

$WACHTRIJ = 5                     # zoveel lessen staan er per persoon klaar (twee per dag plus buffer)
$NIVEAUS = @('basis', 'gevorderd', 'expert')
$rng = if ($Zaad) { New-Object Random $Zaad } else { New-Object Random ([BitConverter]::ToInt32((New-Object Security.Cryptography.RNGCryptoServiceProvider | ForEach-Object { $b = New-Object byte[] 4; $_.GetBytes($b); $b }), 0)) }
function Kans { $rng.NextDouble() }

$inst = Lees (Join-Path $App 'instellingen.json'); $standaard = [string]$inst.vakgebied
$index = @((Lees (Join-Path $App 'lessen\index.json')).lessen)
$lesVan = @{}; foreach ($l in $index) { $lesVan[$l.id] = $l }
function VakVanLes($l) { $m = @($l.matrix | Where-Object { "$_" -like '*:*' })[0]; if ($m) { "$m".Split(':')[0] } else { $standaard } }
function DatumVanId($id) { if ("$id" -match '^(\d{4})(\d{2})(\d{2})-') { [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) } }
function CelPast($l, [string]$cel) { -not $cel -or $l.cel -eq 'alle' -or $l.cel -eq $cel }   # zonder cel op de les: zie Bruikbaar

# Of een les nu meteen in een wachtrij mag: actief, nog niet gedaan, juiste vak en cel, en niet te raden.
# Geeft 'ja', 'nee' of de reden waarom hij eerst langs Claude moet ('cel' of 'herzien').
function Bruikbaar($l, $p, [string]$vak) {
    if (-not $l -or $l.actief -eq $false -or $p.gedaan.Contains($l.id) -or (VakVanLes $l) -ne $vak) { return 'nee' }
    if ($l.cel -and -not (CelPast $l $p.cel)) { return 'nee' }
    if ($l.juistLangst -or $l.vormAfwijkend) { return 'herzien' }
    if (-not $l.cel -and $p.cel) { return 'cel' }    # case nog niet bepaald: eerst laten labelen, anders krijgt leadgen een webshopvraag
    'ja'
}
# Kandidaten voor een plek: lessen over die vaardigheid op dat niveau (anders een niveau ernaast), meerkeuze eerst.
# Hooguit één schrijfopdracht (open, zoek-op) per wachtrij; maak-met-claude alleen via een wens van Claude.
function Zoek($plek, $p, $gekozen, $teller, [switch]$Wachtend) {
    $n = [array]::IndexOf($NIVEAUS, $plek.niveau)
    $schrijf = @($gekozen | Where-Object { $lesVan[$_] -and $lesVan[$_].soort -ne 'meerkeuze' }).Count
    $beste = $null; $wacht = @()
    foreach ($ronde in 0, 1) {
        $kand = @($index | Where-Object {
            @($_.matrix) -contains $plek.vaardigheid -and $gekozen -notcontains $_.id -and $_.soort -ne 'maak-met-claude' -and
            ($_.soort -eq 'meerkeuze' -or -not $schrijf) -and
            $(if ($ronde -eq 0) { $_.niveau -eq $plek.niveau } else { [math]::Abs([array]::IndexOf($NIVEAUS, $_.niveau) - $n) -eq 1 })
        })
        $ja = @(); foreach ($l in $kand) { $b = Bruikbaar $l $p $plek.vak; if ($b -eq 'ja') { $ja += $l } elseif ($b -ne 'nee') { $wacht += [pscustomobject]@{ les = $l.id; reden = $b } } }
        if ($ja.Count) {
            # Eigen cel boven 'alle', meerkeuze boven een schrijfopdracht, dan spreiding: de les die vandaag het minst is uitgedeeld
            $beste = $ja | Sort-Object @{ e = { if ($_.cel -eq $p.cel) { 0 } else { 1 } } }, @{ e = { if ($_.soort -eq 'meerkeuze') { 0 } else { 1 } } }, @{ e = { [int]$teller[$_.id] } }, @{ e = { Kans } } | Select-Object -First 1
            break
        }
    }
    if ($Wachtend) { return , @($wacht) }
    $beste
}

if ($Stap -eq 'plan') {
    $ctx = Lees (Join-Path $Map 'context.json')
    $cellen = @($ctx.cellen | Where-Object { $_ })
    # Skilllijsten van de vakken die meedoen; het standaardvak heeft kale id's, de rest 'vak:1.2.3'
    $items = @{}; $perVak = @{}
    foreach ($vak in @($ctx.vakken)) {
        $pad = Join-Path $App "sjablonen\$vak\skilllijst.csv"; if (-not (Test-Path $pad)) { continue }
        $perVak[$vak] = @()
        foreach ($r in @([IO.File]::ReadAllText($pad, [Text.Encoding]::UTF8) | ConvertFrom-Csv -Delimiter ';')) {
            if (-not $r.id) { continue }
            $id = if ($vak -eq $standaard) { $r.id } else { "${vak}:$($r.id)" }
            $items[$id] = [pscustomobject]@{ id = $id; vak = $vak; hoofdgebied = $id -replace '^(([a-z-]+:)?\d+).*$', '$1'; naam = $r.hoofdgebied; onderwerp = $r.onderwerp; omschrijving = (("$($r.context) $($r.vaardigheid)").Trim() -replace '\s+', ' '); notitie = $r.notitie }
            $perVak[$vak] += $id
        }
    }
    $teller = @{}                      # hoe vaak een les vandaag is uitgedeeld (spreiding over collega's)
    $plan = [ordered]@{}; $bestel = [ordered]@{}; $herzien = @{}; $celBepalen = @{}; $personen = [ordered]@{}

    foreach ($id in @($ctx.leden.PSObject.Properties.Name)) {
        $c = $ctx.leden.$id
        $p = [pscustomobject]@{ id = $id; cel = [string]$c.cel; gedaan = New-Object 'System.Collections.Generic.HashSet[string]' }
        foreach ($g in @($c.gedaan) + @($c.resultaten | ForEach-Object { $_.les })) { if ($g) { [void]$p.gedaan.Add([string]$g) } }
        # Vakken met gewicht: focus (1) telt drie keer, meeleren (2, een oude 3) één keer
        $vakken = [ordered]@{}; foreach ($v in @($c.vakken.PSObject.Properties)) { if ($perVak.ContainsKey($v.Name)) { $vakken[$v.Name] = $(if ([int]$v.Value -eq 1) { 3 } else { 1 }) } }
        if (-not $vakken.Count) { continue }
        $scores = @{}; foreach ($s in @($c.scores.PSObject.Properties)) { $scores[$s.Name] = [int]$s.Value }
        $gem = if ($scores.Count) { ($scores.Values | Measure-Object -Average).Average } else { 0 }
        $prio = @{}; foreach ($s in @($c.prioriteit.PSObject.Properties)) { $prio[$s.Name] = [int]$s.Value }
        # Laatste resultaat per vaardigheid (voor herhaling, verdieping en "niet te snel weer hetzelfde")
        $laatste = @{}
        foreach ($r in @($c.resultaten | Sort-Object { "$($_.datum)" })) {
            if ("$($r.datum)" -notmatch '^\d{4}-\d{2}-\d{2}') { continue }
            foreach ($m in @($r.matrix | Where-Object { $_ })) { $laatste[[string]$m] = [pscustomobject]@{ datum = [datetime]::ParseExact("$($r.datum)".Substring(0, 10), 'yyyy-MM-dd', $null); resultaat = $r.resultaat; niveau = $(if ($r.niveau) { $r.niveau } else { 'basis' }) } }
        }

        # 1. Wat er nog klaarstaat en nog bruikbaar is (niet gedaan, actief, juiste vak en cel). Te makkelijk voor een ervaren
        #    collega (basis bij score 3+) of een tweede schrijfopdracht: eruit.
        $open = @()
        foreach ($w in @($c.wachtrij | Where-Object { $_ })) {
            $l = $lesVan[[string]$w]; if (-not $l -or $open -contains $l.id) { continue }
            $b = Bruikbaar $l $p (VakVanLes $l)
            if ($b -eq 'nee' -or -not $vakken.Contains((VakVanLes $l))) { continue }
            # Nog zonder cel of te raden: blijft staan als Claude hem vandaag labelt of herstelt (anders valt hij bij het toewijzen af)
            if ($b -eq 'cel' -and $l.herkomst -ne 'team') { $celBepalen[$l.id] = $true } elseif ($b -eq 'herzien') { $herzien[$l.id] = $(if ($l.juistLangst) { 'juistLangst' } else { 'vormAfwijkend' }) }
            if ($gem -ge 3.5 -and $l.niveau -eq 'basis' -and $l.type -ne 'nieuws' -and @($l.matrix | Where-Object { $scores[[string]$_] -ge 3 }).Count) { continue }
            if ($l.soort -ne 'meerkeuze' -and @($open | Where-Object { $lesVan[$_].soort -ne 'meerkeuze' }).Count) { continue }
            $open += $l.id
        }
        $bezet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($o in $open) { foreach ($m in @($lesVan[$o].matrix)) { [void]$bezet.Add([string]$m) } }

        # 2. Plekken voor wat er ontbreekt
        $plekken = @(); $nodig = $WACHTRIJ - $open.Count
        $niveauVan = { param($vid) $s = $scores[$vid]; if ($s) { if ($s -le 2) { 'basis' } elseif ($s -eq 3) { 'gevorderd' } else { 'expert' } } elseif ($gem -ge 3.5) { 'gevorderd' } else { 'basis' } }
        $stapOp = { param($n) $NIVEAUS[[math]::Min(2, [array]::IndexOf($NIVEAUS, $n) + 1)] }
        # 2a. Herhaling (na fout of deels) en verdieping (na goed): 14 tot 35 dagen later, op een onvoorspelbaar moment.
        #     Loting: aan de beurt als het getal onder (dagen - 13) / 22 ligt, dus na 35 dagen altijd. Hooguit één van elk per run.
        foreach ($soort in 'herhaling', 'verdieping') {
            if ($plekken.Count -ge $nodig) { break }
            $kand = @($laatste.Keys | Where-Object {
                $r = $laatste[$_]; $d = ($nu - $r.datum).Days
                $items.ContainsKey($_) -and $vakken.Contains($items[$_].vak) -and -not $bezet.Contains($_) -and $d -ge 14 -and
                $(if ($soort -eq 'herhaling') { $r.resultaat -in 'fout', 'deels' } else { $r.resultaat -eq 'goed' })
            } | Sort-Object { $laatste[$_].datum })
            foreach ($vid in $kand) {
                if ((Kans) -lt ((($nu - $laatste[$vid].datum).Days - 13) / 22)) {
                    $nv = if ($soort -eq 'herhaling') { $laatste[$vid].niveau } else { & $stapOp $laatste[$vid].niveau }
                    $plekken += [pscustomobject]@{ vak = $items[$vid].vak; vaardigheid = $vid; type = $soort; niveau = $nv; cel = $p.cel; les = $null }
                    [void]$bezet.Add($vid); break
                }
            }
        }
        # 2b. De rest: basis (of meteen verdieping bij een eigen score van 4 of 5), gewogen naar score en eigen prioriteit,
        #     afwisselend over hoofdgebieden en niet een vaardigheid die in de laatste 14 dagen al aan bod kwam.
        $gebruiktHg = @{}
        while ($plekken.Count -lt $nodig) {
            $vakKeuze = @($vakken.Keys); $r = (Kans) * ($vakken.Values | Measure-Object -Sum).Sum; $vak = $vakKeuze[-1]
            foreach ($v in $vakKeuze) { $r -= $vakken[$v]; if ($r -lt 0) { $vak = $v; break } }
            $heeftScores = @($perVak[$vak] | Where-Object { $scores.ContainsKey($_) }).Count -gt 0
            $gew = @(); $som = 0
            foreach ($vid in $perVak[$vak]) {
                if ($bezet.Contains($vid) -or ($laatste[$vid] -and ($nu - $laatste[$vid].datum).Days -lt 14)) { continue }
                $s = $scores[$vid]
                $w = if (-not $s) { if ($heeftScores) { 1.5 } else { 3 } } elseif ($s -le 2) { 3 } elseif ($s -eq 3) { 2 } elseif ($gem -ge 3.5) { 1.5 } else { 0.5 }
                $w *= @{ 1 = 2.0; 2 = 1.0; 3 = 0.34 }[$(if ($prio[$items[$vid].hoofdgebied]) { $prio[$items[$vid].hoofdgebied] } else { 2 })]
                if ($gebruiktHg[$items[$vid].hoofdgebied]) { $w *= 0.3 }
                if ($items[$vid].notitie) { $w *= 0.5 }
                $gew += , @($vid, $w); $som += $w
            }
            if (-not $gew.Count) { $vakken.Remove($vak); if (-not $vakken.Count) { break } else { continue } }
            $r = (Kans) * $som; $vid = $gew[-1][0]
            foreach ($g in $gew) { $r -= $g[1]; if ($r -lt 0) { $vid = $g[0]; break } }
            $s = $scores[$vid]
            $plekken += [pscustomobject]@{ vak = $vak; vaardigheid = $vid; type = $(if ($s -ge 4 -and -not @($plekken | Where-Object type -eq 'verdieping').Count) { 'verdieping' } else { 'basis' }); niveau = (& $niveauVan $vid); cel = $p.cel; les = $null }
            [void]$bezet.Add($vid); $gebruiktHg[$items[$vid].hoofdgebied] = $true
        }

        # 3. Vullen uit de kennisbank; wat ontbreekt wordt een bestelling, wat eerst langs Claude moet een taak
        $gekozen = @($open)
        foreach ($pl in $plekken) {
            $l = Zoek $pl $p $gekozen $teller
            if ($l) { $pl.les = $l.id; $gekozen += $l.id; $teller[$l.id] = [int]$teller[$l.id] + 1; continue }
            $wacht = Zoek $pl $p $gekozen $teller -Wachtend
            foreach ($x in $wacht) { if ($x.reden -eq 'cel') { $celBepalen[$x.les] = $true } else { $herzien[$x.les] = $(if ($lesVan[$x.les].juistLangst) { 'juistLangst' } else { 'vormAfwijkend' }) } }
            if (-not $wacht.Count) {
                $k = "$($pl.vak)|$($pl.vaardigheid)|$($pl.niveau)|$(if ($pl.cel) { $pl.cel } else { 'alle' })"
                if (-not $bestel.Contains($k)) { $it = $items[$pl.vaardigheid]; $bestel[$k] = [ordered]@{ vak = $pl.vak; vaardigheid = $pl.vaardigheid; hoofdgebied = $it.naam; onderwerp = $it.onderwerp; omschrijving = $it.omschrijving; notitie = $it.notitie; type = $pl.type; niveau = $pl.niveau; cel = $(if ($pl.cel) { $pl.cel } else { 'alle' }); aantal = 0 } }
                $bestel[$k].aantal++
            }
        }
        $plan[$id] = [ordered]@{ cel = $p.cel; vakken = @($vakken.Keys); gem = [math]::Round($gem, 2); open = $open; plekken = $plekken; gedaan = @($p.gedaan) }
        # Voor Claude alleen wat oordeel vraagt: geen scores of resultaten
        $personen[$id] = [ordered]@{ cel = $p.cel; project = $c.project; vakken = $c.vakken; ervaring = $(if (-not $scores.Count) { 'onbekend' } elseif ($gem -ge 3.5) { 'ervaren' } elseif ($gem -ge 2.5) { 'gemiddeld' } else { 'beginner' })
            focus = $c.focus; leerdoelen = $c.leerdoelen; wachtrij = @($open + @($plekken | Where-Object les | ForEach-Object { $_.les })); open = @($plekken | Where-Object { -not $_.les }).Count }
    }

    # Voorraadtips: per vak, vaardigheid en cel de vraag (wie hem laag scoort of nog niet ingevuld heeft, gewogen naar prioriteit)
    # tegenover het aanbod (actieve lessen voor die cel of 'alle'). Vaardigheden zonder enkele les eerst.
    $tips = @()
    foreach ($vak in @($perVak.Keys)) {
        $leden = @($plan.Keys | Where-Object { $plan[$_].vakken -contains $vak })
        if (-not $leden.Count) { continue }
        foreach ($vid in $perVak[$vak]) {
            $alle = @($index | Where-Object { $_.actief -ne $false -and @($_.matrix) -contains $vid })
            foreach ($cel in @(@($leden | ForEach-Object { if ($plan[$_].cel) { $plan[$_].cel } else { 'alle' } }) | Select-Object -Unique)) {
                $vraag = 0
                foreach ($lid in @($leden | Where-Object { $(if ($plan[$_].cel) { $plan[$_].cel } else { 'alle' }) -eq $cel })) {
                    $s = $ctx.leden.$lid.scores.$vid; $pr = $ctx.leden.$lid.prioriteit.($items[$vid].hoofdgebied)
                    if (-not $s -or [int]$s -le 2) { $vraag += @{ 1 = 2.0; 2 = 1.0; 3 = 0.34 }[$(if ($pr) { [int]$pr } else { 2 })] }
                }
                if (-not $vraag) { continue }
                $aanbod = @($alle | Where-Object { $_.cel -eq $cel -or $_.cel -eq 'alle' -or ($cel -eq 'alle' -and $_.cel) }).Count
                $tips += [pscustomobject]@{ vak = $vak; vaardigheid = $vid; hoofdgebied = $items[$vid].naam; onderwerp = $items[$vid].onderwerp; omschrijving = $items[$vid].omschrijving; cel = $cel; lessen = $aanbod; zonderLes = -not $alle.Count; score = $vraag / (1 + $aanbod) }
            }
        }
    }
    $tips = @($tips | Sort-Object @{ e = { -not $_.zonderLes } }, @{ e = { $_.score }; Descending = $true } | Select-Object -First 20 | Select-Object vak, vaardigheid, hoofdgebied, onderwerp, omschrijving, cel, lessen, zonderLes)
    # Lessen van het team en nieuws van de laatste 14 dagen worden bij het toewijzen vooraan gezet; een teamles zonder cel kan Claude
    # niet labelen (die is van een head), dus Claude beoordeelt alleen of hij past en zet hem anders bij 'nietVoor' in de wensen.
    Schrijf (Join-Path $Map 'regelaar.json') ([ordered]@{ v = 1; vandaag = $nu.ToString('yyyy-MM-dd'); leden = $plan })
    Schrijf (Join-Path $Map 'werk.json') ([ordered]@{
        v = 1; vandaag = $nu.ToString('yyyy-MM-dd'); vakgebied = $standaard; vakken = @($perVak.Keys | Where-Object { $v = $_; @($plan.Values | Where-Object { $_.vakken -contains $v }).Count }); cellen = $cellen
        bestellingen = @($bestel.Values | Sort-Object { -$_.aantal })
        voorraad = $tips
        herzienEerst = @($herzien.Keys | Sort-Object | ForEach-Object { [ordered]@{ les = $_; reden = $herzien[$_] } })
        celBepalen = @($celBepalen.Keys | Sort-Object)
        personen = $personen
        lesstatistiek = $ctx.lesstatistiek; feedback = $ctx.feedback
    })
    $nOpen = (@($plan.Values | ForEach-Object { @($_.plekken | Where-Object { -not $_.les }).Count }) | Measure-Object -Sum).Sum
    Write-Host "Regelaar: $($plan.Count) deelnemer(s), $nOpen open plek(ken), $($bestel.Count) bestelling(en), $($herzien.Count) les(sen) eerst herzien, $($celBepalen.Count) zonder cel"
    return
}

# ---------------------------------------------------------------- toewijzen
$rp = Lees (Join-Path $Map 'regelaar.json')
$wensen = $null; $wPad = Join-Path $Map 'wachtrijen.json'
if (Test-Path $wPad) { try { $wensen = Lees $wPad } catch { Write-Host '  wachtrijen.json van Claude is geen geldige JSON: wensen genegeerd' } }
$teller = @{}; $uit = [ordered]@{}; $genegeerd = 0; $gevuld = 0; $leeg = 0; $vervangen = 0
foreach ($id in @($rp.leden.PSObject.Properties.Name)) {
    $r = $rp.leden.$id
    $p = [pscustomobject]@{ id = $id; cel = [string]$r.cel; gedaan = New-Object 'System.Collections.Generic.HashSet[string]' }
    foreach ($g in @($r.gedaan)) { if ($g) { [void]$p.gedaan.Add([string]$g) } }
    # Wensen van Claude: een lijst les-id's, of { wensen: [...], nietVoor: [...] } (nietVoor: past niet bij deze persoon)
    $nietVoor = @(); $wens = @()
    $wObj = if ($wensen) { $wensen.$id }
    if ($wObj -is [array] -or $wObj -is [string]) { $wens = @($wObj) } elseif ($wObj) { $wens = @($wObj.wensen); $nietVoor = @($wObj.nietVoor) }
    # Een teamles zonder cel kan Claude niet labelen (die is van een head): die mag, tenzij Claude hem bij 'nietVoor' zette
    $mag = { param($l) $l -and @($r.vakken) -contains (VakVanLes $l) -and $nietVoor -notcontains $l.id -and ((Bruikbaar $l $p (VakVanLes $l)) -eq 'ja' -or ($l.herkomst -eq 'team' -and (Bruikbaar $l $p (VakVanLes $l)) -eq 'cel')) }
    # Vooraan: nieuws en lessen van het team van de laatste 14 dagen; een teamles op basisniveau niet voor een ervaren collega
    $vooraan = @($index | Where-Object {
        $dag = DatumVanId $_.id
        ($_.type -eq 'nieuws' -or $_.herkomst -eq 'team') -and $dag -and ($nu - $dag).Days -le 14 -and (& $mag $_) -and
        -not ($_.type -ne 'nieuws' -and $_.niveau -eq 'basis' -and [double]$r.gem -ge 3.5)
    } | Sort-Object @{ e = { if ($_.type -eq 'nieuws') { 0 } else { 1 } } }, id | ForEach-Object { $_.id })
    # Wensen van Claude (bijv. een les die bij iemands leerdoelen past): alleen als ze volgens de regels mogen
    $ok = @(); foreach ($x in $wens) { $l = $lesVan[[string]$x]; if ((& $mag $l) -or ($l -and $l.soort -eq 'maak-met-claude' -and (Bruikbaar $l $p (VakVanLes $l)) -eq 'ja')) { $ok += $l.id } elseif ($x) { $genegeerd++ } }
    $lijst = @($vooraan + $ok + @($r.open | Where-Object { & $mag $lesVan[$_] }))
    $leegPl = @()
    foreach ($pl in @($r.plekken)) {
        $id2 = $pl.les
        if (-not $id2 -or -not (& $mag $lesVan[$id2]) -or $lijst -contains $id2) { $l = Zoek $pl $p $lijst $teller; $id2 = if ($l) { $l.id } }
        if ($id2) { $lijst += $id2; $teller[$id2] = [int]$teller[$id2] + 1; if (-not $pl.les) { $gevuld++ } } else { $leegPl += $pl }
    }
    # Nog een lege plek (bijv. de wachtende les bleek na het labelen bij een andere cel te horen, of een bestelling lukte niet):
    # een andere passende meerkeuzeles van hetzelfde vak en niveau, zodat de wachtrij vol blijft. Morgen plant de regelaar opnieuw.
    foreach ($pl in $leegPl) {
        if (@($lijst | Select-Object -Unique).Count -ge $WACHTRIJ) { break }
        $v = @($index | Where-Object { $_.soort -eq 'meerkeuze' -and $_.niveau -eq $pl.niveau -and (VakVanLes $_) -eq $pl.vak -and $lijst -notcontains $_.id -and (& $mag $_) }) |
            Sort-Object @{ e = { if ($_.cel -eq $p.cel) { 0 } else { 1 } } }, @{ e = { [int]$teller[$_.id] } }, @{ e = { Kans } } | Select-Object -First 1
        if ($v) { $lijst += $v.id; $teller[$v.id] = [int]$teller[$v.id] + 1; $vervangen++ } else { $leeg++ }
    }
    # Nooit twee schrijfopdrachten en hooguit één per wachtrij; daarna afkappen (vooraan en wensen gaan voor)
    $def = @(); $schrijf = 0
    foreach ($x in @($lijst | Select-Object -Unique)) { $l = $lesVan[$x]; if ($l.soort -ne 'meerkeuze') { if ($schrijf) { continue }; $schrijf++ }; $def += $x }
    $uit[$id] = @($def | Select-Object -First ([math]::Max($WACHTRIJ, @($vooraan + $ok).Count)))
}
Schrijf $wPad $uit
Write-Host "Toewijzen: $($uit.Count) wachtrij(en), $gevuld plek(ken) gevuld met nieuwe of herstelde lessen, $vervangen met een andere passende les, $leeg nog leeg$(if ($genegeerd) { ", $genegeerd wens(en) genegeerd (niet volgens de regels)" })"
