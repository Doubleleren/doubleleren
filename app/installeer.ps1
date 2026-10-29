# Installeert de Windows-pop-up van DoubleLeren op deze laptop (optioneel: aanmelden kan ook gewoon op de website).
# Met venster (standaard) of stil voor tests:
#   installeer.ps1 -Stil -Uitnodiging lid-xxxxxx:<token> -Naam Alfa -Xlsx C:\...\skilllijst.xlsx [-Thuis map] [-AppMap map] [-DataMap map]
#   installeer.ps1 -Stil -Uitnodiging lid-xxxxxx:<token> -Code "zes woorden"      (al aangemeld: alleen de pop-up op deze laptop)
#   installeer.ps1 -Stil -Uitnodiging lid-xxxxxx:<token> -Herstel -Naam Alfa      (code kwijt: nieuwe sleutel, scores blijven)
param(
    [switch]$Stil, [string]$Uitnodiging, [string]$Naam, [string]$Xlsx, [string]$Code, [switch]$Herstel, [switch]$GeenLessen,
    [string]$Thuis, [string]$AppMap, [string]$DataMap, [switch]$GeenTaak
)
$ErrorActionPreference = 'Stop'
$App = Split-Path $PSScriptRoot -Parent
foreach ($l in 'krypto', 'opslag', 'lid', 'geheim', 'client') { . (Join-Path $PSScriptRoot "lib\$l.ps1") }
# Excel-inleesscript is optioneel: sommige webfilters blokkeren het; de skilllijst kan ook via de website
$skilllijstScript = Join-Path $PSScriptRoot 'lib\skilllijst.ps1'
if (Test-Path $skilllijstScript) { . $skilllijstScript }
$inst = Get-Content (Join-Path $App 'instellingen.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Thuis) { $Thuis = Get-DlThuis }

function Split-Uitnodiging([string]$U) {
    $U = $U.Trim()
    if ($U -notmatch '^(lid-[0-9a-f]{6}):([A-Za-z0-9_]{20,255})$') { throw 'De uitnodigingscode klopt niet. Hij begint met lid- en bevat een dubbele punt.' }
    @{ id = $Matches[1]; token = $Matches[2] }
}
function Get-Opslagen($u) {
    $app = if ($AppMap) { New-DlOpslag -Map $AppMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.appRepo -Raw }
    $data = if ($DataMap) { New-DlOpslag -Map $DataMap } else { New-DlOpslag -Eigenaar $inst.eigenaar -Repo $inst.dataRepo -Token $u.token }
    $v = Read-DlJson $app 'vertrouwd.json'
    if (-not $v -or -not $v.beheer) { throw 'De beheerder heeft DoubleLeren nog niet ingericht (geen vertrouwd.json).' }
    @{ app = $app; data = $data; vertrouwd = $v.beheer }
}
function Save-Lokaal($u, $o, $prive, [bool]$lessen = $true) {
    $cfg = [ordered]@{ v = 2; id = $u.id; eigenaar = $inst.eigenaar; appRepo = $inst.appRepo; dataRepo = $inst.dataRepo; lessen = $lessen; vertrouwd = $o.vertrouwd }
    if ($AppMap) { $cfg.appMap = (Resolve-Path $AppMap).Path }
    if ($DataMap) { $cfg.dataMap = (Resolve-Path $DataMap).Path }
    Save-DlClient $Thuis $cfg $u.id $prive $u.token
}

function Get-Leren($u) {
    $o = Get-Opslagen $u
    $org = Read-DlBeheer $o.data 'organisatie.json' $o.vertrouwd
    # Het organogram bestaat altijd; ontbreekt het, dan geeft GitHub 'niet gevonden' omdat de token geen toegang heeft
    if (-not $org) { throw 'Deze uitnodigingscode heeft geen toegang tot de gegevens. Gebruik je de nieuwste token? Die moet als Resource owner "Doubleleren" hebben en toegang tot doubleleren-data (Contents: Read and write). Anders: vraag de beheerder om een nieuwe.' }
    if (-not $org.leden.($u.id)) { throw 'Dit lidnummer is niet bekend. Controleer het deel vóór de dubbele punt (lid-......) of vraag de beheerder.' }
    if ($org.leden.($u.id).leren -eq 'optioneel') { 'optioneel' } else { 'verplicht' }
}

# Skilllijst importeren en versleuteld + ondertekend opslaan
function Save-Skilllijst($o, $u, $s, $prive, [string]$xlsx) {
    if (-not (Get-Command Import-DlSkilllijst -ErrorAction SilentlyContinue)) { throw 'Excel inlezen kan hier niet (geblokkeerd door een webfilter). Meld je aan via de website; daarna kun je hier de pop-up toevoegen.' }
    $import = Import-DlSkilllijst -Xlsx $xlsx -Sjabloon (Join-Path $App "sjablonen\$($inst.vakgebied)\skilllijst.csv")
    $b = Read-DlOpslag $o.data (Get-DlLidPad $u.id 'matrix')
    Write-DlVersleuteld $o.data $u.id 'matrix' $s $import.matrix $(if ($b) { $b.sha }) $u.id $prive | Out-Null
    "$($import.gekoppeld) van $($import.totaal)"
}

# --- Kern: nieuw account -----------------------------------------------------
function Install-Nieuw($u, [string]$naam, [string]$xlsx, [switch]$herstel, [bool]$lessen = $true) {
    $o = Get-Opslagen $u
    $leren = Get-Leren $u
    if ($leren -eq 'verplicht') { $lessen = $true }
    $bestaand = Read-DlBeheer $o.data "sleutels/$($u.id).json" $o.vertrouwd
    if ($bestaand -and -not $herstel) { throw 'Je bent al aangemeld. Kies "Nieuwe laptop" (met je code) of "Code kwijt".' }
    if ($herstel -and -not $bestaand) { throw 'Er is nog niets te herstellen: kies "Ik begin voor het eerst".' }

    $kp = New-DlSleutelpaar 3072
    if (-not (Test-DlSleutelVorm $kp.publiek)) { $kp = New-DlSleutelpaar 3072 }
    $code = New-DlCode
    $kluis = Lock-DlKluis $u.id $kp.prive $code
    $aanvraag = [ordered]@{ v = 1; id = $u.id; publiek = $kp.publiek; kluis = $kluis; aangevraagd = (Get-Date).ToString('s') }
    $gekoppeld = $null

    if ($herstel) {
        $aanvraag.herstel = $true
        $p = Read-DlOpslag $o.data "data/$($u.id)/prive.enc"; if ($p) { Remove-DlOpslag $o.data "data/$($u.id)/prive.enc" $p.sha }
    } else {
        $dk = Get-DlWillekeurig 32; $s = Get-DlSleutelsUitDk $dk
        if (-not $xlsx -and $leren -eq 'verplicht') { throw 'Kies je ingevulde skilllijst (Excel).' }
        $bp = Read-DlOpslag $o.data (Get-DlLidPad $u.id 'profiel')
        Write-DlVersleuteld $o.data $u.id 'profiel' $s ([ordered]@{ v = 1; naam = $naam; sinds = (Get-Date).ToString('yyyy-MM-dd'); lessen = $lessen }) $(if ($bp) { $bp.sha }) $u.id $kp.prive | Out-Null
        if ($xlsx) { $gekoppeld = Save-Skilllijst $o $u $s $kp.prive $xlsx }
        $gen = Get-DlGeneratorPubliek $o.data $o.vertrouwd; if (-not $gen) { $gen = $o.vertrouwd }     # vóór de aparte generatorsleutel: de beheersleutel
        $aanvraag.toegang = [ordered]@{ $u.id = (ConvertTo-B64u (Protect-DlRsa $kp.publiek $dk)); generator = (ConvertTo-B64u (Protect-DlRsa $gen $dk)) }
    }
    $oud = Read-DlOpslag $o.data "aanvragen/$($u.id).json"
    Write-DlJson $o.data "aanvragen/$($u.id).json" $aanvraag $(if ($oud) { $oud.sha }) | Out-Null
    Save-Lokaal $u $o $kp.prive $lessen
    [pscustomobject]@{ id = $u.id; code = $code; controlewoorden = (Get-DlControlewoorden $aanvraag); gekoppeld = $gekoppeld; lessen = $lessen }
}

# --- Kern: al aangemeld (bijv. via de website): alleen deze laptop koppelen --------
function Install-Bestaand($u, [string]$code, [string]$xlsx, $lessen = $null) {
    $o = Get-Opslagen $u
    $s = Read-DlBeheer $o.data "sleutels/$($u.id).json" $o.vertrouwd
    if (-not $s) { $s = Read-DlJson $o.data "aanvragen/$($u.id).json" }
    if (-not $s) { throw "Geen account gevonden voor $($u.id)." }
    try { $prive = Unlock-DlKluis $u.id $s.kluis (ConvertTo-DlCode $code) } catch { throw 'Deze code klopt niet. Let op de spelling, of kies "Code kwijt".' }
    if ($prive.n -ne $s.publiek.n) { throw 'De sleutel past niet bij dit account.' }
    $gekoppeld = $null
    try {
        $sl = Get-DlSleutelsUitDk (Get-DlDk $o.data $u.id $u.id $prive $o.vertrouwd)
        $pub = New-DlSleutelbron $o.data $o.vertrouwd $u.id $prive
        $pr = Read-DlVersleuteld $o.data $u.id 'profiel' $sl $pub
        if ($null -eq $lessen) { $lessen = -not ($pr -and $pr.obj.lessen -eq $false) }
        elseif ($pr) { $pr.obj | Add-Member -NotePropertyName lessen -NotePropertyValue ([bool]$lessen) -Force; Write-DlVersleuteld $o.data $u.id 'profiel' $sl $pr.obj $pr.sha $u.id $prive | Out-Null }
        if ($xlsx) { $gekoppeld = Save-Skilllijst $o $u $sl $prive $xlsx }
    } catch { if ($null -eq $lessen) { $lessen = $true } }
    Save-Lokaal $u $o $prive ([bool]$lessen)
    [pscustomobject]@{ id = $u.id; code = $null; controlewoorden = $null; gekoppeld = $gekoppeld; lessen = [bool]$lessen }
}

function Register-DlTaak {
    $taakNaam = 'DoubleLeren'
    $script = Join-Path $PSScriptRoot 'dagelijkse-les.ps1'
    $gebruiker = "$env:USERDOMAIN\$env:USERNAME"
    $actie = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$script`""
    $bijInloggen = New-ScheduledTaskTrigger -AtLogOn -User $gebruiker
    $bijOntgrendelen = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger |
        New-CimInstance -ClientOnly -Property @{ StateChange = 8; UserId = $gebruiker; Enabled = $true }
    $elkHalfUur = New-ScheduledTaskTrigger -Daily -At '07:00'
    $elkHalfUur.Repetition = (New-ScheduledTaskTrigger -Once -At '07:00' -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Hours 16)).Repetition
    $inst2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taakNaam -Action $actie -Trigger @($bijInloggen, $bijOntgrendelen, $elkHalfUur) -Settings $inst2 `
        -Principal (New-ScheduledTaskPrincipal -UserId $gebruiker -LogonType Interactive -RunLevel Limited) -Description 'Dagelijkse SEO-les van DoubleLeren' -Force | Out-Null
    # Snelkoppeling naar de website
    $url = "https://$($inst.eigenaar).github.io/$($inst.appRepo)/"
    foreach ($map in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        [IO.File]::WriteAllText((Join-Path $map 'DoubleLeren.url'), "[InternetShortcut]`r`nURL=$url`r`n")
    }
}

# --- Stil (tests en beheer) ---------------------------------------------------------
if ($Stil) {
    $u = Split-Uitnodiging $Uitnodiging
    $r = if ($Code) { Install-Bestaand $u $Code $Xlsx $(if ($GeenLessen) { $false } else { $null }) } else { Install-Nieuw $u $Naam $Xlsx -herstel:$Herstel -lessen:(-not $GeenLessen) }
    if (-not $GeenTaak) { Register-DlTaak }
    $r | ConvertTo-Json -Compress
    return
}

# --- Venster ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DoubleLeren installeren" Width="620" SizeToContent="Height" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        FontFamily="Segoe UI" Background="#F8F6FD">
  <Border Margin="20" Background="White" CornerRadius="12" Padding="28,24">
    <StackPanel>
      <TextBlock FontSize="26" FontWeight="Bold" Foreground="#000"><Run Text="double"/><Run Text="leren" FontWeight="Normal"/></TextBlock>
      <TextBlock x:Name="Stap" Foreground="#5c5c5c" FontSize="13" Margin="0,2,0,16"/>

      <StackPanel x:Name="P1">
        <TextBlock TextWrapping="Wrap" FontSize="15" Margin="0,0,0,12">De pop-up zet elke werkdag je les op je scherm en gaat pas weg als je hem hebt gedaan. Plak hieronder de uitnodigingscode die je via Teams kreeg.</TextBlock>
        <TextBox x:Name="Uitn" FontSize="14" Padding="8"/>
        <TextBlock FontSize="13" Foreground="#5c5c5c" Margin="0,14,0,4">Wat wil je doen?</TextBlock>
        <RadioButton x:Name="KLaptop" IsChecked="True" Margin="0,4" FontSize="14">Ik heb al een account (code van zes woorden): pop-up op deze laptop</RadioButton>
        <RadioButton x:Name="KNieuw" Margin="0,4" FontSize="14">Ik begin voor het eerst (kan ook op de website)</RadioButton>
        <RadioButton x:Name="KKwijt" Margin="0,4" FontSize="14">Ik ben mijn code kwijt</RadioButton>
      </StackPanel>

      <StackPanel x:Name="P2" Visibility="Collapsed">
        <TextBlock FontSize="13" Foreground="#5c5c5c">Je voornaam (zichtbaar voor jou en je leidinggevenden)</TextBlock>
        <TextBox x:Name="Naam" FontSize="14" Padding="8" Margin="0,4,0,14"/>
        <CheckBox x:Name="Lessen" FontSize="14" Margin="0,0,0,12" Visibility="Collapsed" IsChecked="False">Ik wil ook de dagelijkse lessen (vrijblijvend: een les overslaan kan altijd)</CheckBox>
        <StackPanel x:Name="XlsxRij">
          <TextBlock x:Name="XlsxLabel" FontSize="13" Foreground="#5c5c5c">Je ingevulde skilllijst (Excel)</TextBlock>
          <DockPanel Margin="0,4,0,0">
            <Button x:Name="Kies" DockPanel.Dock="Right" Padding="14,6" Margin="8,0,0,0">Kies bestand</Button>
            <TextBox x:Name="Xlsx" FontSize="13" Padding="8" IsReadOnly="True"/>
          </DockPanel>
        </StackPanel>
      </StackPanel>

      <StackPanel x:Name="P2b" Visibility="Collapsed">
        <TextBlock FontSize="13" Foreground="#5c5c5c">Je code van zes woorden</TextBlock>
        <TextBox x:Name="Code" FontSize="16" Padding="8" Margin="0,4,0,12"/>
        <CheckBox x:Name="Lessen2" FontSize="14" Margin="0,0,0,10" Visibility="Collapsed">Ik wil (ook) de dagelijkse lessen</CheckBox>
        <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="#5c5c5c">Je skilllijst en voortgang staan al in je account; die hoef je hier niet opnieuw te kiezen.</TextBlock>
      </StackPanel>

      <StackPanel x:Name="P3" Visibility="Collapsed">
        <TextBlock TextWrapping="Wrap" FontSize="15">Dit is je persoonlijke code. Bewaar hem in je wachtwoordkluis: je hebt hem nodig om in te loggen op de website en op een nieuwe laptop. Niemand anders heeft hem, ook de beheerder niet.</TextBlock>
        <Border Background="#CEFF69" CornerRadius="10" Padding="16,12" Margin="0,14">
          <DockPanel>
            <Button x:Name="Kopieer" DockPanel.Dock="Right" Padding="12,4" VerticalAlignment="Center">Kopiëren</Button>
            <TextBox x:Name="CodeToon" FontSize="20" FontWeight="SemiBold" Background="Transparent" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap"/>
          </DockPanel>
        </Border>
        <CheckBox x:Name="Bewaard" FontSize="14">Ik heb mijn code veilig bewaard</CheckBox>
        <StackPanel x:Name="ControleRij">
          <TextBlock TextWrapping="Wrap" FontSize="15" Margin="0,18,0,6">Stuur deze zes controlewoorden via Teams naar je beheerder. Omdat je een nieuwe code aanvraagt, wordt zo gecontroleerd dat het echt jouw aanvraag is:</TextBlock>
          <Border Background="#E2EDF6" CornerRadius="10" Padding="16,10"><TextBlock x:Name="Controle" FontSize="18" FontWeight="SemiBold"/></Border>
        </StackPanel>
        <TextBlock x:Name="Info" TextWrapping="Wrap" FontSize="13" Foreground="#5c5c5c" Margin="0,12,0,0"/>
      </StackPanel>

      <TextBlock x:Name="Fout" TextWrapping="Wrap" Foreground="#B42318" FontSize="13" Margin="0,12,0,0"/>
      <DockPanel Margin="0,18,0,0">
        <TextBlock x:Name="Bezig" Foreground="#5c5c5c" VerticalAlignment="Center"/>
        <Button x:Name="Volgende" HorizontalAlignment="Right" Padding="20,8" Background="#000" Foreground="#fff" FontSize="14">Volgende</Button>
      </DockPanel>
    </StackPanel>
  </Border>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$e = @{}; foreach ($n in 'Stap', 'P1', 'P2', 'P2b', 'P3', 'Uitn', 'KNieuw', 'KLaptop', 'KKwijt', 'Naam', 'XlsxRij', 'Lessen', 'XlsxLabel', 'Lessen2', 'Kies', 'Xlsx', 'Code', 'CodeToon', 'Kopieer', 'Bewaard', 'Controle', 'ControleRij', 'Info', 'Fout', 'Bezig', 'Volgende') { $e[$n] = $win.FindName($n) }
$script:fase = 1; $script:u = $null
$e.Stap.Text = 'Stap 1 van 3'
function Toon([string]$p) { foreach ($x in 'P1', 'P2', 'P2b', 'P3') { $e[$x].Visibility = $(if ($x -eq $p) { 'Visible' } else { 'Collapsed' }) } }
function Werk([string]$tekst) { $e.Bezig.Text = $tekst; $e.Volgende.IsEnabled = $false; $win.Dispatcher.Invoke([Action] {}, 'Render') }
function Klaar { $e.Bezig.Text = ''; $e.Volgende.IsEnabled = $true }

$e.Kies.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'Excel (*.xlsx)|*.xlsx'
    if ($d.ShowDialog()) { $e.Xlsx.Text = $d.FileName }
})
$e.Kopieer.Add_Click({ try { [Windows.Clipboard]::SetText($e.CodeToon.Text) } catch {} })
$e.Bewaard.Add_Checked({ $e.Volgende.IsEnabled = $true }); $e.Bewaard.Add_Unchecked({ $e.Volgende.IsEnabled = $false })

