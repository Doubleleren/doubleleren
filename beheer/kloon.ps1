# Data-repo via een lokale git-kopie in %USERPROFILE%\.doubleleren\beheer\data-kloon, met de git-inlog van de
# beheerder in plaats van een beheertoken. Wordt gebruikt als die kopie bestaat en er geen -DataMap is opgegeven.
#   git clone https://github.com/Doubleleren/doubleleren-data.git "%USERPROFILE%\.doubleleren\beheer\data-kloon"
# In de cloud (GitHub Actions) staat de kopie in de werkmap van de run; er is dan niets lokaal om later te versturen.
# Commits en rebases altijd onder een neutrale naam: op een runner is er geen git-naam, en een rebase heeft er een nodig.
$script:DlGitNaam = @('-c', 'user.name=doubleleren', '-c', 'user.email=sync@doubleleren.invalid')

function Get-DlKloon([string]$Thuis) {
    $k = Join-Path $Thuis 'data-kloon'
    if (Test-Path (Join-Path $k '.git')) { $k }
}
# Een half afgemaakte rebase (na een conflict) eerst afbreken: anders blijft de kopie vastzitten
function Stop-DlRebase([string]$K) {
    $ErrorActionPreference = 'Continue'
    $gd = (git -C $K rev-parse --git-dir 2>$null); if (-not $gd) { return }
    if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $K $gd }
    if ((Test-Path (Join-Path $gd 'rebase-merge')) -or (Test-Path (Join-Path $gd 'rebase-apply'))) { $null = git -C $K rebase --abort 2>&1 }
}
function Update-DlKloon([string]$K) {
    $ErrorActionPreference = 'Continue'
    Stop-DlRebase $K
    $uit = git -C $K @script:DlGitNaam pull -q --rebase 2>&1
    if ($LASTEXITCODE) { Stop-DlRebase $K; throw "Bijwerken van de data-repo (git pull) mislukt: controleer je verbinding en de map data-kloon. ($((@($uit) | Select-Object -First 3) -join ' '))" }
}
function Get-DlKloonCommit([string]$K) { $ErrorActionPreference = 'Continue'; (git -C $K rev-parse HEAD 2>$null) }
# Terug naar een eerdere stand (na een mislukte stap): standaard de versie op GitHub. Op de laptop geef je de stand van
# vlak vóór de stap mee, zodat eerder werk dat nog niet verstuurd is (bijv. na een mislukte push) bewaard blijft.
function Reset-DlKloon([string]$K, [string]$Naar = '@{u}') {
    $ErrorActionPreference = 'Continue'
    Stop-DlRebase $K
    $null = git -C $K reset -q --hard $Naar 2>&1
    $null = git -C $K clean -qfd 2>&1
}
# Staat alles in de kopie ook op GitHub? (geen eigen commits die nog niet verstuurd zijn, niets gewijzigd)
function Test-DlKloonVerstuurd([string]$K) {
    $ErrorActionPreference = 'Continue'
    $voor = git -C $K rev-list --count '@{u}..HEAD' 2>$null
    ($LASTEXITCODE -eq 0) -and ([int]$voor -eq 0) -and -not (git -C $K status --porcelain 2>$null)
}
# Commit onder een neutrale naam en push; bij een tussentijdse wijziging van een deelnemer eerst opnieuw ophalen
function Push-DlKloon([string]$K) {
    $ErrorActionPreference = 'Continue'
    $null = git -C $K add -A 2>&1
    $null = git -C $K diff --cached --quiet 2>&1
    if ($LASTEXITCODE) { $null = git -C $K @script:DlGitNaam commit -q -m sync 2>&1 }
    # Ook zonder nieuwe commit pushen: een eerder mislukte push gaat zo alsnog mee
    for ($i = 1; $i -le 3; $i++) {
        $null = git -C $K push -q 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        $null = git -C $K @script:DlGitNaam pull -q --rebase 2>&1
        if ($LASTEXITCODE) { Stop-DlRebase $K; break }      # conflict: niet blijven hangen in een rebase
    }
    if ($env:GITHUB_ACTIONS) { throw 'Versturen naar de data-repo (git push) mislukt. Er is niets verstuurd; start de run opnieuw.' }
    throw 'Versturen naar de data-repo (git push) mislukt. De wijziging staat lokaal klaar; probeer het later opnieuw.'
}
# Hoogste versie van het organogram in de git-geschiedenis (tot en met $Tot), alleen van versies met een geldige
# handtekening van de beheerder (een niet-ondertekende versie met een hoog nummer zou anders alles blokkeren). Zo valt
# een teruggezette oudere versie op, ook als die zelf wel geldig ondertekend is. Met -Cache onthoudt hij tot welke commit
# hij al keek, zodat hij daarna alleen nieuwe commits controleert (de laptop doet dit vaak).
function Get-DlHoogsteOrgVersie([string]$K, $Vertrouwd, [string]$Tot = 'HEAD', [string]$Cache) {
    $ErrorActionPreference = 'Continue'
    $oud = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8     # namen met é goed inlezen
    try {
        $max = 0; $bereik = $Tot; $c = $null
        $vf = (Get-DlVingerafdrukHex $Vertrouwd)
        if ($Cache -and (Test-Path $Cache)) {
            try { $c = Get-Content $Cache -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $c = $null }
            # Alleen bruikbaar als die commit nog in de geschiedenis zit (na een force-push niet meer) en bij dezelfde sleutel hoort
            if ($c -and $c.sleutel -eq $vf -and $c.commit -match '^[0-9a-f]{40}$') {
                $null = git -C $K merge-base --is-ancestor $c.commit $Tot 2>$null
                if ($LASTEXITCODE -eq 0) { $max = [int]$c.max; $bereik = "$($c.commit)..$Tot" } else { $c = $null }
            } else { $c = $null }
        }
        foreach ($h in @(git -C $K log --format=%H $bereik -- beheer/organisatie.json 2>$null)) {
            $tekst = (git -C $K show "${h}:beheer/organisatie.json" 2>$null) -join "`n"
            if (-not $tekst) { continue }                                   # in die commit verwijderd
            try {
                $e = $tekst.Trim() | ConvertFrom-Json
                if ([int]$e.v -ne 2 -or $e.door -ne 'beheer' -or -not (Test-DlHandtekening $Vertrouwd 'beheer|organisatie.json' 'beheer' $e.inhoud $e.sig)) { continue }
                $o = $e.inhoud | ConvertFrom-Json
                if ($o.versie -and [int]$o.versie -gt $max) { $max = [int]$o.versie }
            } catch { continue }
        }
        if ($Cache) {
            $kop = (git -C $K rev-parse $Tot 2>$null)
            if ($kop) { [IO.File]::WriteAllText($Cache, ([ordered]@{ commit = $kop; max = $max; sleutel = $vf } | ConvertTo-Json -Compress)) }
        }
        $max
    } finally { [Console]::OutputEncoding = $oud }
}
