# Controle van één les (lessen gaan naar alle deelnemers): verplichte velden, opdrachtsoort, lengte en alleen https-bronnen.
# Geeft een lijst met fouten terug (leeg = goed). Gebruikt door generator-publiceer.ps1 en voorstellen-opnemen.ps1.
function Test-DlLes($l, [string]$Id, [int]$Lengte) {
    $fouten = @()
    if ($l.id -ne $Id -or $l.id -notmatch '^[0-9a-z][0-9a-z\-]{2,80}$') { $fouten += 'id moet gelijk zijn aan de bestandsnaam (a-z, 0-9, -)' }
    foreach ($veld in 'titel', 'uitleg', 'vakgebied') { if (-not $l.$veld) { $fouten += "$veld ontbreekt" } }
    if ($l.opdracht.soort -notin 'meerkeuze', 'open', 'zoek-op', 'maak-met-claude') { $fouten += 'onbekende opdrachtsoort' }
    if ($l.opdracht.soort -eq 'meerkeuze' -and (@($l.opdracht.opties).Count -ne 4 -or [int]$l.opdracht.juist -notin 0..3)) { $fouten += 'meerkeuze heeft 4 opties en juist 0-3 nodig' }
    if ($l.bron -and $l.bron.url) {
        $u = $null
        if (-not ([Uri]::TryCreate([string]$l.bron.url, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -eq 'https' -and -not $u.IsUnc -and ([string]$l.bron.url).Length -le 500)) { $fouten += 'bron.url moet een https-adres zijn' }
    }
    # Optionele kennisvideo: alleen een YouTube-video (zie sjablonen/<vakgebied>/videos.json), met titel
    if ($l.video) {
        if ([string]$l.video.url -notmatch '^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$') { $fouten += 'video.url moet een YouTube-video zijn (https://www.youtube.com/watch?v=...)' }
        if (-not $l.video.titel -or ([string]$l.video.titel).Length -gt 200) { $fouten += 'video.titel ontbreekt of is te lang' }
    }
    if ($Lengte -gt 20000) { $fouten += 'te groot' }
    , $fouten
}
