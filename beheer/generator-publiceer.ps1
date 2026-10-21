# Voor de lesgenerator: controleert nieuwe lessen, zet de wachtrijen uit wachtrijen.json versleuteld en ondertekend
# klaar per deelnemer, werkt de lessenindex bij en ruimt de ontsleutelde context altijd op (ook bij een fout).
#   wachtrijen.json:  { "lid-xxxxxx": ["les-id-1", "les-id-2", "les-id-3"], ... }   (les-id's moeten in lessen/ staan)
#   -Proef: alles controleren en de wachtrijen versleutelen, maar niets naar de repo's schrijven (cloud-proefrun)
param([string]$DataMap, [string]$Thuis, [string]$Map, [switch]$Push, [switch]$Proef)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim') { . (Join-Path $App "app\lib\$l.ps1") }
. (Join-Path $PSScriptRoot 'lescontrole.ps1')
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Thuis) { $Thuis = Join-Path (Get-DlThuis) 'beheer' }
if (-not $Map) { $Map = Join-Path $Thuis 'generator' }
try {
    $geheim = Read-DlGeneratorGeheim $Thuis
    . (Join-Path $PSScriptRoot 'kloon.ps1')
    $kloon = $null
    if (-not $DataMap) { $kloon = Get-DlKloon $Thuis; if ($kloon) { Update-DlKloon $kloon; $DataMap = $kloon } }
    $d =if ($DataMap) { New-DlOpslag -Map $DataMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $geheim.token }
    $V = (Get-Content (Join-Path $App 'vertrouwd.json') -Raw -Encoding UTF8 | ConvertFrom-Json).beheer   # beheersleutel: controleert alles onder beheer/

    # 1. Bestaande lessen (alleen als de app-map een git-kopie is): de generator mag eigen lessen herzien of uit de
    #     roulatie halen, maar nooit een teamles aanpassen, de herkomst wijzigen of een les verwijderen.
    #     Zo'n wijziging wordt teruggedraaid (de rest gaat gewoon door), zodat niemand door één fout geen les krijgt.
    if (Test-Path (Join-Path $App '.git')) {
        $wijz = @(git -C $App status --porcelain -- lessen | Where-Object { $_ -notmatch 'lessen/index\.json$' })
        foreach ($r in $wijz) {
            $f = $r.Substring(3).Trim('"'); $reden = $null
            if ($r -match '^( D|D )') { $reden = 'lessen worden nooit verwijderd (zet actief op false)' }
            elseif ($r -match '^( M|M |MM)') {
                $oud = (git -C $App show "HEAD:$f") -join "`n" | ConvertFrom-Json
                $tekst = [IO.File]::ReadAllText((Join-Path $App $f), [Text.Encoding]::UTF8)
                $nu = $null; try { $nu = $tekst | ConvertFrom-Json } catch {}
                if (-not $nu) { $reden = 'geen geldige JSON' }
                elseif ((Test-DlLes $nu ([IO.Path]::GetFileNameWithoutExtension($f)) $tekst.Length).Count) { $reden = (Test-DlLes $nu ([IO.Path]::GetFileNameWithoutExtension($f)) $tekst.Length) -join '; ' }
                elseif ($oud.herkomst -eq 'team') { $reden = 'een teamles wordt nooit door de generator aangepast' }
                elseif ("$($nu.herkomst)" -ne "$($oud.herkomst)") { $reden = 'de herkomst van een les mag niet veranderen' }
                elseif (-not $nu.herzien) { $reden = 'een herziene les heeft een herzien-datum nodig' }
                else { Write-Host "  herzien: $(Split-Path $f -Leaf)$(if ($nu.actief -eq $false) { ' (uit de roulatie)' })" }
            }
            if ($reden) { git -C $App checkout -q HEAD -- $f; Write-Host "  teruggedraaid: $(Split-Path $f -Leaf) ($reden)" }
        }
    }

    # 2. Elke les controleren: verplichte velden, lengtes en alleen https-bronnen (lessen gaan naar alle laptops)
    $fouten = @()
    foreach ($f in Get-ChildItem (Join-Path $App 'lessen') -Filter *.json | Where-Object Name -ne 'index.json') {
        try { $l = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $fouten += "$($f.Name): geen geldige JSON"; continue }
        foreach ($fout in (Test-DlLes $l $f.BaseName ([IO.File]::ReadAllText($f.FullName)).Length)) { $fouten += "$($f.Name): $fout" }
    }
    if ($fouten.Count) { throw "Lessen afgekeurd, niets gepubliceerd:`n  $($fouten -join "`n  ")" }

    & (Join-Path $PSScriptRoot 'lessen-index.ps1')
    $alleLessen = @((Get-Content (Join-Path $App 'lessen\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).lessen)
    $bekend = @($alleLessen.id)
    $inactief = @($alleLessen | Where-Object { $_.actief -eq $false } | ForEach-Object { $_.id })

    # 3. Wachtrijen versleutelen en ondertekenen met de generatorsleutel
    $w = Get-Content (Join-Path $Map 'wachtrijen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $w.PSObject.Properties) {
        $id = $p.Name; $lijst = @($p.Value | Where-Object { $_ })
        $onbekend = @($lijst | Where-Object { $bekend -notcontains $_ })
        if ($onbekend.Count) { throw "Onbekende les-id's voor ${id}: $($onbekend -join ', ')" }
        $uit = @($lijst | Where-Object { $inactief -contains $_ })
        if ($uit.Count) { $lijst = @($lijst | Where-Object { $inactief -notcontains $_ }); Write-Host "  $($uit.Count) les(sen) uit de roulatie uit een wachtrij gehaald" }
        $t = Read-DlBeheer $d "toegang/$id.json" $V; if (-not $t) { Write-Host "  $id overgeslagen: nog niet goedgekeurd"; continue }
        $s = Get-DlSleutelsUitDk (Unprotect-DlRsa $geheim.generatorPrive (ConvertFrom-B64u $t.kopieen.generator))
        $nieuw = [ordered]@{ v = 1; bijgewerkt = (Get-Date).ToString('s'); lessen = $lijst }
        $b = Read-DlOpslag $d (Get-DlLidPad $id 'wachtrij')      # wordt volledig vervangen
        if ($Proef) {
            Protect-Dl $s "$id|wachtrij" (ConvertTo-DlEnvelop $id 'wachtrij' $nieuw 'generator' $geheim.generatorPrive) | Out-Null; $script:proefTel++
            # Ter controle: de geplande lessen per wachtrij, met een korte hash in plaats van het pseudoniem (de beheerder koppelt die lokaal)
            $hash = (-join ((Get-DlSha256 $script:DlUtf8.GetBytes("doubleleren-proef|$id"))[0..2] | ForEach-Object { $_.ToString('x2') }))
            $idx = @((Get-Content (Join-Path $App 'lessen\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json).lessen)
            Write-Host "  PROEF-WACHTRIJ $hash`: $(($lijst | ForEach-Object { $l = $idx | Where-Object id -eq $_ | Select-Object -First 1; "[$($l.type)/$($l.niveau)] $($l.titel)" }) -join ' || ')"
            continue
        }
        Write-DlVersleuteld $d $id 'wachtrij' $s $nieuw $(if ($b) { $b.sha }) 'generator' $geheim.generatorPrive | Out-Null
        Write-Host "  $id`: $($lijst.Count) les(sen) klaargezet"
    }
    if ($Proef) { Write-Host "PROEF: $($script:proefTel) wachtrij(en) versleuteld en ondertekend, $(@(Get-ChildItem (Join-Path $App 'lessen') -Filter *.json).Count - 1) lessen gecontroleerd; niets verstuurd."; return }
    # 4. Scorebord van iedereen bijwerken (ook wie de website niet opende); een fout hier houdt de lessen niet tegen
    try { & (Join-Path $PSScriptRoot 'scorebord-bijwerken.ps1') -DataMap $DataMap -Thuis $Thuis } catch { Write-Host "  Scorebord bijwerken mislukt: $($_.Exception.Message)" }
    if ($kloon) { Push-DlKloon $kloon; Write-Host 'Wachtrijen en scorebord verstuurd naar de data-repo.' }
    if ($Push) { Push-Location $App; try { git add -A lessen; git commit -q -m 'Lessen bijgewerkt' 2>$null; git push -q } finally { Pop-Location } }
}
finally {
    # Ontsleutelde context en verwerkte wachtrijen altijd opruimen
    Remove-Item (Join-Path $Map 'context.json'), (Join-Path $Map 'wachtrijen.json') -ErrorAction SilentlyContinue
}
