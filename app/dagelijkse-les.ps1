# DoubleLeren (team): dagelijkse les. Gestart door Taakplanner (inloggen, ontgrendelen, elk half uur).
#   -Test          : niets opslaan, Esc sluit het venster
#   -LesBestand    : een specifieke les (JSON) tonen
#   -Snapshot map  : elke fase als PNG renderen en stoppen (voor controle)
#   -Opslaan       : met -Snapshot: de les ook echt afronden en opslaan (test van het opslaan)
#   -Thuis map     : andere map met config en geheim (tests)
param(
    [switch]$Test,
    [string]$LesBestand,
    [string]$Snapshot,
    [switch]$Opslaan,
    [int]$AutoSluit = 0,
    [string]$Thuis
)

$ErrorActionPreference = 'Stop'
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim', 'client') { . (Join-Path $PSScriptRoot "lib\$l.ps1") }
if (-not $Thuis) { $Thuis = Get-DlThuis }
$StatusPad = Join-Path $Thuis 'status.json'
$FoutPad   = Join-Path $Thuis 'fouten.log'
$WachtMap  = Join-Path $Thuis 'wachtend'
$Utf8      = New-Object System.Text.UTF8Encoding($false)

function Lees-Json($pad) { [IO.File]::ReadAllText($pad, [Text.Encoding]::UTF8) | ConvertFrom-Json }
function Schrijf-Tekst($pad, $tekst) { [IO.File]::WriteAllText($pad, $tekst, $Utf8) }
function Log-Fout($tekst) {
    try { [IO.File]::AppendAllText($FoutPad, ("{0}  {1}`r`n" -f (Get-Date).ToString('s'), $tekst), $Utf8) } catch {}
}
function Schrijf-Status($voltooid, $uDatum, $uTot) {
    Schrijf-Tekst $StatusPad ([pscustomobject]@{ laatstVoltooid = $voltooid; uitstelDatum = $uDatum; uitstelTot = $uTot } | ConvertTo-Json)
}
function Get-LogSoort([datetime]$D) { 'log-' + $D.ToString('yyyy-MM') }

# Resultaat versleuteld opslaan: zonder antwoord in het logboek, het antwoord apart in het privébestand
function Opslaan-Resultaat($C, $Regel, [string]$Antwoord) {
    $s = Get-DlEigenSleutels $C
    $soort = 'log-' + ([string]$Regel.datum).Substring(0, 7)
    $voegToe = {
        param($h)
        $lijst = @(); if ($h) { $lijst = @($h.regels) }
        if (-not ($lijst | Where-Object { $_.id -eq $Regel.id -and $_.datum -eq $Regel.datum })) { $lijst += [pscustomobject]$Regel }
        [ordered]@{ v = 1; regels = $lijst }
    }.GetNewClosure()
    Update-DlVersleuteld $C.data $C.id $soort $s $voegToe $C.id $C.prive $C.publiek | Out-Null
    if ($Antwoord) {
        # Antwoordensleutel komt uit je eigen privésleutel: niemand anders kan hem maken of vervangen
        $ak = Get-DlAk $C.prive
        $nieuw = [pscustomobject]@{ datum = $Regel.datum; id = $Regel.id; antwoord = $Antwoord }
        $voegAntwoord = {
            param($h)
            $l = @(); if ($h) { $l = @($h.antwoorden) }
            if (-not ($l | Where-Object { $_.id -eq $nieuw.id -and $_.datum -eq $nieuw.datum })) { $l += $nieuw }
            [ordered]@{ v = 1; antwoorden = $l }
        }.GetNewClosure()
        Update-DlVersleuteld $C.data $C.id 'prive' $ak $voegAntwoord $C.id $C.prive $C.publiek | Out-Null
    }
}

