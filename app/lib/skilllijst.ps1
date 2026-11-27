# Leest een skilllijst-Excel (.xlsx, zelfde opzet als de SEO-sheet) en koppelt elke vaardigheid aan het sjabloon.
#   $r = Import-DlSkilllijst -Xlsx 'C:\...\SEO kennis.xlsx' -Sjabloon 'sjablonen\seo\skilllijst.csv'
#   $r.matrix  -> @{ v=1; sjabloon='seo'; scores = @{ '1.1.1' = @{ '2026-06' = 2 } } }
#   $r.gekoppeld, $r.nietGevonden
# Ander vak dan het standaardvak: -Vak cro geeft id's als 'cro:1.1.1' (het standaardvak houdt kale id's).
# Opzet sheet: A = hoofdgebied, B = onderwerp, C = vaardigheid (of een inleidende zin zonder score),
# D..I = maand 1..6 (D1 = datum van maand 1), J = huidige score.

# Meer tabbladen (bijv. uitleg + een blad per persoon): alleen een blad met vaardigheden ("- ..." in kolom C) telt;
# zijn dat er meer, dan het blad met de voornaam uit -Naam in de bladnaam, anders het blad met de meeste scores,
# anders het eerste (in tabbladvolgorde). Spiegelbeeld van leesXlsx in docs/xlsx.js.
function Read-DlXlsx([string]$Pad, [string]$Naam) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Pad)
    try {
        $lees = { param($naam) $e = $zip.GetEntry($naam); if (-not $e) { return $null }; $s = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8); try { $s.ReadToEnd() } finally { $s.Dispose() } }
        $gedeeld = @()
        $ssXml = & $lees 'xl/sharedStrings.xml'
        if ($ssXml) {
            $ss = [xml]$ssXml
            foreach ($si in $ss.sst.si) { $gedeeld += (($si.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText }) -join '') }
        }
        $leesBlad = {
            param($pad)
            $x = [xml](& $lees $pad)
            $rijen = @{}
            foreach ($rij in $x.worksheet.sheetData.row) {
                $cellen = @{}
                foreach ($c in $rij.c) {
                    if ($null -eq $c.v -and -not $c.is) { continue }
                    $kol = ($c.r -replace '\d', '')
                    $w = if ($c.t -eq 's') { $gedeeld[[int]$c.v] } elseif ($c.t -eq 'inlineStr') { $c.is.InnerText } else { [string]$c.v }
                    $cellen[$kol] = $w
                }
                $rijen[[int]$rij.r] = $cellen
            }
            $rijen
        }
        # Werkbladen in tabbladvolgorde (workbook.xml + rels); zonder workbook.xml op bestandsnaam
        $bestanden = @($zip.Entries | Where-Object { $_.FullName -match '^xl/worksheets/sheet\d+\.xml$' } | ForEach-Object FullName | Sort-Object)
        $bladen = @()
        $wbXml = & $lees 'xl/workbook.xml'; $relsXml = & $lees 'xl/_rels/workbook.xml.rels'
        if ($wbXml -and $relsXml) {
            $doel = @{}
            foreach ($r in ([xml]$relsXml).SelectNodes('//*[local-name()="Relationship"]')) { $t = $r.GetAttribute('Target'); $doel[$r.GetAttribute('Id')] = if ($t.StartsWith('/')) { $t.Substring(1) } else { "xl/$t" } }
            foreach ($s in ([xml]$wbXml).SelectNodes('//*[local-name()="sheet"]')) {
                $p = $doel[$s.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')]
                if ($p -and $bestanden -contains $p) { $bladen += [pscustomobject]@{ naam = $s.GetAttribute('name'); pad = $p } }
            }
        }
        if (-not $bladen.Count) { $bladen = @($bestanden | ForEach-Object { [pscustomobject]@{ naam = $_; pad = $_ } }) }
        if (-not $bladen.Count) { throw 'Geen werkblad gevonden in het Excel-bestand.' }
        if ($bladen.Count -eq 1) { return (& $leesBlad $bladen[0].pad) }
        $woorden = { param($t) @([regex]::Matches("$t".ToLower(), '\p{L}+') | ForEach-Object Value) }
        $voornaam = @(& $woorden $Naam)[0]
        $kandidaten = @(foreach ($b in $bladen) {
            $rijen = & $leesBlad $b.pad; $n = 0; $scores = 0
            foreach ($c in $rijen.Values) {
                if ("$($c.C)" -notmatch '^\s*[-–•]') { continue }
                $n++; foreach ($k in 'D', 'E', 'F', 'G', 'H', 'I') { if ("$($c[$k])" -match '^[1-5](\.0+)?$') { $scores++ } }
            }
            if ($n) { [pscustomobject]@{ naam = $b.naam; rijen = $rijen; scores = $scores } }
        })
        if (-not $kandidaten.Count) { return (& $leesBlad $bladen[0].pad) }
        $keuze = if ("$voornaam".Length -gt 1) { $kandidaten | Where-Object { (& $woorden $_.naam) -contains $voornaam } | Select-Object -First 1 }
        if (-not $keuze) { $keuze = $kandidaten[0]; foreach ($k in $kandidaten) { if ($k.scores -gt $keuze.scores) { $keuze = $k } } }
        $keuze.rijen
    } finally { $zip.Dispose() }
}

