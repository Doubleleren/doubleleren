# Bouwt lessen/index.json uit alle lessen in de pool. De pop-up gebruikt hem als reserve als een wachtrij leeg is,
# de website voor de kennisbank. Lessen zijn niet persoonlijk en staan daarom leesbaar in de app-repo.
$App = Split-Path $PSScriptRoot -Parent
$lessen = foreach ($f in Get-ChildItem (Join-Path $App 'lessen') -Filter *.json | Where-Object Name -ne 'index.json' | Sort-Object Name) {
    $l = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $r = [ordered]@{
        id = $l.id; titel = $l.titel; vakgebied = $l.vakgebied; onderwerp = $l.onderwerp; type = $l.type
        niveau = $(if ($l.niveau) { $l.niveau } else { 'basis' }); matrix = @($l.matrix | Where-Object { $_ })
        kernpunt = $l.kernpunt; bron = $l.bron; video = $l.video; soort = $l.opdracht.soort
        herkomst = $(if ($l.herkomst -eq 'team') { 'team' } else { 'generator' })
    }
    if ($l.herzien) { $r.herzien = "$($l.herzien)" }
    if ($l.actief -eq $false) { $r.actief = $false }     # uit de roulatie: nooit meer in een wachtrij, wel nog na te lezen
    # Meerkeuze waarbij het juiste antwoord ruim de langste optie is (meer dan 10%): te raden, de generator herziet hem
    elseif ($l.opdracht.soort -eq 'meerkeuze' -and @($l.opdracht.opties).Count -eq 4 -and [int]$l.opdracht.juist -in 0..3) {
        $len = @($l.opdracht.opties | ForEach-Object { "$_".Length }); $j = [int]$l.opdracht.juist
        $rest = (@(0..3 | Where-Object { $_ -ne $j } | ForEach-Object { $len[$_] }) | Measure-Object -Maximum).Maximum
        if ($len[$j] -gt 1.1 * $rest) { $r.juistLangst = $true }
        # Ook te raden op vorm: het juiste antwoord als enige met (of zonder) reden, of duidelijk de kortste.
        # Een reden is een voegwoord als 'want', een uitleg na een dubbele punt of puntkomma, of een tweede zin.
        # Afkortingen (bijv., o.a.) en een label vooraan (Let op:) tellen niet als reden.
        $reden = @($l.opdracht.opties | ForEach-Object {
            $o = "$_" -replace '(?i)\b(bijv|bv|o\.a|m\.a\.w|d\.w\.z|i\.p\.v|t\.o\.v|e\.d|enz|incl|excl|ca|nl|vs)\.', '' -replace '(?i)^\s*(let op|tip|let wel|nb)\s*:\s*', ''
            $o -match '\b(want|omdat|doordat|zodat|waardoor|daardoor|dus)\b|[:;] \S|\.\s+\S'
        })
        $andere = @(0..3 | Where-Object { $_ -ne $j })
        $redenAnders = @($andere | Where-Object { $reden[$_] }).Count
        $kortste = ($andere | ForEach-Object { $len[$_] } | Measure-Object -Minimum).Minimum
        $gem = ($andere | ForEach-Object { $len[$_] } | Measure-Object -Average).Average
        if (($reden[$j] -and $redenAnders -eq 0) -or (-not $reden[$j] -and $redenAnders -eq 3) -or ($len[$j] -lt $kortste -and $len[$j] -lt 0.7 * $gem)) {
            $r.vormAfwijkend = $true
        }
        # Nog niet in de vaste opbouw na het antwoord (kern, afleiders, begrippen): de generator zet hem om
        if (-not $l.afleiders) { $r.oudeUitleg = $true }
    }
    $r
}
$index = [ordered]@{ v = 1; bijgewerkt = (Get-Date).ToString('s'); lessen = @($lessen) }
[IO.File]::WriteAllText((Join-Path $App 'lessen\index.json'), ($index | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
Write-Host "lessen/index.json: $(@($lessen).Count) lessen"
