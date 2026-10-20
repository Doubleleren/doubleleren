# Een regel om DoubleLeren te installeren of bij te werken:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/doubleleren/doubleleren/main/app/start.ps1 | iex"
# Haalt de benodigde bestanden op via api.github.com (lijst) en raw.githubusercontent.com (inhoud),
# zet ze in %USERPROFILE%\.doubleleren\programma en start de installer.
# Bewust zonder BOM en alleen ASCII, zodat 'irm | iex' het goed leest. (eigenaar/repo gelijk houden met instellingen.json)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]'Tls13' } catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$eigenaar = 'doubleleren'; $repo = 'doubleleren'
$thuis = Join-Path $env:USERPROFILE '.doubleleren'
$doel = Join-Path $thuis 'programma'
$tmp = Join-Path $thuis ('download-' + [guid]::NewGuid().ToString('N'))
$kop = @{ 'User-Agent' = 'DoubleLeren' }
Write-Host 'DoubleLeren wordt gedownload...'
$boom = Invoke-RestMethod "https://api.github.com/repos/$eigenaar/$repo/git/trees/main?recursive=1" -Headers $kop -UseBasicParsing
$paden = @($boom.tree | Where-Object { $_.type -eq 'blob' -and ($_.path -eq 'instellingen.json' -or $_.path -like 'app/*' -or $_.path -like 'sjablonen/*') } | ForEach-Object { $_.path })
if ($paden.Count -lt 5) { throw 'Kon de lijst met bestanden niet ophalen.' }
# Een webfilter (bijv. Cisco Umbrella) kan losse bestanden vervangen door een HTML-blokkeerpagina. Het Excel-inleesscript
# is optioneel (de skilllijst gaat via de website); elk ander geblokkeerd bestand stopt de installatie.
$optioneel = @('app/lib/skilllijst.ps1')
foreach ($p in $paden) {
    $uit = Join-Path $tmp ($p -replace '/', '\')
    New-Item -ItemType Directory (Split-Path $uit) -Force | Out-Null
    Invoke-WebRequest "https://raw.githubusercontent.com/$eigenaar/$repo/main/$p" -OutFile $uit -Headers $kop -UseBasicParsing
    if ([IO.File]::ReadAllText($uit) -match '^\s*<(!doctype|html)') {
        Remove-Item $uit
        if ($optioneel -notcontains $p) { Remove-Item $tmp -Recurse -Force; throw "Een webfilter blokkeert $p. Vraag IT om raw.githubusercontent.com/doubleleren toe te staan, of gebruik alleen de website." }
        Write-Host "Overgeslagen (webfilter): $p - niet nodig voor de pop-up."
    }
}
if (Test-Path $doel) { Remove-Item $doel -Recurse -Force }
Move-Item $tmp $doel
Write-Host "$($paden.Count) bestanden opgehaald."
$cfgPad = Join-Path $thuis 'config.json'
if ((Test-Path $cfgPad) -and (Get-Content $cfgPad -Raw | ConvertFrom-Json).vertrouwd) { Write-Host 'Bijgewerkt naar de nieuwste versie.'; return }
Write-Host 'Het installatievenster wordt geopend.'
# In hetzelfde venster starten (sommige beveiliging blokkeert het openen van een nieuw PowerShell-proces)
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Open Windows PowerShell via het Startmenu en probeer het daar opnieuw.' }
& (Join-Path $doel 'app\installeer.ps1')