function Repair-DlTekst([string]$T) {
    # Excel-exports met kapotte tekens (U+FFFD) herstellen voor bekende woorden
    $T = $T.Replace("ici$([char]0xFFFD)n", 'iciën').Replace("be$([char]0xFFFD)nvl", 'beïnvl').Replace("ge$([char]0xFFFD)nd", 'geïnd')
    $T.Trim()
}
function Get-DlSleutelTekst([string]$T) { ((Repair-DlTekst $T).ToLower() -replace '^[-\s]+', '' -replace '[^a-z0-9ëïéèäöü]+', ' ').Trim() }

function Import-DlSkilllijst([string]$Xlsx, [string]$Sjabloon, [string]$Vak, [string]$Naam) {
    $sj = @(Import-Csv $Sjabloon -Delimiter ';' -Encoding UTF8)
    $index = @{}; foreach ($s in $sj) { $index["$(Get-DlSleutelTekst $s.onderwerp)|$(Get-DlSleutelTekst $s.vaardigheid)"] = $s.id }

    $rijen = Read-DlXlsx $Xlsx $Naam
    # Maand 1 uit D1 (Excel-datum); E..I zijn de maanden erna
    $start = (Get-Date -Day 1).Date
    $d1 = $rijen[1].D
    if ($d1 -match '^\d+(\.0+)?$') { $start = [datetime]::FromOADate([double]$d1); $start = Get-Date -Year $start.Year -Month $start.Month -Day 1 }
    $maandKol = [ordered]@{}; $i = 0
    foreach ($k in 'D', 'E', 'F', 'G', 'H', 'I') { $maandKol[$k] = $start.AddMonths($i).ToString('yyyy-MM'); $i++ }
    $nu = (Get-Date).ToString('yyyy-MM')

    $scores = [ordered]@{}; $nietGevonden = @(); $onderwerp = ''; $volgorde = 0
    foreach ($r in ($rijen.Keys | Sort-Object)) {
        $c = $rijen[$r]
        if ($r -eq 1) { continue }
        if ($c.B) { $onderwerp = $c.B; continue }
        if (-not $c.C) { continue }
        $heeftScore = $false; foreach ($k in @($maandKol.Keys) + 'J') { if ("$($c[$k])" -match '^[1-5](\.0+)?$') { $heeftScore = $true } }
        if (-not $heeftScore) { continue }     # inleidende zin of voortgangsregel
        $volgorde++
        $sleutel = "$(Get-DlSleutelTekst $onderwerp)|$(Get-DlSleutelTekst $c.C)"
        $id = $index[$sleutel]
        if (-not $id -and $volgorde -le $sj.Count) { $id = $sj[$volgorde - 1].id; $nietGevonden += "rij $r gekoppeld op volgorde aan $id ($(Repair-DlTekst $c.C))" }
        if (-not $id) { $nietGevonden += "rij $r niet gekoppeld: $(Repair-DlTekst $c.C)"; continue }
        $s = [ordered]@{}
        foreach ($k in $maandKol.Keys) { if ("$($c[$k])" -match '^([1-5])(\.0+)?$') { $s[$maandKol[$k]] = [int]$Matches[1] } }
        if ($s.Count -eq 0 -and "$($c.J)" -match '^([1-5])(\.0+)?$') { $s[$nu] = [int]$Matches[1] }
        $scores[$(if ($Vak) { "$Vak`:$id" } else { $id })] = $s
    }
    [pscustomobject]@{
        matrix       = [ordered]@{ v = 1; sjabloon = (Split-Path (Split-Path $Sjabloon) -Leaf); scores = $scores }
        gekoppeld    = $scores.Count
        totaal       = $sj.Count
        nietGevonden = $nietGevonden
    }
}
