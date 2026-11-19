# Maakt een nep-skilllijst (.xlsx, zelfde opzet als de echte SEO-sheet) uit het sjabloon, met vaste scores 1-5.
# Voor tests en de lokale demo: niemand heeft dan een eigen (persoonlijke) Excel nodig.
#   powershell -ExecutionPolicy Bypass -File test\nep-skilllijst.ps1 -Uit %TEMP%\nep-skilllijst.xlsx
# Maand 1 (D1) is juni 2026; elke vaardigheid krijgt één score in kolom D.
param([Parameter(Mandatory)][string]$Uit, [string]$Sjabloon)
$ErrorActionPreference = 'Stop'
if (-not $Sjabloon) { $Sjabloon = Join-Path (Split-Path $PSScriptRoot -Parent) 'sjablonen\seo\skilllijst.csv' }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$sj = @(Import-Csv $Sjabloon -Delimiter ';' -Encoding UTF8)
$rnd = New-Object Random 42
$x = { param($t) [Security.SecurityElement]::Escape([string]$t) }
$tekst = { param($cel, $t) "<c r=`"$cel`" t=`"inlineStr`"><is><t>$(& $x $t)</t></is></c>" }

$rijen = New-Object Collections.Generic.List[string]
$juni = [datetime]::new(2026, 6, 1).ToOADate()
$rijen.Add("<row r=`"1`">$(& $tekst 'A1' 'Hoofdgebied')$(& $tekst 'B1' 'Onderwerp')$(& $tekst 'C1' 'Vaardigheid')<c r=`"D1`"><v>$juni</v></c>$(& $tekst 'J1' 'Nu')</row>")
$r = 1; $onderwerp = $null
foreach ($s in $sj) {
    if ($s.onderwerp -ne $onderwerp) {
        $onderwerp = $s.onderwerp; $r++
        $rijen.Add("<row r=`"$r`">$(& $tekst "A$r" $s.hoofdgebied)$(& $tekst "B$r" $s.onderwerp)</row>")
    }
    $r++
    $rijen.Add("<row r=`"$r`">$(& $tekst "C$r" $s.vaardigheid)<c r=`"D$r`"><v>$($rnd.Next(1, 6))</v></c></row>")
}

$delen = [ordered]@{
    '[Content_Types].xml'        = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
    '_rels/.rels'                = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    'xl/workbook.xml'            = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Skilllijst" sheetId="1" r:id="rId1"/></sheets></workbook>'
    'xl/_rels/workbook.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
    'xl/worksheets/sheet1.xml'   = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><worksheet xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`"><sheetData>$($rijen -join '')</sheetData></worksheet>"
}
Remove-Item $Uit -ErrorAction SilentlyContinue
$zip = [IO.Compression.ZipFile]::Open($Uit, 'Create')
try {
    foreach ($naam in $delen.Keys) {
        $s = New-Object IO.StreamWriter($zip.CreateEntry($naam).Open(), (New-Object Text.UTF8Encoding($false)))
        try { $s.Write($delen[$naam]) } finally { $s.Dispose() }
    }
} finally { $zip.Dispose() }
Write-Host "Nep-skilllijst: $Uit ($($sj.Count) vaardigheden)"