$e.Volgende.Add_Click({
    $e.Fout.Text = ''
    try {
        switch ($script:fase) {
            1 {
                $script:u = Split-Uitnodiging $e.Uitn.Text
                $script:leren = Get-Leren $script:u
                if ($e.KLaptop.IsChecked) { Toon 'P2b'; $script:fase = 21; if ($script:leren -eq 'optioneel') { $e.Lessen2.Visibility = 'Visible' } }
                else {
                    Toon 'P2'; $e.XlsxRij.Visibility = $(if ($e.KKwijt.IsChecked) { 'Collapsed' } else { 'Visible' }); $script:fase = 2
                    if ($script:leren -eq 'optioneel' -and -not $e.KKwijt.IsChecked) { $e.Lessen.Visibility = 'Visible'; $e.XlsxLabel.Text = 'Je skilllijst (Excel, optioneel: dan zie je ook je eigen voortgang)' }
                }
                $e.Stap.Text = 'Stap 2 van 3'
            }
            2 {
                if (-not $e.Naam.Text.Trim()) { throw 'Vul je voornaam in.' }
                if ($e.KNieuw.IsChecked -and $script:leren -ne 'optioneel' -and -not (Test-Path $e.Xlsx.Text)) { throw 'Kies je ingevulde skilllijst (Excel).' }
                Werk 'Je sleutels worden gemaakt en je skilllijst versleuteld opgeslagen. Dit duurt even…'
                $lessenKeuze = $(if ($script:leren -eq 'optioneel') { [bool]$e.Lessen.IsChecked } else { $true })
                $r = Install-Nieuw $script:u $e.Naam.Text.Trim() $(if ($e.Xlsx.Text -and (Test-Path $e.Xlsx.Text)) { $e.Xlsx.Text } else { '' }) -herstel:([bool]$e.KKwijt.IsChecked) -lessen:$lessenKeuze
                Register-DlTaak; Klaar
                $e.CodeToon.Text = $r.code; $e.Controle.Text = $r.controlewoorden
                $e.ControleRij.Visibility = $(if ($e.KKwijt.IsChecked) { 'Visible' } else { 'Collapsed' })
                $e.Info.Text = $(if ($r.gekoppeld) { "Skilllijst ingelezen: $($r.gekoppeld) vaardigheden. " } else { '' }) + $(if ($e.KKwijt.IsChecked) { 'Zodra je beheerder je nieuwe code heeft goedgekeurd, kun je weer inloggen.' } else { 'Je account wordt vanzelf geactiveerd, meestal binnen een paar minuten. Daarna kun je inloggen op de website.' }) + ' Je eerste les verschijnt de volgende werkdag.'
                Toon 'P3'; $e.Stap.Text = 'Stap 3 van 3'; $e.Volgende.Content = 'Afronden'; $e.Volgende.IsEnabled = $false; $script:fase = 3
            }
            21 {
                Werk 'Je code wordt gecontroleerd…'
                $r = Install-Bestaand $script:u $e.Code.Text '' $(if ($script:leren -eq 'optioneel') { [bool]$e.Lessen2.IsChecked } else { $null })
                Register-DlTaak; Klaar
                [void][Windows.MessageBox]::Show('Gelukt. De pop-up staat op deze laptop en verschijnt bij je volgende les.', 'DoubleLeren'); $win.Close()
            }
            3 { $win.Close() }
        }
    } catch { Klaar; $e.Fout.Text = "$($_.Exception.Message)" }
})
[void]$win.ShowDialog()