# Alleen gewone webadressen openen (geen file:, \\server\, ms-…: of andere schema's uit een gemanipuleerde les)
function Test-WebAdres([string]$U) {
    $uri = $null
    [Uri]::TryCreate($U, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and -not $uri.IsUnc -and $U.Length -le 500
}

try {
    New-Item -ItemType Directory $Thuis -Force | Out-Null

    # --- Moet de pop-up vandaag (nog) verschijnen? (lokaal, zonder iets te ontsleutelen) ---
    $vandaag = (Get-Date).ToString('yyyy-MM-dd')
    $status = if (Test-Path $StatusPad) { Lees-Json $StatusPad } else { [pscustomobject]@{ laatstVoltooid = ''; uitstelDatum = ''; uitstelTot = '' } }
    $script:uitstelGebruikt = ($status.uitstelDatum -eq $vandaag)
    if (-not $Test -and -not $Snapshot) {
        if ($status.laatstVoltooid -eq $vandaag) { exit }
        if ($script:uitstelGebruikt -and $status.uitstelTot -and (Get-Date) -lt [datetime]$status.uitstelTot) { exit }
    }

    $nieuweMutex = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\DoubleLerenTeam', [ref]$nieuweMutex)
    if (-not $nieuweMutex) { exit }

    $c = $null
    if (-not $LesBestand -or $Opslaan) {
        $c = Get-DlClient -Thuis $Thuis
        if (-not $c) { Log-Fout 'DoubleLeren is nog niet geïnstalleerd op deze laptop'; exit }
    }
    # Verplicht of vrijblijvend: live uit het organogram, zodat de beheerder het centraal kan omzetten
    $script:vrijblijvend = $false
    if ($c) {
        $leren = 'verplicht'
        try { $org = Read-DlBeheer $c.data 'organisatie.json' $c.vertrouwd; if ($org.leden.($c.id).leren -eq 'optioneel') { $leren = 'optioneel' } } catch {}
        if ($leren -eq 'optioneel') {
            if ($c.cfg.lessen -eq $false -and -not $Test -and -not $Snapshot) { exit }     # koos geen lessen
            $script:vrijblijvend = $true
        }
    }

    # Eerder niet verstuurde resultaten (bijv. offline) alsnog versturen
    if ($c -and (Test-Path $WachtMap)) {
        foreach ($f in Get-ChildItem $WachtMap -Filter *.dpapi | Sort-Object Name) {
            try { $w = Read-DlGeheim $f.FullName; Opslaan-Resultaat $c $w.regel $w.antwoord; Remove-Item $f.FullName }
            catch { Log-Fout "Wachtend resultaat nog niet verstuurd: $($_.Exception.Message)" }
        }
    }

    # --- Logboek van deze en vorige maand: gedaan vandaag, reeks, al gemaakte lessen ---
    $logs = @()
    if ($c) {
        try {
            $s = Get-DlEigenSleutels $c
            foreach ($m in @((Get-Date), (Get-Date).AddMonths(-1))) {
                $r = Read-DlVersleuteld $c.data $c.id (Get-LogSoort $m) $s $c.publiek
                if ($r) { $logs += @($r.obj.regels) }
            }
        } catch {
            Log-Fout "Logboek lezen mislukt (offline of nog niet goedgekeurd?): $($_.Exception.Message)"
            if (-not $Test -and -not $Snapshot) { exit }
        }
    }
    if (-not $Test -and -not $Snapshot -and ($logs | Where-Object { "$($_.datum)".StartsWith($vandaag) })) {
        Schrijf-Status $vandaag $status.uitstelDatum $status.uitstelTot; exit     # al gedaan op een andere laptop
    }

    # --- Les kiezen: eerste uit je wachtrij die je nog niet deed, anders uit de gedeelde lessenpool ---
    if ($LesBestand) { $les = Lees-Json (Resolve-Path $LesBestand).Path }
    else {
        # Een les komt nooit twee keer: ook oudere maanden van het logboek meetellen
        $gedaan = @($logs | ForEach-Object { $_.id })
        $geladen = @((Get-LogSoort (Get-Date)), (Get-LogSoort (Get-Date).AddMonths(-1)))
        foreach ($b in @(Get-DlOpslagLijst $c.data "data/$($c.id)" | Where-Object { $_ -match '^log-\d{4}-\d{2}\.enc$' })) {
            $soort = $b -replace '\.enc$', ''
            if ($geladen -contains $soort) { continue }
            try { $r = Read-DlVersleuteld $c.data $c.id $soort $s $c.publiek; if ($r) { $gedaan += @($r.obj.regels | ForEach-Object { $_.id }) } } catch {}
        }
        $w = Read-DlVersleuteld $c.data $c.id 'wachtrij' $s $c.publiek
        $lesId = @($(if ($w) { @($w.obj.lessen) }) | Where-Object { $_ -and $gedaan -notcontains $_ }) | Select-Object -First 1
        if (-not $lesId) {
            $idx = Read-DlJson $c.app 'lessen/index.json'
            if ($idx) { $lesId = @($idx.lessen | Where-Object { $gedaan -notcontains $_.id }) | Select-Object -First 1 -ExpandProperty id }
        }
        if (-not $lesId) { Log-Fout 'Geen les beschikbaar: wachtrij en lessenpool zijn op. De generator vult ze aan.'; exit }
        $les = Read-DlJson $c.app "lessen/$lesId.json"
        if (-not $les) { Log-Fout "Les $lesId staat niet in de lessenpool"; exit }
    }
    $o = $les.opdracht

    # --- Reeks (weekenden onderbreken niet) en aantal deze maand ---
    $dagen = @($logs | ForEach-Object { "$($_.datum)".Substring(0, 10) } | Sort-Object -Unique)
    $reeks = 0; $d = (Get-Date).Date.AddDays(-1)
    while ($true) {
        if ($dagen -contains $d.ToString('yyyy-MM-dd')) { $reeks++ }
        elseif ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { break }
        $d = $d.AddDays(-1)
        if ($reeks -gt 3650) { break }
    }
    $dezeMaand = @($logs | Where-Object { "$($_.datum)".StartsWith((Get-Date).ToString('yyyy-MM')) }).Count

    # --- UI ------------------------------------------------------------------
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dagelijkse les" WindowStyle="None" AllowsTransparency="True"
        Background="#E60B1220" WindowState="Maximized" Topmost="True"
        ShowInTaskbar="True" FontFamily="Segoe UI" ResizeMode="NoResize">
  <Grid>
    <Border x:Name="Kaart" Background="#FFFFFF" CornerRadius="14" MaxWidth="780" Margin="24,32"
            VerticalAlignment="Center" Padding="38,30">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,16">
          <StackPanel Orientation="Horizontal">
            <Border Background="#EEF2FF" CornerRadius="10" Padding="10,3">
              <TextBlock x:Name="Badge" Foreground="#4338CA" FontSize="12" FontWeight="SemiBold"/>
            </Border>
            <TextBlock x:Name="Reeks" Foreground="#64748B" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="Titel" FontSize="24" FontWeight="SemiBold" Foreground="#0F172A" TextWrapping="Wrap" Margin="0,12,0,0"/>
        </StackPanel>
        <Grid DockPanel.Dock="Bottom" Margin="0,20,0,0">
          <StackPanel x:Name="LinksKnoppen" Orientation="Horizontal" HorizontalAlignment="Left"/>
          <StackPanel x:Name="Knoppen" Orientation="Horizontal" HorizontalAlignment="Right"/>
        </Grid>
        <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="Inhoud" Margin="0,0,10,0"/>
        </ScrollViewer>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@
    $win          = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $kaart        = $win.FindName('Kaart')
    $inhoud       = $win.FindName('Inhoud')
    $knoppen      = $win.FindName('Knoppen')
    $linksKnoppen = $win.FindName('LinksKnoppen')
    $scroll       = $win.FindName('Scroll')
    $scroll.MaxHeight = [Windows.SystemParameters]::PrimaryScreenHeight - 330

    $typeNaam = @{ basis = 'Basis'; verdieping = 'Verdieping'; herhaling = 'Herhaling'; nieuws = 'Nieuws' }[[string]$les.type]
    if (-not $typeNaam) { $typeNaam = $les.type }
    $win.FindName('Badge').Text = ('{0}  ·  {1}' -f $les.vakgebied, $typeNaam)
    $win.FindName('Reeks').Text = ('Reeks: {0} {1}  ·  deze maand {2} {3}' -f $reeks, $(if ($reeks -eq 1) { 'dag' } else { 'dagen' }), $dezeMaand, $(if ($dezeMaand -eq 1) { 'les' } else { 'lessen' }))
    $win.FindName('Titel').Text = $les.titel

    function Kleur($hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }
    function Rand($l, $t, $r, $b) { New-Object Windows.Thickness($l, $t, $r, $b) }

    function Nieuw-Alinea([string]$tekst, [double]$grootte = 15, [string]$kleur = '#1E293B') {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.TextWrapping = 'Wrap'; $tb.FontSize = $grootte; $tb.LineHeight = [math]::Round($grootte * 1.5)
        $tb.Margin = Rand 0 0 0 10; $tb.Foreground = Kleur $kleur
        $tekst = [regex]::Replace($tekst, '(?m)^- ', [string][char]0x2022 + '  ')
        foreach ($deel in [regex]::Split($tekst, '(\*\*[^*]+\*\*|\*[^*\s][^*]*\*)')) {
            if ($deel -eq '') { continue }
            $run = New-Object Windows.Documents.Run
            if ($deel -match '^\*\*(.+)\*\*$') { $run.Text = $Matches[1]; $run.FontWeight = [Windows.FontWeights]::SemiBold }
            elseif ($deel -match '^\*([^*]+)\*$') { $run.Text = $Matches[1]; $run.FontStyle = [Windows.FontStyles]::Italic }
            else { $run.Text = $deel }
            $tb.Inlines.Add($run)
        }
        $tb
    }
    function Toon-Tekst([string]$tekst, [double]$grootte = 15, [string]$kleur = '#1E293B') {
        if (-not $tekst) { return }
        foreach ($p in ($tekst -split "(?:\r?\n){2,}")) {
            if ($p.Trim()) { [void]$inhoud.Children.Add((Nieuw-Alinea $p.Trim() $grootte $kleur)) }
        }
    }
    function Toon-Label([string]$tekst) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = $tekst.ToUpper(); $tb.FontSize = 11; $tb.FontWeight = [Windows.FontWeights]::Bold
        $tb.Foreground = Kleur '#6366F1'; $tb.Margin = Rand 0 14 0 6
        [void]$inhoud.Children.Add($tb)
    }
    function Toon-Kader([string]$tekst, [string]$achtergrond, [string]$rand, [string]$label = '') {
        $b = New-Object Windows.Controls.Border
        $b.Background = Kleur $achtergrond; $b.BorderBrush = Kleur $rand; $b.BorderThickness = Rand 3 0 0 0
        $b.CornerRadius = New-Object Windows.CornerRadius(6); $b.Padding = Rand 16 12 16 4; $b.Margin = Rand 0 6 0 12
        $sp = New-Object Windows.Controls.StackPanel
        if ($label) {
            $lb = New-Object Windows.Controls.TextBlock
            $lb.Text = $label.ToUpper(); $lb.FontSize = 11; $lb.FontWeight = [Windows.FontWeights]::Bold
            $lb.Foreground = Kleur '#475569'; $lb.Margin = Rand 0 0 0 6
            [void]$sp.Children.Add($lb)
        }
        foreach ($p in ($tekst -split "(?:\r?\n){2,}")) { if ($p.Trim()) { [void]$sp.Children.Add((Nieuw-Alinea $p.Trim() 15)) } }
        $b.Child = $sp
        [void]$inhoud.Children.Add($b)
    }
    function Nieuw-Knop([string]$tekst, [scriptblock]$actie, [switch]$Primair) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $tekst; $b.Padding = Rand 18 9 18 9; $b.Margin = Rand 8 0 0 0; $b.FontSize = 14
        $b.Cursor = [Windows.Input.Cursors]::Hand
        if ($Primair) { $b.Background = Kleur '#4F46E5'; $b.Foreground = Kleur '#FFFFFF'; $b.BorderBrush = Kleur '#4F46E5' }
        else { $b.Background = Kleur '#F1F5F9'; $b.Foreground = Kleur '#0F172A'; $b.BorderBrush = Kleur '#CBD5E1' }
        $b.Add_Click($actie)
        $b.Add_IsEnabledChanged({ $this.Opacity = $(if ($this.IsEnabled) { 1 } else { 0.4 }) })
        $b
    }
    function Leeg {
        $inhoud.Children.Clear(); $knoppen.Children.Clear(); $linksKnoppen.Children.Clear(); $scroll.ScrollToTop()
    }
    function Voeg-UitstelKnop {
        if ($script:vrijblijvend) {
            $k = Nieuw-Knop 'Vandaag overslaan' { if (-not $Test) { Schrijf-Status $vandaag $status.uitstelDatum $status.uitstelTot }; $script:magSluiten = $true; $win.Close() }
            $k.Margin = Rand 0 0 8 0
            [void]$linksKnoppen.Children.Add($k)
            return
        }
        if (-not $script:uitstelGebruikt) {
            $k = Nieuw-Knop 'Later (2 uur)' { Stel-Uit }
            $k.Margin = Rand 0 0 8 0
            [void]$linksKnoppen.Children.Add($k)
        }
    }
    function Voeg-WegKnop {
        $k = Nieuw-Knop 'Venster even weg' { $win.WindowState = 'Minimized' }
        $k.Margin = Rand 0 0 8 0; $k.ToolTip = 'Minimaliseert de les zodat je kunt opzoeken of met Claude kunt werken. Terug via de taakbalk.'
        [void]$linksKnoppen.Children.Add($k)
    }

    function Stel-Uit {
        if (-not $Test) { Schrijf-Status $vandaag ((Get-Date).AddHours(2).ToString('s')) }
        $script:magSluiten = $true; $win.Close()
    }

    # --- Fasen ---------------------------------------------------------------
    $script:uitlegGetoond = $false
    $script:keuze = -1
    $script:resultaat = ''
    $script:antwoord = ''
    $script:minTekens = if ($o.minTekens) { [int]$o.minTekens } else { 40 }

    function Fase-Uitleg {
        Leeg
        Toon-Label 'Uitleg'
        Toon-Tekst $les.intro
        Toon-Tekst $les.uitleg
        $script:uitlegGetoond = $true
        Voeg-UitstelKnop
        [void]$knoppen.Children.Add((Nieuw-Knop 'Naar de opdracht  ->' { Fase-Opdracht } -Primair))
    }

    function Fase-Opdracht {
        Leeg
        if (-not $script:uitlegGetoond -and $les.intro) { Toon-Tekst $les.intro 15 '#334155' }
        $label = @{ meerkeuze = 'Vraag'; open = 'Denk na'; 'zoek-op' = 'Zoek het op'; 'maak-met-claude' = 'Maak het met Claude' }[[string]$o.soort]
        Toon-Label $label
        Toon-Tekst $o.vraag 16 '#0F172A'
        if ($o.hint) { Toon-Tekst ('Tip: ' + $o.hint) 13 '#64748B' }
        Voeg-UitstelKnop

        if ($o.soort -eq 'meerkeuze') {
            $script:controleerKnop = Nieuw-Knop 'Controleer' { Fase-Afronding } -Primair
            $script:controleerKnop.IsEnabled = $false
            $i = 0
            foreach ($optie in $o.opties) {
                $rb = New-Object Windows.Controls.RadioButton
                $rb.GroupName = 'opties'; $rb.Tag = $i; $rb.Margin = Rand 0 6 0 6; $rb.VerticalContentAlignment = 'Top'
                $tb = New-Object Windows.Controls.TextBlock
                $tb.Text = $optie; $tb.TextWrapping = 'Wrap'; $tb.FontSize = 15; $tb.Margin = Rand 6 -2 0 0
                $rb.Content = $tb
                $rb.Add_Checked({ $script:keuze = [int]$this.Tag; $script:controleerKnop.IsEnabled = $true })
                [void]$inhoud.Children.Add($rb)
                $i++
            }
            [void]$knoppen.Children.Add($script:controleerKnop)
        }
        else {
            if ($o.soort -ne 'open') { Voeg-WegKnop }
            $script:invoer = New-Object Windows.Controls.TextBox
            $script:invoer.AcceptsReturn = $true; $script:invoer.TextWrapping = 'Wrap'; $script:invoer.MinHeight = 150
            $script:invoer.FontSize = 14; $script:invoer.Padding = Rand 8 8 8 8; $script:invoer.Margin = Rand 0 8 0 4
            $script:invoer.VerticalScrollBarVisibility = 'Auto'; $script:invoer.MaxHeight = 320
            $script:teller = New-Object Windows.Controls.TextBlock
            $script:teller.FontSize = 12; $script:teller.Foreground = Kleur '#64748B'
            $script:teller.Text = "0 / $($script:minTekens) tekens minimaal"
            $script:indienKnop = Nieuw-Knop 'Indienen' { $script:antwoord = $script:invoer.Text.Trim(); Fase-Afronding } -Primair
            $script:indienKnop.IsEnabled = $false
            $script:invoer.Add_TextChanged({
                $n = $script:invoer.Text.Trim().Length
                $script:teller.Text = "$n / $($script:minTekens) tekens minimaal"
                $script:indienKnop.IsEnabled = ($n -ge $script:minTekens)
            })
            [void]$inhoud.Children.Add($script:invoer)
            [void]$inhoud.Children.Add($script:teller)
            [void]$knoppen.Children.Add($script:indienKnop)
            $null = $script:invoer.Focus()
        }
    }

    function Fase-Afronding {
        Leeg
        if ($o.soort -eq 'meerkeuze') {
            $juist = [int]$o.juist
            $script:antwoord = [string]$o.opties[$script:keuze]
            if ($script:keuze -eq $juist) {
                $script:resultaat = 'goed'
                Toon-Kader ('**Goed!** ' + $o.opties[$juist]) '#F0FDF4' '#16A34A'
            } else {
                $script:resultaat = 'fout'
                Toon-Kader ("**Niet helemaal.** Jij koos: " + $script:antwoord + "`n`n**Juist is:** " + $o.opties[$juist]) '#FEF2F2' '#DC2626'
            }
        } else {
            Toon-Kader $script:antwoord '#F8FAFC' '#94A3B8' 'Jouw antwoord'
            if ($les.modelantwoord) { Toon-Kader $les.modelantwoord '#EEF2FF' '#6366F1' 'Zo zou een expert het doen' }
        }
        if ($les.toelichting) { Toon-Tekst $les.toelichting }
        if (-not $script:uitlegGetoond) { Toon-Label 'Uitleg'; Toon-Tekst $les.uitleg; $script:uitlegGetoond = $true }
        if ($les.kernpunt) { Toon-Kader $les.kernpunt '#FFFBEB' '#D97706' 'Onthoud' }
        if ($les.toepassing) { Toon-Kader $les.toepassing '#F0F9FF' '#0284C7' 'Probeer vandaag' }
        if ($les.bron -and $les.bron.url -and (Test-WebAdres $les.bron.url)) {
            $tb = New-Object Windows.Controls.TextBlock
            $tb.FontSize = 13; $tb.Margin = Rand 0 4 0 4; $tb.TextWrapping = 'Wrap'
            $tb.Inlines.Add('Bron: ')
            $h = New-Object Windows.Documents.Hyperlink
            $h.Inlines.Add($(if ($les.bron.titel) { $les.bron.titel } else { $les.bron.url }))
            $h.NavigateUri = [uri]$les.bron.url
            $h.Add_Click({ if (Test-WebAdres $this.NavigateUri.AbsoluteUri) { Start-Process $this.NavigateUri.AbsoluteUri; $win.WindowState = 'Minimized' } })
            $tb.Inlines.Add($h)
            [void]$inhoud.Children.Add($tb)
        }

        $script:afrondKnop = Nieuw-Knop 'Afronden' { Sla-Op } -Primair
        $script:afrondDashKnop = Nieuw-Knop 'Afronden en voortgang bekijken' { $script:openDashboard = $true; Sla-Op }
        $script:afrondDashKnop.Margin = Rand 0 0 0 0
        [void]$knoppen.Children.Add($script:afrondDashKnop)
        if ($o.soort -ne 'meerkeuze') {
            # Zelfbeoordeling bepaalt of het onderwerp later terugkomt
            $script:afrondKnop.IsEnabled = $false
            $script:afrondDashKnop.IsEnabled = $false
            Toon-Label 'Hoe ging het?'
            $rij = New-Object Windows.Controls.StackPanel
            $rij.Orientation = 'Horizontal'
            foreach ($s in @(@('goed', 'Wist ik goed'), @('deels', 'Deels'), @('fout', 'Wist ik niet'))) {
                $k = Nieuw-Knop $s[1] {
                    $script:resultaat = [string]$this.Tag
                    foreach ($c in $script:scoreKnoppen) { $c.Background = Kleur '#F1F5F9'; $c.Foreground = Kleur '#0F172A' }
                    $this.Background = Kleur '#0F172A'; $this.Foreground = Kleur '#FFFFFF'
                    $script:afrondKnop.IsEnabled = $true
                    $script:afrondDashKnop.IsEnabled = $true
                }
                $k.Tag = $s[0]; $k.Margin = Rand 0 0 8 0
                [void]$rij.Children.Add($k)
            }
            $script:scoreKnoppen = @($rij.Children)
            [void]$inhoud.Children.Add($rij)
        }
        [void]$knoppen.Children.Add($script:afrondKnop)
    }

    function Sla-Op {
        if (-not $Test) {
            $script:teBewaren = @{
                regel = [ordered]@{
                    datum = (Get-Date).ToString('s'); id = $les.id; resultaat = $script:resultaat; soort = $o.soort; niveau = $les.niveau
                    matrix = @($les.matrix | Where-Object { $_ }); vakgebied = $les.vakgebied; onderwerp = $les.onderwerp; titel = $les.titel; type = $les.type
                }
                antwoord = $(if ($o.soort -ne 'meerkeuze') { $script:antwoord } else { '' })
            }
            Schrijf-Status $vandaag $status.uitstelDatum $status.uitstelTot
        }
        $script:magSluiten = $true; $win.Close()
    }

    # Versleuteld opslaan; lukt dat niet (offline), dan beschermd bewaren en bij de volgende start opnieuw proberen
    function Synchroniseer {
        if (-not $script:teBewaren) { return }
        try { Opslaan-Resultaat $c $script:teBewaren.regel $script:teBewaren.antwoord }
        catch {
            Log-Fout "Opslaan mislukt, wordt later opnieuw geprobeerd: $($_.Exception.Message)"
            Save-DlGeheim (Join-Path $WachtMap ((Get-Date).ToString('yyyyMMdd-HHmmss') + '.dpapi')) ([pscustomobject]$script:teBewaren)
        }
    }

    # --- Snapshot-modus (controle zonder venster) ----------------------------
    if ($Snapshot) {
        if (-not (Test-Path $Snapshot)) { New-Item -ItemType Directory $Snapshot | Out-Null }
        $scroll.MaxHeight = [double]::PositiveInfinity
        $win.WindowState = 'Normal'; $win.Topmost = $false; $win.ShowActivated = $false
        $win.Left = -20000; $win.Top = 0; $win.Width = 856; $win.SizeToContent = 'Height'
        $win.Show()
        function Maak-Snapshot($naam) {
            $win.UpdateLayout()
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$kaart.ActualWidth, [int]$kaart.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($kaart)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create((Join-Path $Snapshot "$naam.png")); $enc.Save($fs); $fs.Close()
        }
        $kaart.Margin = Rand 0 0 0 0
        if ($les.volgorde -eq 'uitleg-eerst') { Fase-Uitleg; Maak-Snapshot '1-uitleg' }
        Fase-Opdracht; Maak-Snapshot '2-opdracht'
        if ($o.soort -eq 'meerkeuze') { $script:keuze = ([int]$o.juist + 1) % @($o.opties).Count }
        else { $script:antwoord = 'Voorbeeldantwoord van de gebruiker om de lay-out te testen.' }
        Fase-Afronding; Maak-Snapshot '3-afronding'
        if ($Opslaan) { if (-not $script:resultaat) { $script:resultaat = 'deels' }; Sla-Op; Synchroniseer }
        $script:magSluiten = $true; $win.Close()
        exit
    }

    # --- Starten -------------------------------------------------------------
    $script:magSluiten = $false
    $win.Add_Closing({ if (-not $script:magSluiten -and -not $script:vrijblijvend) { $_.Cancel = $true } })
    if ($script:vrijblijvend) { $win.Topmost = $false; $win.Add_KeyDown({ if ($_.Key -eq 'Escape') { $script:magSluiten = $true; $win.Close() } }) }
    $win.Add_KeyDown({ if ($Test -and $_.Key -eq 'Escape') { $script:magSluiten = $true; $win.Close() } })
    if ($AutoSluit -gt 0) {
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds($AutoSluit)
        $timer.Add_Tick({ $script:magSluiten = $true; $win.Close() })
        $timer.Start()
    }

    if ($les.volgorde -eq 'uitleg-eerst') { Fase-Uitleg } else { Fase-Opdracht }

    $app = New-Object Windows.Application
    $app.ShutdownMode = 'OnMainWindowClose'
    # Afmelden/afsluiten van Windows nooit blokkeren
    $app.Add_SessionEnding({ $script:magSluiten = $true })
    [void]$app.Run($win)
    Synchroniseer
    if ($script:openDashboard -and $c) { Start-Process "https://$($c.cfg.eigenaar).github.io/$($c.cfg.appRepo)/" }
}
catch {
    Log-Fout ("FOUT: " + $_.Exception.Message + " @ regel " + $_.InvocationInfo.ScriptLineNumber)
    exit 1
}
