# Controle van één les (lessen gaan naar alle deelnemers): verplichte velden, opdrachtsoort, lengte en alleen https-bronnen.
# Geeft een lijst met fouten terug (leeg = goed). Gebruikt door generator-publiceer.ps1 en voorstellen-opnemen.ps1.
function Test-DlLes($l, [string]$Id, [int]$Lengte) {
    $fouten = @()
    if ($l.id -ne $Id -or $l.id -notmatch '^[0-9a-z][0-9a-z\-]{2,80}$') { $fouten += 'id moet gelijk zijn aan de bestandsnaam (a-z, 0-9, -)' }
    foreach ($veld in 'titel', 'uitleg', 'vakgebied') { if (-not $l.$veld) { $fouten += "$veld ontbreekt" } }
    if ($null -ne $l.kort -and ($l.kort -isnot [string] -or $l.kort.Length -gt 600)) { $fouten += 'kort moet tekst zijn (hooguit 600 tekens)' }
    if ($l.kort -and "$($l.uitleg)" -match '^\s*\*\*Kort gezegd') { $fouten += "kort en een 'Kort gezegd'-alinea in de uitleg: kies er één (de gewone-taaltekst staat anders dubbel)" }
    if ($l.opdracht.soort -notin 'meerkeuze', 'open', 'zoek-op', 'maak-met-claude') { $fouten += 'onbekende opdrachtsoort' }
    if ($l.opdracht.soort -eq 'meerkeuze' -and (@($l.opdracht.opties).Count -ne 4 -or [int]$l.opdracht.juist -notin 0..3)) { $fouten += 'meerkeuze heeft 4 opties en juist 0-3 nodig' }
    # Vaste opbouw na het antwoord (generator-instructies, 'Na het antwoord'): kern, afleiders en begrippen
    if ($null -ne $l.kern -and ($l.kern -isnot [string] -or $l.kern.Length -gt 200 -or $l.opdracht.soort -ne 'meerkeuze')) { $fouten += 'kern is één zin (hooguit 200 tekens), alleen bij meerkeuze' }
    if ($null -ne $l.afleiders) {
        $a = @($l.afleiders)
        if ($l.opdracht.soort -ne 'meerkeuze' -or $a.Count -ne 4 -or @($a | Where-Object { $_ -isnot [string] -or $_.Length -gt 300 }).Count) { $fouten += 'afleiders: bij meerkeuze 4 teksten (hooguit 300 tekens), in de volgorde van de opties' }
        elseif ([int]$l.opdracht.juist -in 0..3 -and $a[[int]$l.opdracht.juist].Trim() -or @(0..3 | Where-Object { $_ -ne [int]$l.opdracht.juist -and -not $a[$_].Trim() }).Count) { $fouten += 'afleiders: één zin bij elke foute optie, leeg bij het juiste antwoord' }
        if ($l.toelichting) { $fouten += 'afleiders en toelichting: kies er één (de uitleg staat anders dubbel)' }
    }
    if ($null -ne $l.begrippen) {
        $b = @($l.begrippen)
        if ($b.Count -gt 4 -or @($b | Where-Object { $_.term -isnot [string] -or -not $_.term.Trim() -or $_.term.Length -gt 60 -or $_.uitleg -isnot [string] -or -not $_.uitleg.Trim() -or $_.uitleg.Length -gt 200 }).Count) { $fouten += 'begrippen: hooguit 4, elk met term (hooguit 60 tekens) en uitleg (hooguit 200 tekens)' }
    }
    if ($l.bron -and $l.bron.url) {
        $u = $null
        if (-not ([Uri]::TryCreate([string]$l.bron.url, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -eq 'https' -and -not $u.IsUnc -and ([string]$l.bron.url).Length -le 500)) { $fouten += 'bron.url moet een https-adres zijn' }
    }
    # Optionele kennisvideo: alleen een YouTube-video (zie sjablonen/<vakgebied>/videos.json), met titel
    if ($l.video) {
        if ([string]$l.video.url -notmatch '^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$') { $fouten += 'video.url moet een YouTube-video zijn (https://www.youtube.com/watch?v=...)' }
        if (-not $l.video.titel -or ([string]$l.video.titel).Length -gt 200) { $fouten += 'video.titel ontbreekt of is te lang' }
    }
    # Herzien na feedback of resultaten: datum en korte reden; 'actief: false' haalt een les uit de roulatie
    if ($null -ne $l.actief -and $l.actief -isnot [bool]) { $fouten += 'actief moet true of false zijn' }
    if ($null -ne $l.herzien -and "$($l.herzien)" -notmatch '^\d{4}-\d{2}-\d{2}$') { $fouten += 'herzien moet een datum zijn (JJJJ-MM-DD)' }
    if ($l.actief -eq $false -and -not $l.herzien) { $fouten += 'een les uit de roulatie heeft een herzien-datum nodig' }
    if ($null -ne $l.wijziging -and (([string]$l.wijziging).Length -gt 300 -or [string]$l.wijziging -match 'lid-[0-9a-f]{6}')) { $fouten += 'wijziging is te lang of noemt een pseudoniem' }
    if ($Lengte -gt 20000) { $fouten += 'te groot' }
    , $fouten
}
