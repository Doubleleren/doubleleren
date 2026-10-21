# De pop-up werkt zichzelf bij: hoogstens één keer per dag kijken of er in de app-repo iets veranderde onder app/, en zo ja
# dezelfde bestanden ophalen als de installatieregel (start.ps1). Eerst naar een tijdelijke map; pas als alles compleet is,
# wordt de oude versie omgewisseld. Config, sleutels en status staan apart in %USERPROFILE%\.doubleleren en blijven staan.
# Geeft $true terug als er een nieuwe versie is geplaatst (die geldt vanaf de volgende start).
function Update-DlProgramma([string]$Thuis, [string]$Eigenaar = 'doubleleren', [string]$Repo = 'doubleleren') {
    $ErrorActionPreference = 'Stop'     # elke fout stopt; de versie wordt alleen genoteerd als alles gelukt is
    $doel = Join-Path $Thuis 'programma'; $merk = Join-Path $Thuis 'bijwerken.json'
    $vandaag = (Get-Date).ToString('yyyy-MM-dd')
    $st = $null; if (Test-Path $merk) { try { $st = Get-Content $merk -Raw | ConvertFrom-Json } catch {} }
    if ($st -and $st.gecontroleerd -eq $vandaag) { return $false }
    $kop = @{ 'User-Agent' = 'DoubleLeren' }
    $c = Invoke-RestMethod "https://api.github.com/repos/$Eigenaar/$Repo/commits?path=app&per_page=1" -Headers $kop -UseBasicParsing -TimeoutSec 20
    $versie = [string]@($c)[0].sha
    if ($versie -notmatch '^[0-9a-f]{40}$') { throw 'Kon de nieuwste versie niet bepalen.' }
    $nieuw = -not ($st -and $st.versie -eq $versie)
    if ($nieuw) {
        $boom = Invoke-RestMethod "https://api.github.com/repos/$Eigenaar/$Repo/git/trees/$versie`?recursive=1" -Headers $kop -UseBasicParsing -TimeoutSec 30
        $paden = @($boom.tree | Where-Object { $_.type -eq 'blob' -and ($_.path -eq 'instellingen.json' -or $_.path -like 'app/*' -or $_.path -like 'sjablonen/*') } | ForEach-Object { $_.path })
        if ($paden.Count -lt 5) { throw 'Kon de lijst met bestanden niet ophalen.' }
        $optioneel = @('app/lib/skilllijst.ps1')      # een webfilter blokkeert dit soms; de pop-up heeft het niet nodig
        $tmp = Join-Path $Thuis ('bijwerken-' + [guid]::NewGuid().ToString('N'))
        try {
            foreach ($p in $paden) {
                $uit = Join-Path $tmp ($p -replace '/', '\')
                New-Item -ItemType Directory (Split-Path $uit) -Force | Out-Null
                Invoke-WebRequest "https://raw.githubusercontent.com/$Eigenaar/$Repo/$versie/$p" -OutFile $uit -Headers $kop -UseBasicParsing -TimeoutSec 30
                if ([IO.File]::ReadAllText($uit) -match '^\s*<(!doctype|html)') {
                    Remove-Item $uit
                    if ($optioneel -notcontains $p) { throw "Een webfilter blokkeert $p." }
                }
            }
            if (-not (Test-Path (Join-Path $tmp 'app\dagelijkse-les.ps1'))) { throw 'Download onvolledig.' }
            # Omwisselen: oude versie opzij, nieuwe op zijn plek, oude weg (lukt het niet, dan terug)
            $oud = Join-Path $Thuis 'programma-oud'
            Remove-Item $oud -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $doel) { Move-Item $doel $oud }
            try { Move-Item $tmp $doel } catch { if (Test-Path $oud) { Move-Item $oud $doel }; throw }
            Remove-Item $oud -Recurse -Force -ErrorAction SilentlyContinue
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [IO.File]::WriteAllText($merk, ([ordered]@{ gecontroleerd = $vandaag; versie = $versie } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $nieuw
}
