# Voor de lesgenerator: controleert nieuwe lessen, zet de wachtrijen uit wachtrijen.json versleuteld en ondertekend
# klaar per deelnemer, werkt de lessenindex bij en ruimt de ontsleutelde context altijd op (ook bij een fout).
#   wachtrijen.json:  { "lid-xxxxxx": ["les-id-1", "les-id-2", "les-id-3"], ... }   (les-id's moeten in lessen/ staan)
param([string]$DataMap, [string]$Thuis, [string]$Map, [switch]$Push)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
if (-not $Map) { $Map = Join-Path $Thuis 'generator' }
try {
    $geheim = Read-DlGeheim (Join-Path $Thuis 'beheer.dpapi'); if (-not $geheim) { throw 'Geen beheergeheimen: draai beheer.ps1 -Init' }
    . (Join-Path $PSScriptRoot 'kloon.ps1')
    $kloon = $null
    if (-not $DataMap) { $kloon = Get-DlKloon $Thuis; if ($kloon) { Update-DlKloon $kloon; $DataMap = $kloon } }
    $d =if ($DataMap) { New-DlOpslag -Map $DataMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token }
    $V = [pscustomobject]@{ kty = 'RSA'; n = $geheim.generatorPrive.n; e = $geheim.generatorPrive.e }

    # 1. Elke les controleren: verplichte velden, lengtes en alleen https-bronnen (lessen gaan naar alle laptops)
    $fouten = @()
    foreach ($f in Get-ChildItem (Join-Path $App 'lessen') -Filter *.json | Where-Object Name -ne 'index.json') {
        try { $l = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $fouten += "$($f.Name): geen geldige JSON"; continue }
        if ($l.id -ne $f.BaseName -or $l.id -notmatch '^[0-9a-z][0-9a-z\-]{2,80}$') { $fouten += "$($f.Name): id moet gelijk zijn aan de bestandsnaam (a-z, 0-9, -)" }
        foreach ($veld in 'titel', 'uitleg', 'vakgebied') { if (-not $l.$veld) { $fouten += "$($f.Name): $veld ontbreekt" } }
        if ($l.opdracht.soort -notin 'meerkeuze', 'open', 'zoek-op', 'maak-met-claude') { $fouten += "$($f.Name): onbekende opdrachtsoort" }
        if ($l.opdracht.soort -eq 'meerkeuze' -and (@($l.opdracht.opties).Count -ne 4 -or [int]$l.opdracht.juist -notin 0..3)) { $fouten += "$($f.Name): meerkeuze heeft 4 opties en juist 0-3 nodig" }
        if ($l.bron -and $l.bron.url) {
            $u = $null
            if (-not ([Uri]::TryCreate([string]$l.bron.url, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -eq 'https' -and -not $u.IsUnc -and ([string]$l.bron.url).Length -le 500)) { $fouten += "$($f.Name): bron.url moet een https-adres zijn" }
        }
        if (([IO.File]::ReadAllText($f.FullName)).Length -gt 20000) { $fouten += "$($f.Name): te groot" }
    }
    if ($fouten.Count) { throw "Lessen afgekeurd, niets gepubliceerd:`n  $($fouten -join "`n  ")" }

    & (Join-Path $PSScriptRoot 'lessen-index.ps1')
    $bekend = @((Get-Content (Join-Path $App 'lessen\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).lessen.id)

    # 2. Wachtrijen versleutelen en ondertekenen met de generatorsleutel
    $w = Get-Content (Join-Path $Map 'wachtrijen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $w.PSObject.Properties) {
        $id = $p.Name; $lijst = @($p.Value | Where-Object { $_ })
        $onbekend = @($lijst | Where-Object { $bekend -notcontains $_ })
        if ($onbekend.Count) { throw "Onbekende les-id's voor ${id}: $($onbekend -join ', ')" }
        $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t) { Write-Host "  $id overgeslagen: nog niet goedgekeurd"; continue }
        $s = Get-DlSleutelsUitDk (Unprotect-DlRsa $geheim.generatorPrive (ConvertFrom-B64u $t.kopieen.generator))
        $nieuw = [ordered]@{ v = 1; bijgewerkt = (Get-Date).ToString('s'); lessen = $lijst }
        $b = Read-DlOpslag $d (Get-DlLidPad $id 'wachtrij')      # wordt volledig vervangen
        Write-DlVersleuteld $d $id 'wachtrij' $s $nieuw $(if ($b) { $b.sha }) 'generator' $geheim.generatorPrive | Out-Null
        Write-Host "  $id`: $($lijst.Count) les(sen) klaargezet"
    }
    if ($kloon) { Push-DlKloon $kloon; Write-Host 'Wachtrijen verstuurd naar de data-repo.' }
    if ($Push) { Push-Location $App; try { git add -A lessen; git commit -q -m 'Lessen bijgewerkt' 2>$null; git push -q } finally { Pop-Location } }
}
finally {
    # Ontsleutelde context en verwerkte wachtrijen altijd opruimen
    Remove-Item (Join-Path $Map 'context.json'), (Join-Path $Map 'wachtrijen.json') -ErrorAction SilentlyContinue
}
