# Data-repo via een lokale git-kopie in %USERPROFILE%\.doubleleren\beheer\data-kloon, met de git-inlog van de
# beheerder in plaats van een beheertoken. Wordt gebruikt als die kopie bestaat en er geen -DataMap is opgegeven.
#   git clone https://github.com/Doubleleren/doubleleren-data.git "%USERPROFILE%\.doubleleren\beheer\data-kloon"

function Get-DlKloon([string]$Thuis) {
    $k = Join-Path $Thuis 'data-kloon'
    if (Test-Path (Join-Path $k '.git')) { $k }
}
function Update-DlKloon([string]$K) {
    $ErrorActionPreference = 'Continue'
    $null = git -C $K pull -q --rebase 2>&1
    if ($LASTEXITCODE) { throw 'Bijwerken van de data-repo (git pull) mislukt: controleer je verbinding en de map data-kloon.' }
}
# Commit onder een neutrale naam en push; bij een tussentijdse wijziging van een deelnemer eerst opnieuw ophalen
function Push-DlKloon([string]$K) {
    $ErrorActionPreference = 'Continue'
    $null = git -C $K add -A 2>&1
    $null = git -C $K diff --cached --quiet 2>&1
    if ($LASTEXITCODE) { $null = git -C $K -c user.name=doubleleren -c user.email=sync@doubleleren.invalid commit -q -m sync 2>&1 }
    # Ook zonder nieuwe commit pushen: een eerder mislukte push gaat zo alsnog mee
    for ($i = 1; $i -le 3; $i++) {
        $null = git -C $K push -q 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        $null = git -C $K pull -q --rebase 2>&1
    }
    throw 'Versturen naar de data-repo (git push) mislukt. De wijziging staat lokaal klaar; probeer het later opnieuw.'
}
