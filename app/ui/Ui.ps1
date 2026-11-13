# WPF UI (D-006): STA main thread, background runspaces for checks, a 500 ms DispatcherTimer that only polls shared state.
# Event handlers are plain script blocks that call functions defined here (no GetNewClosure: it would hide script-scope functions).
# 2.6.0: collectors in a RunspacePool (#2), report save / history / duplicate check in background tasks (#3), stepper (#8),
#        edition flags instead of patched copies (#14, D-034), colours from XAML design tokens (#13, D-035).

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'UiLogic.ps1')
. (Join-Path $PSScriptRoot 'ManualTests.ps1')
. (Join-Path $PSScriptRoot 'Doki.ps1')

$global:WkUi = @{}
$global:WkBg = @()
$global:WkState = @{
    screen = 'ScreenHome'; checks = @{}; stress = @{}; queue = @(); currentKind = $null
    checksStarted = $null; temp = $null; reportPath = $null; reportInfo = $null
    dirty = $false; saving = $false; reportRev = 0; reached = @{ ScreenHome = $true }; expand = @{}
    login = @{ role = $null; id = $null; name = $null }   # role: staff | guest
}
# Status palette = design-token names (MainWindow.xaml C.*), not colours.
$global:WkPalette = @{
    green = @{ fill = 'C.Green.Fill'; border = 'C.Green.Border'; fg = 'C.Green.Fg'; icon = [string][char]0x2713 }
    amber = @{ fill = 'C.Amber.Fill'; border = 'C.Amber.Border'; fg = 'C.Amber.Fg'; icon = '!' }
    red   = @{ fill = 'C.Red.Fill'; border = 'C.Red.Border'; fg = 'C.Red.Fg'; icon = [string][char]0x2715 }
    grey  = @{ fill = 'C.Grey.Fill'; border = 'C.Grey.Border'; fg = 'C.Grey.Fg'; icon = [string][char]0x2013 }
    busy  = @{ fill = 'C.Surface'; border = 'C.Line'; fg = 'C.Busy.Fg'; icon = [string][char]0x2026 }
}
$global:WkBrushConv = New-Object System.Windows.Media.BrushConverter
$global:WkBrushCache = @{}

# 'C.Token' -> the XAML resource brush; '#RRGGBB' -> converted once. Always a cached, frozen brush.
function Get-WkBrush([string]$Key) {
    if ($global:WkBrushCache.ContainsKey($Key)) { return $global:WkBrushCache[$Key] }
    $b = $null
    if ($Key.StartsWith('#')) { $b = $global:WkBrushConv.ConvertFromString($Key) }
    elseif ($global:WkWindow) { $b = $global:WkWindow.TryFindResource($Key) }
    if (-not $b) { Write-WkLog ('unknown colour token: ' + $Key) 'WARN'; $b = [System.Windows.Media.Brushes]::Magenta }
    if (-not $b.IsFrozen) { $b = $b.Clone(); $b.Freeze() }
    $global:WkBrushCache[$Key] = $b
    return $b
}

function Invoke-WkUiSafe([scriptblock]$Body) {
    try { & $Body } catch { Write-WkLog ('ui error: ' + $_.Exception.ToString() + ' at ' + $_.InvocationInfo.PositionMessage) 'ERROR' }
}

function Set-WkVisible($El, [bool]$Visible) { if ($El) { if ($Visible) { $El.Visibility = 'Visible' } else { $El.Visibility = 'Collapsed' } } }

# ---------------- language ----------------

function Update-WkTagged($El) {
    if ($El -is [System.Windows.FrameworkElement] -and $El.Tag -is [string] -and $El.Tag) {
        $txt = T $El.Tag
        if ($El -is [System.Windows.Controls.TextBlock]) { $El.Text = $txt }
        elseif ($El -is [System.Windows.Controls.ContentControl]) { $El.Content = $txt }
    }
    foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($El)) {
        if ($c -is [System.Windows.DependencyObject]) { Update-WkTagged $c }
    }
}

function Set-WkUiLanguage([string]$Lang) {
    Set-WkLanguage $Lang
    $w = $global:WkWindow
    if (Test-WkRtl) { $w.FlowDirection = 'RightToLeft' } else { $w.FlowDirection = 'LeftToRight' }
    $w.Title = T 'app.title'
    Update-WkTagged $w
    Initialize-WkDurations
    Initialize-WkHistoryFilters
    Update-WkHistoryHeaders
    Update-WkDeviceLine
    Build-WkLoginCards
    Update-WkRoleLine
    Update-WkHomeButtons
    Build-WkDiskManual
    Build-WkManualPanel
    if ($global:WkState.screen -eq 'ScreenHistory') { Update-WkHistory }
    if ($global:WkState.screen -eq 'ScreenAbout') { Update-WkAbout }
    if ($global:WkState.follow) { Update-WkFollowUp }
    if ($global:WkState.checks.device) { Update-WkDeviceCard }
    Update-WkDeployCard
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) { Update-WkCard $k }
    foreach ($k in $global:WkStressKinds) { Update-WkStressRow $k }
    if ($global:WkState.screen -eq 'ScreenReport') { Update-WkReportScreen }
    Update-WkSaveButtons
    Update-WkStepper
    if ($global:WkUi.FinishRoot -and $global:WkFinWin) {
        Update-WkTagged $global:WkUi.FinishRoot
        if (Test-WkRtl) { $global:WkFinWin.FlowDirection = 'RightToLeft' } else { $global:WkFinWin.FlowDirection = 'LeftToRight' }
    }
    Update-WkJiraStatusUi
    Update-DokiLanguage
    # The greeting carries a translated name: rebuild it in the new language (bypass the rate limit / repeat guard once).
    if ($global:WkState.screen -eq 'ScreenHome' -and $global:DokiState.ready) { $global:DokiState.lastSig = $null; $global:DokiState.lastAt = [DateTime]::MinValue; Invoke-DokiLogin }
    Save-WkLast
}

function Format-WkReason($R) {
    $a = @()
    foreach ($x in @($R.args)) {
        if ($x -is [string] -and $global:WkStrings.ContainsKey($x)) { $a += (T $x) } else { $a += $x }
    }
    $t = T $R.key @a
    if ($R.subject) { $t = [string]$R.subject + ': ' + $t }
    return $t
}

# ---------------- screens ----------------

$global:WkScreens = @('ScreenHome', 'ScreenChecks', 'ScreenStress', 'ScreenManual', 'ScreenReport', 'ScreenHistory', 'ScreenAbout', 'ScreenSettings')

function Show-WkScreen([string]$Name) {
    if ($Name -eq 'ScreenAbout' -and $global:WkState.screen -ne 'ScreenAbout') { $global:WkState.prevScreen = $global:WkState.screen }
    foreach ($s in $global:WkScreens) { Set-WkVisible $global:WkUi[$s] ($s -eq $Name) }
    $global:WkState.screen = $Name
    $global:WkState.reached[$Name] = $true
    if ($Name -eq 'ScreenAbout') { Update-WkAbout }
    if ($Name -eq 'ScreenManual' -and $global:WkUi.ManualPanel.Children.Count -eq 0) { Build-WkManualPanel }
    if ($Name -eq 'ScreenManual') { Start-WkMicMeter } else { Stop-WkMicMeter }   # live mic level only while the checklist is open
    if ($Name -eq 'ScreenReport') { Update-WkReportScreen; Update-WkDeployCard; Update-WkSaveButtons }
    if ($Name -eq 'ScreenHistory') { Start-WkHistoryLoad }
    if ($Name -eq 'ScreenSettings') { Show-WkSettingsValues }
    Update-WkStepper
    Update-DokiForScreen $Name
}

# Generic two-button dialog (RTL aware). Returns 'primary' (default / Esc) or 'secondary'.
function Show-WkChoice([string]$Title, [string]$Message, [string]$Primary, [string]$Secondary) {
    $w = New-Object System.Windows.Window
    $w.Title = $Title; $w.Width = 520; $w.SizeToContent = 'Height'; $w.ResizeMode = 'NoResize'; $w.WindowStartupLocation = 'CenterOwner'
    $w.Owner = $global:WkWindow; $w.Background = Get-WkBrush 'C.Bg'; $w.FontFamily = 'Segoe UI, Tahoma'; $w.FontSize = 15
    if (Test-WkRtl) { $w.FlowDirection = 'RightToLeft' }
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '24'
    $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $Message; $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,0,0,18'; $tb.Foreground = Get-WkBrush 'C.Text'
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'
    $b1 = New-Object System.Windows.Controls.Button; $b1.Style = $global:WkWindow.FindResource('Primary'); $b1.Content = $Primary
    $b1.Height = 44; $b1.FontSize = 15; $b1.Padding = '20,0'; $b1.Margin = '0,0,10,0'; $b1.IsDefault = $true; $b1.IsCancel = $true; $b1.Name = 'ChoicePrimary'
    $b2 = New-Object System.Windows.Controls.Button; $b2.Style = $global:WkWindow.FindResource('Secondary'); $b2.Content = $Secondary
    $b2.Height = 44; $b2.FontSize = 15; $b2.Padding = '20,0'; $b2.Name = 'ChoiceSecondary'
    [void]$row.Children.Add($b1); [void]$row.Children.Add($b2)
    [void]$sp.Children.Add($tb); [void]$sp.Children.Add($row)
    $w.Content = $sp
    $global:WkChoice = 'primary'; $global:WkChoiceWin = $w
    $b1.Add_Click({ $global:WkChoice = 'primary'; $global:WkChoiceWin.Close() })
    $b2.Add_Click({ $global:WkChoice = 'secondary'; $global:WkChoiceWin.Close() })
    [void]$w.ShowDialog()
    return $global:WkChoice
}

# ---------------- stepper (2.6.0, #8) ----------------

$global:WkStepNames = @{ home = 'StepHome'; checks = 'StepChecks'; stress = 'StepStress'; manual = 'StepManual'; report = 'StepReport' }

function Update-WkStepper {
    $u = $global:WkUi
    if (-not $u.StepperBar) { return }
    $show = $global:WkState.screen -in @('ScreenChecks', 'ScreenStress', 'ScreenManual', 'ScreenReport')
    Set-WkVisible $u.StepperBar $show
    if (-not $show) { return }
    $steps = Get-WkStepStates @{
        checksStarted = $global:WkState.checksStarted; checks = $global:WkState.checks; verdict = (Get-WkCurrentVerdict)
        stress = $global:WkState.stress; manual = $global:WkState.checks.manual; rules = (Get-WkRules)
        reportSaved = [bool]$global:WkState.reportPath; dirty = [bool]$global:WkState.dirty; reached = $global:WkState.reached
    }
    $busy = [bool]$global:WkState.currentKind -or [bool]$global:WkState.saving   # never leave a running stress test / save from the bar
    $i = 0
    foreach ($s in $steps) {
        $i++
        $n = $global:WkStepNames[$s.id]
        $current = ($s.screen -eq $global:WkState.screen)
        $dotKey = 'C.Grey.Fill'; $numKey = 'C.Muted'; $num = [string]$i
        switch ($s.state) {
            'green' { $dotKey = 'C.Green.Fg'; $numKey = 'C.White'; $num = [string][char]0x2713 }
            'amber' { $dotKey = 'C.Amber.Fg'; $numKey = 'C.White'; $num = '!' }
            'red'   { $dotKey = 'C.Red.Fg'; $numKey = 'C.White'; $num = [string][char]0x2715 }
            'busy'  { $dotKey = 'C.Busy.Fg'; $numKey = 'C.White'; $num = [string][char]0x2026 }
        }
        if ($current -and $s.state -eq 'pending') { $dotKey = 'C.Accent'; $numKey = 'C.White' }
        $u[$n + 'Dot'].Background = Get-WkBrush $dotKey
        $u[$n + 'Num'].Foreground = Get-WkBrush $numKey
        $u[$n + 'Num'].Text = $num
        $u[$n + 'Sub'].Text = [string]$s.sub
        Set-WkVisible $u[$n + 'Sub'] ([bool]$s.sub)
        if ($current) { $u[$n].Background = Get-WkBrush 'C.Grey.Fill'; $u[$n].BorderBrush = Get-WkBrush 'C.Accent'; $u[$n + 'Text'].FontWeight = 'Bold' }
        else { $u[$n].Background = [System.Windows.Media.Brushes]::Transparent; $u[$n].BorderBrush = [System.Windows.Media.Brushes]::Transparent; $u[$n + 'Text'].FontWeight = 'SemiBold' }
        $u[$n].IsEnabled = ($current -or ($s.reachable -and -not $busy))
        $u[$n].DataContext = $s.screen
    }
}

# ---------------- Doki hooks (Phase 8) ----------------

function Invoke-DokiLogin {
    $l = $global:WkState.login
    $name = ''
    if ($l.role -eq 'staff') { $name = ([string](Get-WkStaffDisplayName $l.id)).Trim().Split(' ')[0] }   # first name is friendlier
    elseif ($l.role -eq 'guest') { $gn = $global:WkUi.TxtGuestName.Text.Trim(); if ($gn) { $name = $gn.Split(' ')[0].Split('@')[0] } }
    Invoke-DokiEvent 'login' @{ role = $l.role; name = $name; hour = (Get-Date).Hour; hasAsset = ($global:WkUi.TxtAsset.Text.Trim() -ne '') }
}

function Update-DokiForScreen([string]$Name) {
    if (-not $global:DokiState.ready) { return }
    if ($Name -eq 'ScreenHome') { Move-DokiTo 'home' } else { Move-DokiTo 'side' }
    # Screen entry is user navigation: speak now and drop lines queued on the previous screen.
    switch ($Name) {
        'ScreenHome'    { $global:DokiState.queue = @(); $global:DokiState.lastAt = [DateTime]::MinValue; Invoke-DokiLogin }
        'ScreenChecks'  { $global:DokiState.queue = @() }
        'ScreenStress'  { if (-not $global:WkState.currentKind) { Invoke-DokiEvent 'stressScreen' -Force } else { $global:DokiState.queue = @() } }
        'ScreenManual'  { Invoke-DokiEvent 'manual' -Force }
        'ScreenReport'  { $global:DokiState.queue = @() }
        'ScreenHistory' { Invoke-DokiEvent 'history' -Force }
        'ScreenAbout'   { Invoke-DokiEvent 'about' -Force }
    }
}

# Next deployment step from the deployment state (not from the buttons: Rename stays enabled after a rename).
function Invoke-DokiDeployStep {
    if (-not (Test-WkFeature 'deploy')) { return }
    $d = $global:WkState.deploy
    $t = Get-WkDeployTargetName
    $same = $t.valid -and ($env:COMPUTERNAME -eq $t.name.ToUpperInvariant())
    $renamed = ($d -and $d.renamedTo) -or $same
    $edrDone = ($d -and $d.edr -and $d.edr.state -eq 'done')
    $step = $null
    if (-not $t.valid) { $step = $null }
    elseif (-not $renamed) { $step = 'rename' }
    elseif (-not $edrDone) { $step = 'install' }
    else { $step = 'restart' }
    Invoke-DokiEvent 'deploy' @{ step = $step }
}

# ---------------- device facts card + live monitor (Phase 6) ----------------

function Update-WkDeviceCard {
    $p = $global:WkUi.DevDetails
    $p.Children.Clear()
    $res = $global:WkState.checks.device
    if (-not $res) { [void]$p.Children.Add((New-WkLine (T 'common.checking') 'C.Accent' 14)); return }
    if (-not $res.ok) { [void]$p.Children.Add((New-WkLine ((T 'common.couldNotCheck') + ': ' + [string]$res.error) 'C.Muted' 13)); return }
    foreach ($r in (Get-WkDeviceRows $res.data)) {
        $g = New-Object System.Windows.Controls.DockPanel
        $l = New-WkLine ([string]$r[0]) 'C.Muted' 14
        $l.Width = 190; [System.Windows.Controls.DockPanel]::SetDock($l, 'Left')
        $vv = New-WkLine ([string]$r[1]) 'C.Text' 14 $true
        [void]$g.Children.Add($l); [void]$g.Children.Add($vv)
        [void]$p.Children.Add($g)
    }
}

function Update-WkMonitorUi {
    $s = Get-WkMonitorSample
    $u = $global:WkUi
    $na = '-'
    if ($null -ne $s.cpu) { $u.MonCpuBar.Value = $s.cpu; $u.MonCpuText.Text = ([string]$s.cpu + '%') } else { $u.MonCpuText.Text = $na }
    if ($null -ne $s.ram) { $u.MonRamBar.Value = $s.ram; $u.MonRamText.Text = (T 'mon.ramValue' $s.ram $s.ramUsedGB $s.ramTotalGB) } else { $u.MonRamText.Text = $na }
    if ($null -ne $s.disk) { $u.MonDiskBar.Value = $s.disk; $u.MonDiskText.Text = ([string]$s.disk + '%') } else { $u.MonDiskText.Text = $na }
    foreach ($b in @($u.MonCpuBar, $u.MonRamBar, $u.MonDiskBar)) {
        $c = 'C.Brand'; if ($b.Value -ge 90) { $c = 'C.Red.Fg' } elseif ($b.Value -ge 70) { $c = 'C.Orange' }
        $b.Foreground = Get-WkBrush $c
    }
    $strip = 'CPU ' + $s.cpu + '%   |   RAM ' + $s.ram + '%   |   Disk ' + $s.disk + '%'
    if ($null -ne $global:WkState.temp) { $strip += '   |   ' + $global:WkState.temp + [char]0x00B0 + 'C' }
    $u.MonStrip.Text = $strip
}

# ---------------- deployment: rename -> EDR -> restart (org edition, Phase 6, D-025) ----------------

function Get-WkDeployTargetName {
    $prefix = [string]$global:WkUi.CmbPrefix.SelectedItem
    return (New-WkComputerName $prefix $global:WkUi.TxtAsset.Text.Trim())
}

function Add-WkDeployLog([string]$Text, [string]$Color = 'C.Text') {
    if (-not $global:WkState.deploy) { $global:WkState.deploy = @{ log = @() } }
    $global:WkState.deploy.log += ((Get-Date).ToString('HH:mm') + ' ' + $Text)
    $global:WkState.checks.deploy = $global:WkState.deploy
    [void]$global:WkUi.DepStatus.Children.Add((New-WkLine $Text $Color 14 $true))
    Set-WkDirty
}

function Update-WkDeployCard {
    $u = $global:WkUi
    # Device preparation only in the org edition and only after the report is saved (a restart before saving would lose it).
    if (-not (Test-WkFeature 'deploy') -or -not $global:WkState.reportPath) { $u.DeployCard.Visibility = 'Collapsed'; return }
    $u.DeployCard.Visibility = 'Visible'
    if (-not $global:WkState.deploy) { $global:WkState.deploy = @{ log = @() } }
    $d = $global:WkState.deploy
    Set-WkVisible $u.DepDryBox (Test-WkDeployDryRun)
    $t = Get-WkDeployTargetName
    $u.DepCurrent.Text = T 'dep.current' $env:COMPUTERNAME
    if (-not $t.valid) {
        if ($t.reason -eq 'noAsset') { $u.DepNewName.Text = T 'dep.needAsset' } elseif ($t.reason -eq 'tooLong') { $u.DepNewName.Text = T 'dep.tooLong' $t.name } else { $u.DepNewName.Text = T 'dep.invalid' $t.name }
        $u.DepNewName.Foreground = Get-WkBrush 'C.Red.Fg'
    } else { $u.DepNewName.Text = T 'dep.newName' $t.name; $u.DepNewName.Foreground = Get-WkBrush 'C.Green.Fg' }
    $same = $t.valid -and ($env:COMPUTERNAME -eq $t.name.ToUpperInvariant())
    $renamed = [bool]$d.renamedTo
    $busy = ($d.edr -and $d.edr.state -eq 'running')
    $u.BtnRename.IsEnabled = $t.valid -and -not $same -and -not $busy
    $u.BtnInstallEdr.IsEnabled = ($renamed -or $same) -and -not $busy -and -not ($d.edr -and $d.edr.state -eq 'done' -and -not $d.edr.dry)
    $u.BtnRestart.IsEnabled = -not $busy
    $u.CmbPrefix.IsEnabled = -not $renamed
}

function Invoke-WkRenameUi {
    $t = Get-WkDeployTargetName
    if (-not $t.valid) { return }
    $r = Invoke-WkRename $t.name
    $dry = ''; if ($r.dry) { $dry = T 'dep.dry' }
    if ($r.ok) { $global:WkState.deploy.renamedTo = $t.name; Add-WkDeployLog ((T 'dep.renamed' $t.name) + $dry) 'C.Green.Fg' }
    elseif ($r.error -eq 'needAdmin') { Add-WkDeployLog (T 'dep.needAdmin') 'C.Red.Fg' }
    else { Add-WkDeployLog (T 'dep.renameFail' $r.error) 'C.Red.Fg' }
    Update-WkDeployCard
    Invoke-DokiDeployStep
}

function Invoke-WkInstallEdrUi {
    if (-not (Test-WkDeployDryRun) -and (Test-WkEdrInstalled)) { Add-WkDeployLog (T 'dep.edrPresent') 'C.Green.Fg'; return }
    $s = Start-WkEdrInstall
    $global:WkState.deploy.edr = $s
    if ($s.state -eq 'failed') {
        if ($s.error -eq 'needAdmin') { Add-WkDeployLog (T 'dep.needAdmin') 'C.Red.Fg' }
        elseif ([string]$s.error -like 'noInstaller|*') { Add-WkDeployLog (T 'dep.noInstaller' ([string]$s.error).Substring(12)) 'C.Red.Fg' }
        else { Add-WkDeployLog (T 'dep.installFail' $s.error) 'C.Red.Fg' }
    } elseif ($s.state -eq 'running') { Add-WkDeployLog (T 'dep.installing') 'C.Accent' }
    elseif ($s.dry) { Add-WkDeployLog ((T 'dep.installed' 0) + (T 'dep.dry')) 'C.Green.Fg' }
    Update-WkDeployCard
    Invoke-DokiDeployStep
}

function Update-WkDeployPoll {
    $d = $global:WkState.deploy
    if (-not $d -or -not $d.edr -or $d.edr.state -ne 'running') { return }
    $s = Get-WkEdrInstallState $d.edr
    if ($s.state -eq 'done') {
        if ($s.installed) { Add-WkDeployLog ((T 'dep.installed' $s.exitCode) + ' - ' + (T 'dep.installedOk')) 'C.Green.Fg' }
        else { Add-WkDeployLog (T 'dep.installed' $s.exitCode) 'C.Amber.Fg' }
        Update-WkDeployCard
    }
}

function Invoke-WkRestartUi {
    $ans = [System.Windows.MessageBox]::Show((T 'dep.restartConfirm'), (T 'app.title'), 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $r = Invoke-WkRestart
    if ($r.dry) { Add-WkDeployLog ((T 'dep.restart') + (T 'dep.dry')) 'C.Green.Fg' } elseif (-not $r.ok) { Add-WkDeployLog ([string]$r.error) 'C.Red.Fg' }
}

# ---------------- background tasks (report save, history, Jira, updates; polled by the timer) ----------------
# Each task gets its own runspace that loads only the modules it needs (2.6.0, #2).

$global:WkTasks = @{}
$global:WkTaskScript = @'
param($mods, $app, $root, $lang, $what, $a1, $a2, $a3)
$global:WkApp = $app; $global:WkRoot = $root
foreach ($m in $mods) { . $m }
if (Get-Command Set-WkLanguage -ErrorAction SilentlyContinue) { Set-WkLanguage $lang }
try {
    switch ($what) {
        'jiraTest'       { Test-WkSupportConnection }
        'jiraSend'       { Send-WkSupportTicket $a1 }
        'updateCheck'    { Get-DokiLatestRelease }
        'updateDownload' { Save-DokiUpdate $a1 }
        'saveReport' {
            $p = $a1
            if (-not $p.Checks.system) { $p.Checks.system = Get-WkSystemInfo }
            $path = New-WkReport @p
            @{ ok = $true; path = $path; last = $global:WkLastReport; system = $p.Checks.system }
        }
        'historyRows'    { @{ ok = $true; rows = @(Get-WkReportIndexRows) } }
        'dupCheck'       { @{ ok = $true; hit = (Find-WkSameDayReport @(Get-WkReportIndexRows) $a1 $a2 $a3) } }
    }
} catch { @{ ok = $false; error = $_.Exception.Message } }
'@

function Start-WkTask([string]$Name, [string]$What, [object[]]$TaskArgs = @(), [object[]]$Modules = $null) {
    if ($global:WkTasks.ContainsKey($Name)) { return $false }
    if (-not $Modules) { $Modules = @($global:WkModules) }
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($global:WkTaskScript).AddArgument(@($Modules)).AddArgument($global:WkApp).AddArgument($global:WkRoot).AddArgument($global:WkLang).AddArgument($What)
    foreach ($a in @($TaskArgs + @($null, $null, $null))[0..2]) { [void]$ps.AddArgument($a) }
    $global:WkTasks[$Name] = @{ ps = $ps; h = $ps.BeginInvoke(); rs = $rs }
    return $true
}

function Update-WkTasksPoll {
    foreach ($name in @($global:WkTasks.Keys)) {
        $t = $global:WkTasks[$name]
        if (-not $t.h.IsCompleted) { continue }
        $out = $null
        try { $out = @($t.ps.EndInvoke($t.h)) | Select-Object -Last 1 } catch { $out = @{ ok = $false; error = $_.Exception.Message } }
        if (-not $out) { $out = @{ ok = $false; error = 'no result' } }
        try { $t.ps.Dispose(); $t.rs.Dispose() } catch { }
        $global:WkTasks.Remove($name)
        switch ($name) {
            'saveReport'  { Complete-WkSaveUi $out }
            'historyRows' { Complete-WkHistoryLoad $out }
            'dupCheck'    { Complete-WkDuplicate $out }
            'jiraTest' {
                if ($out.ok) { $global:WkUi.AboutJiraResult.Text = T 'jira.ok' $out.user; $global:WkUi.AboutJiraResult.Foreground = Get-WkBrush 'C.Green.Fg' }
                else { Write-WkLog ([string]$out.error) 'ERROR'; $global:WkUi.AboutJiraResult.Text = T 'jira.connectionFailed'; $global:WkUi.AboutJiraResult.Foreground = Get-WkBrush 'C.Red.Fg' }
                $global:WkUi.BtnJiraTest.IsEnabled = $true
            }
            'jiraSend'    { Complete-WkJiraSend $out }
            'updateCheck' {
                $global:WkUi.BtnUpdateCheck.IsEnabled = $true
                $global:DokiUpdateInfo = $out
                if ($out.ok -and $out.available) { $global:WkUi.AboutUpdateStatus.Text = T 'update.available' $out.version; $global:WkUi.BtnUpdateInstall.Visibility = 'Visible' }
                elseif ($out.ok) { $global:WkUi.AboutUpdateStatus.Text = T 'update.current'; $global:WkUi.BtnUpdateInstall.Visibility = 'Collapsed' }
                elseif ($out.status -eq 'disabled') { $global:WkUi.AboutUpdateStatus.Text = T 'update.disabled' }
                else { $global:WkUi.AboutUpdateStatus.Text = T 'update.unavailable' }
            }
            'updateDownload' {
                $global:WkUi.BtnUpdateInstall.IsEnabled = $true
                if ($out.ok) {
                    $global:WkUi.AboutUpdateStatus.Text = T 'update.ready' $out.version
                    $answer = [System.Windows.MessageBox]::Show((T 'update.confirm' $out.version), (T 'update.title'), 'YesNo', 'Question')
                    if ($answer -eq 'Yes') { Start-DokiUpdateInstall $out; $global:WkWindow.Close() }
                } else { $global:WkUi.AboutUpdateStatus.Text = T 'update.failed' $out.error }
            }
        }
    }
}

# ---------------- About (edition aware) ----------------

function Get-WkAboutLink([string]$Url) { return ([string]$Url -replace '^https?://', '') }

function Update-WkAbout {
    $u = $global:WkUi
    $b = $global:WkBuild
    $u.AboutVersion.Text = (T 'about.version') + ': ' + $global:WkVersion
    $date = [string]$b.buildDate
    if (-not $date) {
        $date = (Get-Item -LiteralPath (Join-Path $global:WkApp 'main.ps1')).LastWriteTime.ToString('yyyy-MM-dd') + ' - ' + (T 'about.dev')
    }
    $bt = (T 'about.buildDate') + ': ' + $date
    if ($b.commit) { $bt += '   |   ' + (T 'about.build') + ': ' + [string]$b.commit }
    $u.AboutBuild.Text = $bt
    $org = Get-WkOrg
    $gh = (Test-WkFeature 'github') -and $org -and $org.githubUrl
    $upd = Test-WkFeature 'updater'
    Set-WkVisible $u.AboutGitHubPanel $gh
    Set-WkVisible $u.AboutUpdatePanel $upd
    Set-WkVisible $u.AboutProjectCard ($gh -or $upd)
    if ($gh) { $u.BtnGitHub.Content = Get-WkAboutLink $org.githubUrl }
    if ($upd -and -not $u.AboutUpdateStatus.Text) { $u.AboutUpdateStatus.Text = T 'update.notChecked' }
    $contacts = (Test-WkFeature 'contacts') -and $org -and $org.contacts
    Set-WkVisible $u.AboutContactCard $contacts
    if ($contacts) { $u.AboutMailQc.Content = [string]$org.contacts.qcOwner; $u.AboutMailSupport.Content = [string]$org.contacts.support }
    $u.AboutConfig.Text = (Join-Path $global:WkRoot 'config')
    $roots = @()
    try {
        $p = (Get-WkRules).paths
        if (Test-WkFeature 'staffLogin') {
            $roots += ('Staff: ' + [Environment]::ExpandEnvironmentVariables([string]$p.staff_root))
            $roots += ('Guest: ' + [Environment]::ExpandEnvironmentVariables([string]$p.guest_root))
        } else { $roots += [Environment]::ExpandEnvironmentVariables([string]$p.guest_root) }
    } catch { }
    $u.AboutReports.Text = ($roots -join "`r`n")
    $u.AboutSoundsHint.Text = T 'about.soundsHint' (Get-WkSoundDir)
    $sp = $u.AboutSounds; $sp.Children.Clear()
    foreach ($n in $global:WkSoundNames) {
        if (Get-WkSoundFile $n) { [void]$sp.Children.Add((New-WkLine (T 'about.soundFound' $n) 'C.Green.Fg' 13)) }
        else { [void]$sp.Children.Add((New-WkLine (T 'about.soundMissing' $n) 'C.Muted' 13)) }
    }
    $jiraOn = Test-WkFeature 'jira'
    Set-WkVisible $u.AboutJiraCard $jiraOn
    if ($jiraOn) {
        $jt = Test-WkSupportConfig
        if (-not $jt.enabled) { $u.AboutJiraStatus.Text = T 'jira.disabled'; $u.BtnJiraTest.IsEnabled = $false }
        elseif (-not $jt.ok) { $u.AboutJiraStatus.Text = T 'jira.incomplete' ($jt.missing -join ', '); $u.BtnJiraTest.IsEnabled = $false }
        else { $c = Get-WkSupportConfig; $u.AboutJiraStatus.Text = T 'jira.enabled' $c.baseUrl $c.mode; $u.BtnJiraTest.IsEnabled = $true }
    }
}

# Same plain text as the HTML "Copy information" button.
function Get-WkCurrentReportText {
    $l = $global:WkState.login
    $who = ''; $role = 'staff'
    if ($l.role -eq 'guest') { $role = 'guest'; $who = $global:WkUi.TxtGuestName.Text.Trim() } else { $who = Get-WkStaffDisplayName $l.id }
    $path = ''; if ($global:WkState.reportPath) { $path = [string]$global:WkState.reportPath }
    $txt = Get-WkReportText $global:WkState.checks $global:WkState.stress (Get-WkCurrentVerdict) $who $global:WkUi.TxtAsset.Text.Trim() $role $global:WkUi.TxtNotes.Text $path
    if ($global:WkState.follow -and $global:WkState.follow.suspect) { $txt += "`r`n`r`n" + (T 'follow.reportLine') }
    return $txt
}

# ---------------- follow-up after saving (org edition): still a problem? -> tell support? ----------------

function Get-WkFollowConfig {
    $c = @{ enabled = $false; url = '' }
    if (-not (Test-WkFeature 'followup')) { return $c }
    try { $f = (Get-WkRules).followup; if ($f) { if ($null -ne $f.enabled) { $c.enabled = [bool]$f.enabled }; if ($f.url) { $c.url = [string]$f.url } } } catch { }
    if (-not $c.url) { $c.enabled = $false }
    return $c
}

function Start-WkFollowUp {
    if (-not (Get-WkFollowConfig).enabled) { return }
    $global:WkState.follow = @{ step = 'q1'; suspect = $null; told = $false }
    try { $img = Get-DokiImage 'concerned' -Small; if (-not $img) { $img = Get-DokiImage 'hello' -Small }; $global:WkUi.FollowDokiImg.Source = $img } catch { }
    $global:WkUi.FollowCard.Visibility = 'Visible'
    Update-WkFollowUp
    Invoke-DokiEvent 'followAsk'
}

function Update-WkFollowUp {
    $f = $global:WkState.follow
    $u = $global:WkUi
    if (-not $f) { $u.FollowCard.Visibility = 'Collapsed'; return }
    $u.FollowInfo.Visibility = 'Collapsed'
    $u.FollowButtons.Visibility = 'Visible'
    switch ($f.step) {
        'q1' {
            $v = Get-WkCurrentVerdict
            if ($v.overall.status -eq 'green') { $u.FollowQ.Text = T 'follow.q1Ok' } else { $u.FollowQ.Text = T 'follow.q1Issues' (@($v.overall.reasons).Count) }
        }
        'q2' { $u.FollowQ.Text = T 'follow.q2' }
        'done' {
            $u.FollowButtons.Visibility = 'Collapsed'
            $k = 'follow.thanks'; if ($f.infoKey) { $k = $f.infoKey }
            $u.FollowQ.Text = T $k $f.infoArg
        }
    }
}

function Submit-WkFollowUp([bool]$Yes) {
    $f = $global:WkState.follow
    if (-not $f) { return }
    if ($f.step -eq 'q1') {
        $f.suspect = $Yes
        Write-WkLog ('follow-up: still suspects a problem = ' + $Yes)
        if ($Yes) { $f.step = 'q2' } else { $f.step = 'done'; Invoke-DokiEvent 'followDone' }
    } elseif ($f.step -eq 'q2') {
        $f.step = 'done'
        if ($Yes) {
            $url = (Get-WkFollowConfig).url
            try {
                $safe = (Get-Command Test-WkHttpsUrl -ErrorAction SilentlyContinue) -and (Test-WkHttpsUrl $url)
                if (-not $safe) { throw ('not an https URL: ' + $url) }   # rules/org config is editable: never start a file/command
                [System.Windows.Clipboard]::SetText((Get-WkCurrentReportText))
                Start-Process $url
                $f.told = $true; $f.infoKey = 'follow.opened'
                Write-WkLog ('follow-up: report text copied, opened ' + $url)
                Invoke-DokiEvent 'followPortal'
            } catch { $f.infoKey = 'follow.openFail'; $f.infoArg = $_.Exception.Message; Write-WkLog ('follow-up open failed: ' + $_.Exception.Message) 'WARN' }
        } else { Invoke-DokiEvent 'followDone' }
    }
    Update-WkFollowUp
}

function Copy-WkReportUi {
    $txt = Get-WkCurrentReportText
    [System.Windows.Clipboard]::SetText($txt)
    $global:WkUi.SavedText.Text = T 'report.copied'
    $global:WkUi.SavedBox.Visibility = 'Visible'
}

# ---------------- Jira (org edition). One issue per device; "Update report" re-uploads the attachment only (#6). ----------------

function Send-WkReportToJira {
    if (-not (Test-WkFeature 'jira')) { return }
    if ($global:WkState.login.id -eq 'contractor') { return }
    if (-not $global:WkState.reportPath) { $global:WkUi.SavedText.Text = T 'jira.saveFirst'; return }
    if ($global:WkTasks.ContainsKey('jiraSend')) { return }
    if ($global:WkJiraSentRev -eq $global:WkState.reportRev) { return }
    $v = Get-WkCurrentVerdict
    $sys = $null; if ($global:WkState.checks.system -and $global:WkState.checks.system.ok) { $sys = $global:WkState.checks.system.data }
    $model = ''; $serial = ''; if ($sys) { $model = [string]$sys.model; $serial = [string]$sys.serial }
    $summary = 'Laptop QC ' + $global:WkUi.TxtAsset.Text.Trim() + ' ' + $model + ' ' + $serial + ' - ' + (Get-WkVerdictWord $v.overall.status)
    $l = $global:WkState.login
    $who = ''; if ($l.role -eq 'guest') { $who = $global:WkUi.TxtGuestName.Text.Trim() } else { $who = Get-WkStaffDisplayName $l.id }
    $ticket = @{ summary = $summary; text = (Get-WkCurrentReportText); asset = $global:WkUi.TxtAsset.Text.Trim(); serial = $serial; model = $model
                 verdict = [string]$v.overall.status; technician = $who; role = [string]$l.role; reportPath = [string]$global:WkState.reportPath
                 followUpSuspect = [bool]($global:WkState.follow -and $global:WkState.follow.suspect)
                 qcFields = (Get-WkJiraQcValues $global:WkState.checks $global:WkState.stress $v) }
    if ($global:WkJiraIssueKey) { $ticket.existingIssueKey = [string]$global:WkJiraIssueKey }
    Set-WkJiraState 'sending'
    $g = Get-WkGradeSafe $global:WkState.checks $global:WkState.stress $v
    if ($g) { $ticket.grade = [string]$g.grade; $ticket.score = [int]$g.score; $ticket.summary += ' [' + $g.grade + ']' }
    $ticket.reporterEmail = if ($l.role -eq 'guest') { $who } else { Get-WkPrimaryEmail ([string]$l.id) }
    $ticket.stress = $global:WkState.stress; $ticket.manual = $global:WkState.checks.manual
    # 2.7.0: laptop fields + warranty decision
    $diskGb = 0; if ($global:WkState.checks.disks -and $global:WkState.checks.disks.ok) { foreach ($d in @($global:WkState.checks.disks.data.disks | Where-Object { $_ })) { $diskGb += [double]$d.sizeGB } }
    $ticket.laptop = @{ model = ''; cpu = ''; ramGB = $null; diskGB = [math]::Round($diskGb) }
    if ($sys) { $ticket.laptop.model = ([string]$sys.manufacturer + ' ' + [string]$sys.model).Trim(); $ticket.laptop.cpu = [string]$sys.cpu; $ticket.laptop.ramGB = [double]$sys.ramGB }
    $war = Get-WkWarrantySafe $g $global:WkState.checks
    if ($war) { $ticket.warranty = @{ reject = [bool]$war.reject; text = (Format-WkWarrantyReasons $war); ids = @($war.reasons | ForEach-Object { [string]$_.id }); comment = $global:WkUi.TxtNotes.Text.Trim() } }
    $global:WkJiraSendingRev = $global:WkState.reportRev
    [void](Start-WkTask 'jiraSend' 'jiraSend' @(, $ticket) $global:WkJiraModules)
}

function Complete-WkJiraSend($Out) {
    if ($Out.ok) {
        $global:WkJiraSentRev = $global:WkJiraSendingRev
        if ($Out.key) { $global:WkJiraIssueKey = [string]$Out.key }
        $note = ''; if (@($Out.skipped).Count -gt 0) { $note = 'Not on the Jira screen (not sent): ' + (@($Out.skipped) -join ', ') }
        Set-WkJiraState 'sent' ([string]$Out.key) ([string]$Out.url) $note
    } else {
        Write-WkLog ([string]$Out.error) 'ERROR'
        if ($Out.partial -and $Out.key) { $global:WkJiraIssueKey = [string]$Out.key; Set-WkJiraState 'partial' ([string]$Out.key) ([string]$Out.url) ([string]$Out.error) }
        else { Set-WkJiraState 'failed' '' '' ([string]$Out.error) }
    }
}

# ---------------- Jira delivery status (2.8.0): one state, shown on the report screen and in the finish window ----------------

$global:WkJira = @{ state = 'off'; key = ''; url = ''; error = '' }

# State before anything was sent: off | contractor | notConfigured | waiting | manual.
function Get-WkJiraBaseState {
    if (-not (Test-WkFeature 'jira')) { return 'off' }
    if ($global:WkState.login.id -eq 'contractor') { return 'contractor' }
    $t = $null; try { $t = Test-WkSupportConfig } catch { }
    if (-not $t -or -not $t.ok) { return 'notConfigured' }
    if (-not $global:WkState.reportPath) { return 'waiting' }
    $auto = $false; try { $auto = [bool](Get-WkSupportConfig).autoSend } catch { }
    if ($auto) { return 'waiting' }
    return 'manual'
}

function Set-WkJiraState([string]$State, [string]$Key = '', [string]$Url = '', [string]$Err = '') {
    $global:WkJira = @{ state = $State; key = $Key; url = $Url; error = $Err }
    Write-WkLog ('jira state: ' + $State + ' ' + $Key)
    Update-WkJiraStatusUi
}

function Update-WkJiraStatusUi {
    $u = $global:WkUi
    $j = $global:WkJira
    $show = Test-WkFeature 'jira'
    $tone = @{ sending = 'busy'; sent = 'green'; partial = 'amber'; failed = 'red' }[[string]$j.state]; if (-not $tone) { $tone = 'grey' }
    $pal = $global:WkPalette[$tone]
    $text = switch ([string]$j.state) {
        'sent' { T 'jira.state.sent' $j.key } 'partial' { T 'jira.state.partial' $j.key } default { T ('jira.state.' + [string]$j.state) }
    }
    $detail = [string]$j.error; if ($detail.Length -gt 220) { $detail = $detail.Substring(0, 220) + '...' }
    $retry = $j.state -in @('failed', 'partial', 'manual')
    $open = [bool]($j.key -and $j.url -and (Get-Command Test-WkHttpsUrl -ErrorAction SilentlyContinue) -and (Test-WkHttpsUrl $j.url))
    foreach ($p in @('', 'Fin')) {
        $box = $u[$p + 'JiraBox']; if (-not $box) { continue }
        Set-WkVisible $box $show
        $box.Background = Get-WkBrush $pal.fill; $box.BorderBrush = Get-WkBrush $pal.border
        $u[$p + 'JiraStateText'].Text = $text; $u[$p + 'JiraStateText'].Foreground = Get-WkBrush $pal.fg
        $u[$p + 'JiraDetail'].Text = $detail; Set-WkVisible $u[$p + 'JiraDetail'] ([bool]$detail)
        Set-WkVisible $u['Btn' + $p + 'JiraRetry'] $retry
        Set-WkVisible $u['Btn' + $p + 'JiraOpen'] $open
    }
}

function Invoke-WkJiraRetry {
    $global:WkJiraSentRev = $null
    Send-WkReportToJira
}

function Open-WkSummaryPage { $sp = [string]$global:WkState.reportInfo.summary; if ($sp -and (Test-WkReportPathSafe $sp)) { Start-Process -FilePath $sp } }

function Open-WkJiraIssue { $j = $global:WkJira; if ($j.url -and (Test-WkHttpsUrl $j.url)) { Start-Process $j.url } }

# ---------------- settings (2.8.0, org flag "settings") ----------------

function Get-WkRuleDefaults {
    # rules.json + org.json without config\settings.json
    $keep = $global:WkRules
    $global:WkSkipSettings = $true; $global:WkRules = $null
    try { $r = Get-WkRules } finally { $global:WkSkipSettings = $false; $global:WkRules = $keep }
    return @{ battery = [int]$r.battery.min_health_percent; disk = [int]$r.disk.min_health_percent; cycles = [int]$r.battery.cycle_alarm }
}

function Show-WkSettingsValues {
    $u = $global:WkUi
    $r = Get-WkRules; $d = Get-WkRuleDefaults
    $u.TxtSetBattery.Text = [string][int]$r.battery.min_health_percent
    $u.TxtSetDisk.Text = [string][int]$r.disk.min_health_percent
    $u.TxtSetCycles.Text = [string][int]$r.battery.cycle_alarm
    $u.SetBatteryDefault.Text = T 'settings.default' $d.battery
    $u.SetDiskDefault.Text = T 'settings.default' $d.disk
    $u.SetCyclesDefault.Text = T 'settings.default' $d.cycles
    $u.SettingsMsg.Text = ''
}

function Save-WkSettingsUi {
    $u = $global:WkUi
    $s = ConvertTo-WkSettings $u.TxtSetBattery.Text $u.TxtSetDisk.Text $u.TxtSetCycles.Text
    if (-not $s.ok) {
        $names = @($s.bad | ForEach-Object { T ('settings.' + $_) }) -join ', '
        $u.SettingsMsg.Text = T 'settings.invalid' $names; $u.SettingsMsg.Foreground = Get-WkBrush 'C.Red.Fg'; return
    }
    try { Write-WkJson (Get-WkSettingsPath) $s.values }
    catch { $u.SettingsMsg.Text = T 'settings.saveFailed' $_.Exception.Message; $u.SettingsMsg.Foreground = Get-WkBrush 'C.Red.Fg'; return }
    Write-WkLog ('settings saved: battery ' + $s.values.batteryMinHealth + ', disk ' + $s.values.diskMinHealth + ', cycles ' + $s.values.cycleAlarm)
    Complete-WkSettingsChange
    $u.SettingsMsg.Text = T 'settings.saved'; $u.SettingsMsg.Foreground = Get-WkBrush 'C.Green.Fg'
}

function Reset-WkSettingsUi {
    try { $p = Get-WkSettingsPath; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } } catch { }
    Complete-WkSettingsChange
    Show-WkSettingsValues
    $global:WkUi.SettingsMsg.Text = T 'settings.saved'; $global:WkUi.SettingsMsg.Foreground = Get-WkBrush 'C.Green.Fg'
}

function Complete-WkSettingsChange {
    $global:WkRules = $null
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) { if ($global:WkState.checks[$k]) { Update-WkCard $k } }
    Set-WkDirty
}

# ---------------- finish window (2.8.0, org flag "finishWindow") ----------------
# FinishRoot (MainWindow.xaml) is moved into its own window once; the window is hidden, never closed, so it can be shown again.

function Initialize-WkFinishWindow {
    if (-not (Test-WkFeature 'finishWindow')) { return }
    $u = $global:WkUi
    $w = New-Object System.Windows.Window
    foreach ($k in @($global:WkWindow.Resources.Keys)) { $w.Resources[$k] = $global:WkWindow.Resources[$k] }
    $w.Title = 'Doki'; $w.Width = 760; $w.Height = [math]::Min(820, [System.Windows.SystemParameters]::WorkArea.Height * 0.95)
    $w.WindowStartupLocation = 'CenterScreen'; $w.FontFamily = 'Segoe UI, Tahoma'; $w.FontSize = 15; $w.Background = Get-WkBrush 'C.Bg'
    if ($global:WkWindow.Icon) { $w.Icon = $global:WkWindow.Icon }
    [void]$u.FinishHolder.Children.Remove($u.FinishRoot)
    $w.Content = $u.FinishRoot
    $w.Add_Closing({ param($s, $e) if (-not $global:WkFinAllowClose) { $e.Cancel = $true; Invoke-WkUiSafe { Hide-WkFinish $false } } })
    $global:WkFinWin = $w
}

function Update-WkFinishContent {
    $u = $global:WkUi
    $v = Get-WkCurrentVerdict
    $g = Get-WkGradeSafe $global:WkState.checks $global:WkState.stress $v
    if ($g) { $u.FinGradeTag.Background = Get-WkBrush (Get-WkGradeColor $g.grade); $u.FinGradeText.Text = $g.grade; $u.FinGradeTag.Visibility = 'Visible' } else { $u.FinGradeTag.Visibility = 'Collapsed' }
    $u.FinVerdict.Text = (T 'report.verdict') + ': ' + (Get-WkVerdictWord $v.overall.status)
    $u.FinVerdict.Foreground = Get-WkBrush $global:WkPalette[$v.overall.status].fg
    $war = Get-WkWarrantySafe $g $global:WkState.checks
    if ($war -and $war.reject) { $u.FinWarrantyText.Text = (T 'warranty.title') + ' - ' + (Format-WkWarrantyReasons $war); $u.FinWarrantyBox.Visibility = 'Visible' } else { $u.FinWarrantyBox.Visibility = 'Collapsed' }
    $u.FinPath.Text = [string]$global:WkState.reportPath
    Set-WkVisible $u.BtnFinPrintSummary ([bool]($global:WkState.reportInfo -and $global:WkState.reportInfo.summary))
    Update-WkJiraStatusUi
}

# After the first save: the main window steps aside ("previous pages close") and the finish window takes over.
function Show-WkFinish {
    if (-not $global:WkFinWin) { return }
    $w = $global:WkFinWin
    if (Test-WkRtl) { $w.FlowDirection = 'RightToLeft' } else { $w.FlowDirection = 'LeftToRight' }
    Update-WkTagged $global:WkUi.FinishRoot
    Update-WkFinishContent
    $global:WkWindow.WindowState = 'Minimized'
    $w.Show(); [void]$w.Activate()
}

# $Next = $true: "Next device" (reset the main window); $false: back to the report.
function Hide-WkFinish([bool]$Next) {
    if ($global:WkFinWin -and $global:WkFinWin.IsVisible) { $global:WkFinWin.Hide() }
    $global:WkWindow.WindowState = 'Normal'; [void]$global:WkWindow.Activate()
    if ($Next) { Reset-WkForNewDevice }
}

# ---------------- history (2.6.0, #11) + duplicate guard ----------------

function Get-WkVerdictWord([string]$Status) {
    $k = @{ green = 'report.ok'; amber = 'report.check'; red = 'report.bad' }[$Status]
    if ($k) { return (T $k) }
    return $Status
}

$global:WkHistory = @{ rows = $null; sort = 'date'; desc = $true }
$global:WkHistoryKeys = @('date', 'staff', 'asset', 'model', 'serial', 'grade', 'verdict')
$global:WkHistoryHeaderKeys = @('history.date', 'history.who', 'history.asset', 'history.model', 'history.serial', 'history.grade', 'history.verdict')

function Get-WkHistoryModules { return @($global:WkReportModules | Where-Object { $_ -like '*\lib\Common.ps1' -or $_ -like '*\report\Report.ps1' }) }

function Initialize-WkHistoryFilters {
    $u = $global:WkUi
    $global:WkHistoryBuilding = $true
    try {
        $vi = [math]::Max(0, $u.CmbHistoryVerdict.SelectedIndex); $ri = $u.CmbHistoryRange.SelectedIndex; if ($ri -lt 0) { $ri = 2 }
        $u.CmbHistoryVerdict.Items.Clear(); $u.CmbHistoryRange.Items.Clear()
        foreach ($p in @(@('', 'history.allResults'), @('green', 'report.ok'), @('amber', 'report.check'), @('red', 'report.bad'))) {
            $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = T $p[1]; $it.DataContext = $p[0]; [void]$u.CmbHistoryVerdict.Items.Add($it)
        }
        foreach ($p in @(@('today', 'history.rangeToday'), @('week', 'history.rangeWeek'), @('all', 'history.rangeAll'))) {
            $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = T $p[1]; $it.DataContext = $p[0]; [void]$u.CmbHistoryRange.Items.Add($it)
        }
        $u.CmbHistoryVerdict.SelectedIndex = $vi; $u.CmbHistoryRange.SelectedIndex = $ri
    } finally { $global:WkHistoryBuilding = $false }
}

function Update-WkHistoryHeaders {
    $cols = $global:WkUi.HistoryList.View.Columns
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $h = T $global:WkHistoryHeaderKeys[$i]
        if ($global:WkHistoryKeys[$i] -eq $global:WkHistory.sort) { if ($global:WkHistory.desc) { $h += ' ' + [char]0x25BC } else { $h += ' ' + [char]0x25B2 } }
        $cols[$i].Header = $h
    }
}

function Start-WkHistoryLoad {
    $global:WkHistory.rows = $null
    $global:WkUi.HistoryList.ItemsSource = $null
    $global:WkUi.HistoryCount.Text = T 'history.loading'
    [void](Start-WkTask 'historyRows' 'historyRows' @() (Get-WkHistoryModules))
}

function Complete-WkHistoryLoad($Out) {
    if (-not $Out.ok) { Write-WkLog ('history load failed: ' + [string]$Out.error) 'WARN'; $global:WkHistory.rows = @() }
    else { $global:WkHistory.rows = @($Out.rows) }
    if ($global:WkState.screen -eq 'ScreenHistory') { Update-WkHistory }
}

function Update-WkHistory {
    $u = $global:WkUi
    if ($null -eq $global:WkHistory.rows) { return }
    $verdict = ''; if ($u.CmbHistoryVerdict.SelectedItem) { $verdict = [string]$u.CmbHistoryVerdict.SelectedItem.DataContext }
    $range = 'all'; if ($u.CmbHistoryRange.SelectedItem) { $range = [string]$u.CmbHistoryRange.SelectedItem.DataContext }
    $rows = Select-WkHistoryRows $global:WkHistory.rows $u.TxtHistorySearch.Text $verdict $range (Get-Date) $global:WkHistory.sort $global:WkHistory.desc
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $st = [string]$r.verdict; if (-not $global:WkPalette.ContainsKey($st)) { $st = 'grey' }
        $who = [string]$r.staff; if (-not $who) { $who = T 'role.guest' }
        $asset = [string]$r.asset; if (-not $asset) { $asset = '-' }
        $grade = [string]$r.grade; if (-not $grade) { $grade = '-' }
        $items.Add([pscustomobject]@{ date = [string]$r.date; who = $who; asset = $asset; model = [string]$r.model; serial = [string]$r.serial; grade = $grade
            verdictText = (Get-WkVerdictWord ([string]$r.verdict)); vFill = (Get-WkBrush $global:WkPalette[$st].fill); vFg = (Get-WkBrush $global:WkPalette[$st].fg); path = [string]$r.report_path })
    }
    $u.HistoryList.ItemsSource = $items
    if ($items.Count -eq 0) { $u.HistoryCount.Text = T 'history.empty' } else { $u.HistoryCount.Text = T 'history.count' $items.Count }
    Update-WkHistoryHeaders
}

function Invoke-WkHistorySort($Header) {
    if (-not ($Header -is [System.Windows.Controls.GridViewColumnHeader]) -or -not $Header.Column) { return }
    $i = $global:WkUi.HistoryList.View.Columns.IndexOf($Header.Column)
    if ($i -lt 0) { return }
    $key = $global:WkHistoryKeys[$i]
    if ($global:WkHistory.sort -eq $key) { $global:WkHistory.desc = -not $global:WkHistory.desc } else { $global:WkHistory.sort = $key; $global:WkHistory.desc = ($key -eq 'date') }
    Update-WkHistory
}

function Get-WkHistorySelectedPath {
    $it = $global:WkUi.HistoryList.SelectedItem
    if (-not $it) { return $null }
    $p = [string]$it.path
    # index.csv is an editable file: only a local, existing .html report is opened, never an exe/script/UNC path.
    if (Test-WkReportPathSafe $p) { return $p }
    Write-WkLog ('history: refused to open ' + $p) 'WARN'
    return $null
}

function Open-WkHistorySelected { $p = Get-WkHistorySelectedPath; if ($p) { Start-Process -FilePath $p } }
function Open-WkHistoryFolder { $p = Get-WkHistorySelectedPath; if ($p) { Start-Process 'explorer.exe' ('/select,"' + $p + '"') } }

function Test-WkDuplicate {
    $global:WkUi.DupBanner.Visibility = 'Collapsed'
    $asset = $global:WkUi.TxtAsset.Text.Trim()
    $serial = ''
    if ($global:WkState.checks.system -and $global:WkState.checks.system.ok) { $serial = [string]$global:WkState.checks.system.data.serial }
    [void](Start-WkTask 'dupCheck' 'dupCheck' @($asset, $serial, (Get-Date).ToString('yyyy-MM-dd')) (Get-WkHistoryModules))
}

function Complete-WkDuplicate($Out) {
    $hit = $Out.hit
    if (-not $Out.ok -or -not $hit) { return }
    $who = [string]$hit.staff; if (-not $who) { $who = T 'role.guest' }
    $global:WkUi.DupText.Text = T 'dup.warn' (([string]$hit.date) + ', ' + $who)
    $global:WkUi.DupBanner.Visibility = 'Visible'
    Invoke-DokiEvent 'duplicate'
}

# ---------------- login: staff list from config\staff.json (org edition) or the operator's name (standalone) ----------------

function Get-WkStaff {
    if ($null -eq $global:WkStaffCache) {
        $list = @()
        if ((Get-WkEdition).features.staffLogin) {
            try { $p = Join-Path $global:WkRoot 'config\staff.json'; if (Test-Path -LiteralPath $p) { $list = @((Read-WkJson $p).staff | Where-Object { $_ -and $_.id }) } } catch { Write-WkLog ('staff.json unreadable: ' + $_.Exception.Message) 'WARN' }
        }
        $global:WkStaffCache = $list
    }
    return $global:WkStaffCache
}

function Get-WkStaffDisplayName([string]$Id) {
    foreach ($p in (Get-WkStaff)) {
        if ([string]$p.id -eq $Id) {
            if (-not (Test-WkRtl) -and $p.nameEn) { return [string]$p.nameEn }
            if ($p.name) { return [string]$p.name }
            return [string]$p.nameEn
        }
    }
    return $Id
}

function Get-WkPrimaryEmail([string]$Id) {
    foreach ($p in (Get-WkStaff)) { if ([string]$p.id -eq $Id -and $p.email) { return [string]$p.email } }
    $o = Get-WkOrg
    if ($o -and $o.staffEmails) { return [string]$o.staffEmails.$Id }
    return ''
}

function Build-WkLoginCards {
    $u = $global:WkUi
    $cmb = $u.CmbLogin
    if (-not (Test-WkFeature 'staffLogin')) {
        # Standalone: no staff list; the operator types a name and the asset tag (local report only).
        Set-WkVisible $cmb $false; Set-WkVisible $u.LoginChoose $false
        $global:WkState.login = @{ role = 'guest'; id = 'contractor'; name = $null }
        Update-WkHomeButtons
        return
    }
    $global:WkLoginBuilding = $true
    try {
        $cmb.Items.Clear()
        foreach ($p in (Get-WkStaff)) {
            $it = New-Object System.Windows.Controls.ComboBoxItem
            $it.Content = Get-WkStaffDisplayName ([string]$p.id); $it.DataContext = [string]$p.id; $it.Padding = '10,8'
            $it.Name = 'Login_' + [regex]::Replace([string]$p.id, '[^A-Za-z0-9_]', '_')
            [void]$cmb.Items.Add($it)
        }
        if (Test-WkFeature 'corporateEmail') {
            $g = New-Object System.Windows.Controls.ComboBoxItem
            $g.Content = T 'login.guest'; $g.DataContext = 'guest'; $g.Name = 'Login_guest'; $g.Padding = '10,8'
            $g.Foreground = Get-WkBrush 'C.Amber.Fg'; $g.FontWeight = 'SemiBold'
            [void]$cmb.Items.Add($g)
        }
        $c = New-Object System.Windows.Controls.ComboBoxItem
        $c.Content = T 'login.contractor'; $c.DataContext = 'contractor'; $c.Name = 'Login_contractor'; $c.Padding = '10,8'
        [void]$cmb.Items.Add($c)
        Update-WkLoginHighlight
    } finally { $global:WkLoginBuilding = $false }
}

function Update-WkLoginHighlight {
    $sel = $global:WkState.login.id
    $global:WkLoginBuilding = $true
    try {
        $global:WkUi.CmbLogin.SelectedIndex = -1
        foreach ($c in $global:WkUi.CmbLogin.Items) { if ([string]$c.DataContext -eq $sel) { $global:WkUi.CmbLogin.SelectedItem = $c } }
    } finally { $global:WkLoginBuilding = $false }
}

function Select-WkLogin([string]$Id) {
    if ($Id -in @('guest', 'contractor')) { $global:WkState.login = @{ role = 'guest'; id = $Id; name = $null } }
    else { $global:WkState.login = @{ role = 'staff'; id = $Id; name = (Get-WkStaffDisplayName $Id) } }
    Update-WkLoginHighlight
    Update-WkHomeButtons
    Update-WkRoleLine
    if ($global:WkState.screen -eq 'ScreenHome') { Invoke-DokiLogin }
}

function Update-WkRoleLine {
    $l = $global:WkState.login
    $u = $global:WkUi
    if (-not $l.role) { $u.RoleBox.Visibility = 'Collapsed'; return }
    if ($l.role -eq 'guest') {
        $t = T 'role.guest'
        if ($l.id -eq 'contractor' -and (Test-WkFeature 'staffLogin')) { $t = T 'login.contractor' }
        $gn = $u.TxtGuestName.Text.Trim()
        if ($gn) { if (Test-WkFeature 'staffLogin') { $t += ' (' + $gn + ')' } else { $t = $gn } }
        elseif (-not (Test-WkFeature 'staffLogin')) { $u.RoleBox.Visibility = 'Collapsed'; return }
        $u.RoleLine.Text = $t
        $u.RoleBox.Background = Get-WkBrush 'C.Amber.Fill'; $u.RoleLine.Foreground = Get-WkBrush 'C.Amber.Fg'
    } else {
        $l.name = Get-WkStaffDisplayName $l.id
        $u.RoleLine.Text = T 'role.staff' $l.name
        $u.RoleBox.Background = Get-WkBrush 'C.Green.Fill'; $u.RoleLine.Foreground = Get-WkBrush 'C.Green.Fg'
    }
    $u.RoleBox.Visibility = 'Visible'
}

function Save-WkLast {
    try {
        $last = @{ lang = $global:WkLang; staffId = $null; dokiMuted = [bool]$global:DokiState.muted; dokiDay = [string]$global:DokiLastDay }
        if ($global:WkState.login.role -eq 'staff') { $last.staffId = $global:WkState.login.id }
        Write-WkJson (Join-Path (Get-WkWritableDir 'config') 'last.json') $last
    } catch { }
}

function Update-WkHomeButtons {
    $u = $global:WkUi
    $role = $global:WkState.login.role
    $asset = $u.TxtAsset.Text.Trim()
    $name = $u.TxtGuestName.Text.Trim()
    $contractor = $global:WkState.login.id -eq 'contractor'
    $guestValid = $false
    if ($contractor) { $guestValid = $name.Length -ge 2 -and $asset -ne '' }
    elseif (Test-WkFeature 'corporateEmail') { $guestValid = [bool](Test-WkCorporateEmail $name) }
    if ($contractor) { $u.GuestNameLabel.Text = T 'login.contractorName' } else { $u.GuestNameLabel.Text = T 'login.guestName' }
    $ok = (($role -eq 'staff') -and ($asset -ne '')) -or (($role -eq 'guest') -and $guestValid)
    Set-WkVisible $u.GuestEmailError ($role -eq 'guest' -and -not $contractor -and $name -and -not $guestValid)
    $u.BtnStart.IsEnabled = $ok
    $u.BtnStressOnly.IsEnabled = $ok
    if ($ok) { $u.HintFill.Visibility = 'Hidden' } else { $u.HintFill.Visibility = 'Visible' }
    Set-WkVisible $u.GuestNamePanel ($role -eq 'guest')
    Set-WkVisible $u.AssetHint ($role -eq 'guest' -and -not $contractor)   # the asset tag is optional only for a corporate guest
}

# ---------------- manual disk % (MUST-3): one TextBox + source ComboBox per disk, outside the rebuilt details panel ----------------

$global:WkDiskSources = @('SSD Life', 'HDD Sentinel', 'Other')

function Build-WkDiskManual {
    $panel = $global:WkUi.DiskManualPanel
    $panel.Children.Clear()
    $res = $global:WkState.checks.disks
    if (-not $res -or -not $res.ok) { return }
    if (-not $global:WkState.checks.diskManual) { $global:WkState.checks.diskManual = @{} }
    $disks = @($res.data.disks | Where-Object { $_ })
    # Automatic health is the main path; the manual field is an optional override behind a link,
    # opened automatically when a disk has no automatic % or a manual value already exists.
    $needs = @($disks | Where-Object { $null -eq $_.healthPercent }).Count -gt 0
    $hasValue = @($global:WkState.checks.diskManual.Values | Where-Object { $_ -and ([string]$_.percent).Trim() }).Count -gt 0
    if (-not ($needs -or $hasValue -or $global:WkState.diskManualOpen)) {
        $tg = New-Object System.Windows.Controls.Button
        $tg.Style = $global:WkWindow.FindResource('Link'); $tg.Name = 'DiskManualToggle'; $tg.Content = T 'disk.manualToggle'
        $tg.HorizontalAlignment = 'Left'; $tg.FontSize = 13; $tg.Height = 30; $tg.Padding = '0,0'
        $tg.Add_Click({ Invoke-WkUiSafe { $global:WkState.diskManualOpen = $true; Build-WkDiskManual } })
        [void]$panel.Children.Add($tg)
        return
    }
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $prev = $global:WkState.checks.diskManual[[string]$i]
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = (T 'disk.manual') + ':'
        if ($disks.Count -gt 1) { $lbl.Text = (T 'disk.manual') + ' - ' + [string]$disks[$i].name + ':' }
        $lbl.FontSize = 13; $lbl.FontWeight = 'SemiBold'; $lbl.TextWrapping = 'Wrap'; $lbl.Margin = '0,4,0,4'
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Name = 'DiskManualPct' + $i; $tb.Width = 90; $tb.Height = 38; $tb.FontSize = 16; $tb.FlowDirection = 'LeftToRight'
        $tb.DataContext = $i
        if ($prev) { $tb.Text = [string]$prev.percent }
        $pc = New-Object System.Windows.Controls.TextBlock
        $pc.Text = '%'; $pc.FontSize = 16; $pc.VerticalAlignment = 'Center'; $pc.Margin = '6,0,12,0'
        $cb = New-Object System.Windows.Controls.ComboBox
        $cb.Name = 'DiskManualSrc' + $i; $cb.Width = 150; $cb.Height = 38; $cb.FontSize = 14; $cb.VerticalContentAlignment = 'Center'
        $cb.DataContext = $i
        [void]$cb.Items.Add('SSD Life'); [void]$cb.Items.Add('HDD Sentinel'); [void]$cb.Items.Add((T 'disk.sourceOther'))
        $cb.SelectedIndex = 0
        if ($prev -and $prev.source) { $ix = [array]::IndexOf($global:WkDiskSources, [string]$prev.source); if ($ix -ge 0) { $cb.SelectedIndex = $ix } }
        $tb.Add_TextChanged({ param($s, $e) Invoke-WkUiSafe { Set-WkDiskManual ([int]$s.DataContext) } })
        $cb.Add_SelectionChanged({ param($s, $e) Invoke-WkUiSafe { Set-WkDiskManual ([int]$s.DataContext) } })
        [void]$row.Children.Add($tb); [void]$row.Children.Add($pc); [void]$row.Children.Add($cb)
        [void]$panel.Children.Add($lbl); [void]$panel.Children.Add($row)
    }
}

function Set-WkDiskManual([int]$Index) {
    $tb = $null; $cb = $null
    foreach ($c in $global:WkUi.DiskManualPanel.Children) {
        if ($c -is [System.Windows.Controls.StackPanel]) {
            foreach ($x in $c.Children) {
                if ($x.Name -eq ('DiskManualPct' + $Index)) { $tb = $x }
                if ($x.Name -eq ('DiskManualSrc' + $Index)) { $cb = $x }
            }
        }
    }
    if (-not $tb) { return }
    if (-not $global:WkState.checks.diskManual) { $global:WkState.checks.diskManual = @{} }
    $src = 'SSD Life'
    if ($cb -and $cb.SelectedIndex -ge 0) { $src = $global:WkDiskSources[$cb.SelectedIndex] }
    $global:WkState.checks.diskManual[[string]$Index] = @{ percent = $tb.Text; source = $src }
    # Red border while the text is not a valid 0-100 number (it is then ignored by the rules).
    if ($tb.Text.Trim() -and $null -eq (ConvertTo-WkPercent $tb.Text)) { $tb.BorderBrush = Get-WkBrush 'C.Red.Fg' } else { $tb.BorderBrush = Get-WkBrush 'C.Input' }
    Update-WkCard 'disks'
    Set-WkDirty
}

function Update-WkDeviceLine {
    $sys = $global:WkState.checks.system
    if ($sys -and $sys.ok) {
        $d = $sys.data
        $global:WkUi.DeviceLine.Text = T 'checks.device' $d.manufacturer $d.model $d.serial
    }
}

function New-WkLine([string]$Text, [string]$Color = 'C.Text', [int]$Size = 14, [bool]$Bold = $false) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.TextWrapping = 'Wrap'; $tb.FontSize = $Size; $tb.Margin = '0,2,0,2'
    $tb.Foreground = Get-WkBrush $Color
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    return $tb
}

# Anything that changes the report content after it was saved turns "Saved" into "Update report" (#6).
function Set-WkDirty {
    $global:WkState.dirty = $true
    if ($global:WkState.reportPath) { Update-WkSaveButtons; Update-WkStepper }
}

# ---------------- background checks (2.6.0, #2): one RunspacePool, one job per collector ----------------

$global:WkCheckJobs = @('updates', 'device', 'activation', 'system', 'disks', 'battery', 'drivers')
$global:WkJobScript = @'
param($sync, $mods, $app, $root, $job, $timeout)
if (-not (Get-Command Get-WkDeviceFacts -ErrorAction SilentlyContinue)) { $global:WkApp = $app; $global:WkRoot = $root; foreach ($m in $mods) { . $m } }
try {
    switch ($job) {
        'system'     { $sync.system = Get-WkSystemInfo }
        'battery'    { $sync.battery = Get-WkBattery }
        'disks'      { $sync.disks = Get-WkDisks }
        'drivers'    { $sync.drivers = Get-WkDriverProblems }
        'device'     { $sync.deviceCore = Get-WkDeviceFacts -SkipActivation }
        'activation' { $sync.activation = Get-WkActivationState }
        'updates'    { $sync.updates = Get-WkUpdates -TimeoutSec $timeout }
    }
} catch { $sync['error_' + $job] = $_.Exception.Message }
'@

function Start-WkChecks {
    Stop-WkBackground
    $global:WkSync = [hashtable]::Synchronized(@{})
    # Keep the technician's manual disk % and checklist across a re-check of the same device.
    $keepManual = $global:WkState.checks.diskManual
    $keepList = $global:WkState.checks.manual
    $keepProg = $global:WkState.checks.manualProgress
    $keepCos = $global:WkState.checks.cosmeticDecision
    $global:WkState.checks = @{}
    if ($keepManual) { $global:WkState.checks.diskManual = $keepManual }
    if ($keepList) { $global:WkState.checks.manual = $keepList }
    if ($keepProg) { $global:WkState.checks.manualProgress = $keepProg }
    if ($keepCos) { $global:WkState.checks.cosmeticDecision = $keepCos }
    $global:WkState.checksStarted = Get-Date
    $global:WkChecksClock = [Diagnostics.Stopwatch]::StartNew()
    $global:DokiState.checksAnnounced = $false
    Invoke-DokiEvent 'checksRunning' @{ admin = (Test-WkAdmin) }
    $global:WkUi.DiskManualPanel.Children.Clear()
    Update-WkDeviceCard
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) { Update-WkCard $k }
    $max = [math]::Min(6, [math]::Max(3, [Environment]::ProcessorCount))
    $pool = [runspacefactory]::CreateRunspacePool(1, $max)
    $pool.ApartmentState = 'STA'
    $pool.Open()
    $global:WkPool = $pool
    $timeout = [int](Get-WkRules).updates.search_timeout_seconds
    foreach ($job in $global:WkCheckJobs) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($global:WkJobScript).AddArgument($global:WkSync).AddArgument(@($global:WkCollectorModules)).AddArgument($global:WkApp).AddArgument($global:WkRoot).AddArgument($job).AddArgument($timeout)
        $global:WkBg += @{ ps = $ps; handle = $ps.BeginInvoke(); job = $job }
    }
    Set-WkDirty
    Write-WkLog ('checks started (' + $global:WkCheckJobs.Count + ' jobs, pool max ' + $max + ')')
}

function Stop-WkBackground {
    foreach ($b in $global:WkBg) {
        try { [void]$b.ps.BeginStop($null, $null) } catch { }
    }
    $global:WkBg = @()
    if ($global:WkPool) { try { [void]$global:WkPool.BeginClose($null, $null) } catch { }; $global:WkPool = $null }
}

function Update-WkChecksPoll {
    if (-not $global:WkSync -or -not $global:WkState.checksStarted) { return }
    # finished jobs: free their PowerShell objects (results are already in $global:WkSync)
    if (@($global:WkBg).Count -gt 0) {
        $left = @()
        foreach ($b in $global:WkBg) { if ($b.handle.IsCompleted) { try { $b.ps.Dispose() } catch { } } else { $left += $b } }
        $global:WkBg = $left
    }
    $elapsed = ((Get-Date) - $global:WkState.checksStarted).TotalSeconds
    $changed = $false
    if (-not $global:WkState.checks.ContainsKey('device')) {
        if ($global:WkSync.ContainsKey('deviceCore')) {
            $actDone = $global:WkSync.ContainsKey('activation') -or $global:WkSync.ContainsKey('error_activation') -or $elapsed -gt 40
            if ($actDone) { $global:WkState.checks['device'] = Merge-WkActivation $global:WkSync['deviceCore'] $global:WkSync['activation']; Update-WkDeviceCard }
        } elseif ($global:WkSync.ContainsKey('error_device')) {
            $global:WkState.checks['device'] = @{ ok = $false; data = $null; error = $global:WkSync['error_device'] }; Update-WkDeviceCard
        }
    }
    foreach ($k in @('system', 'battery', 'disks', 'drivers', 'updates')) {
        if (-not $global:WkState.checks.ContainsKey($k) -and $global:WkSync.ContainsKey($k)) {
            $global:WkState.checks[$k] = $global:WkSync[$k]
            $changed = $true
            if ($k -eq 'system') { Update-WkDeviceLine; Test-WkDuplicate } else { Update-WkCard $k }
            if ($k -eq 'disks') { Build-WkDiskManual }
        }
    }
    $limit = [int](Get-WkRules).updates.search_timeout_seconds + 45
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) {
        if (-not $global:WkState.checks.ContainsKey($k)) {
            $runError = $global:WkSync['error_' + $k]
            if ($runError -or $elapsed -gt $limit) {
                if (-not $runError) { $runError = 'no answer after ' + [int]$elapsed + ' s' }
                $global:WkState.checks[$k] = @{ ok = $false; data = $null; error = $runError }
                Write-WkLog ('check ' + $k + ' gave up: ' + $runError) 'WARN'
                $changed = $true
            }
            Update-WkCard $k
        }
    }
    if (-not $global:DokiState.checksAnnounced -and @('battery', 'disks', 'drivers', 'updates' | Where-Object { $global:WkState.checks.ContainsKey($_) }).Count -eq 4) {
        $global:DokiState.checksAnnounced = $true
        if ($global:WkChecksClock) { Write-WkLog ('checks done in ' + $global:WkChecksClock.ElapsedMilliseconds + ' ms') }
        Invoke-DokiEvent 'checksDone' @{ verdict = (Get-WkCurrentVerdict) }
    }
    if ($changed) { Set-WkDirty; Update-WkStepper }
}

# ---------------- cards + summary chips (2.6.0, #9) ----------------

$global:WkCardKinds = @{ Bat = 'battery'; Disk = 'disks'; Drv = 'drivers'; Upd = 'updates' }

function Set-WkCard([string]$P, [string]$Status, [string]$Big, [string]$StatusText, [object[]]$Lines) {
    $u = $global:WkUi
    $pal = $global:WkPalette[$Status]
    $u[$P + 'Card'].Background = Get-WkBrush $pal.fill
    $u[$P + 'Card'].BorderBrush = Get-WkBrush $pal.border
    $u[$P + 'Badge'].Background = Get-WkBrush $pal.fg
    $u[$P + 'Icon'].Text = $pal.icon
    $u[$P + 'Icon'].Foreground = Get-WkBrush 'C.White'
    $u[$P + 'Big'].Text = $Big
    Set-WkVisible $u[$P + 'Big'] ([bool]$Big)
    $u[$P + 'Big'].Foreground = Get-WkBrush $pal.fg
    $u[$P + 'Status'].Text = $StatusText
    $u[$P + 'Status'].Foreground = Get-WkBrush $pal.fg
    $d = $u[$P + 'Details']
    $d.Children.Clear()
    $all = @($Lines | Where-Object { $_ })
    # Long lists (drivers, updates): first 3 lines + "show all (N)".
    $limit = 0; if ($P -eq 'Drv' -or $P -eq 'Upd') { $limit = 3 }
    $folding = ($limit -gt 0 -and $all.Count -gt ($limit + 1))
    $expanded = [bool]$global:WkState.expand[$P]
    $shown = $all; if ($folding -and -not $expanded) { $shown = @($all[0..($limit - 1)]) }
    foreach ($l in $shown) { [void]$d.Children.Add($l) }
    if ($folding) {
        $tg = New-Object System.Windows.Controls.Button
        $tg.Style = $global:WkWindow.FindResource('Link'); $tg.HorizontalAlignment = 'Left'; $tg.FontSize = 13; $tg.Height = 30; $tg.Padding = '0,0'
        if ($expanded) { $tg.Content = T 'common.showLess' } else { $tg.Content = T 'common.showAll' $all.Count }
        $tg.DataContext = $P; $tg.Name = 'Fold' + $P
        $tg.Add_Click({ param($s, $e) Invoke-WkUiSafe { $k = [string]$s.DataContext; $global:WkState.expand[$k] = -not [bool]$global:WkState.expand[$k]; Update-WkCard $global:WkCardKinds[$k] } })
        [void]$d.Children.Add($tg)
    }
    # summary chip
    $chip = $u['Chip' + $P]
    if ($chip) {
        $chip.Background = Get-WkBrush $pal.fill; $chip.BorderBrush = Get-WkBrush $pal.border
        $u['Chip' + $P + 'Badge'].Background = Get-WkBrush $pal.fg
        $u['Chip' + $P + 'Icon'].Text = $pal.icon
        $u['Chip' + $P + 'Big'].Text = $Big
        $u['Chip' + $P + 'Big'].Foreground = Get-WkBrush $pal.fg
        $chip.ToolTip = $StatusText
    }
}

function Get-WkDriverMeaning([int]$Code) {
    $k = 'drivers.code' + $Code
    if ($global:WkStrings.ContainsKey($k)) { return (T $k) }
    return (T 'drivers.codeOther' $Code)
}

function Update-WkCard([string]$Kind) {
    $map = @{ battery = 'Bat'; disks = 'Disk'; drivers = 'Drv'; updates = 'Upd' }
    $P = $map[$Kind]
    $res = $global:WkState.checks[$Kind]
    if (-not $res) {
        $secs = 0
        if ($global:WkState.checksStarted) { $secs = [int]((Get-Date) - $global:WkState.checksStarted).TotalSeconds }
        $text = ''; if ($global:WkState.checksStarted) { $text = T 'common.checking' }
        Set-WkCard $P 'busy' '' $text @((New-WkLine (T 'common.seconds' $secs) 'C.Muted'))
        return
    }
    $rules = Get-WkRules
    $lines = @()
    switch ($Kind) {
        'battery' {
            $v = Get-WkBatteryVerdict $res $rules
            $big = ''
            if ($res.ok -and $res.data.present) {
                $d = $res.data
                if ($null -ne $d.healthPercent) { $big = ('{0}%' -f $d.healthPercent) } else { $big = '-' }
                $cyc = T 'common.notReported'; if ($null -ne $d.cycles) { $cyc = [string]$d.cycles }
                $lines += New-WkLine ((T 'battery.cycles') + ': ' + $cyc)
                if ($d.runtimeMinutes) { $lines += New-WkLine ((T 'battery.runtime') + ': ' + (T 'battery.runtimeValue' ([math]::Floor($d.runtimeMinutes / 60)) ($d.runtimeMinutes % 60))) }
                else { $lines += New-WkLine ((T 'battery.runtime') + ': ' + (T 'common.notReported')) }
                if ($d.designMWh -and $d.fullMWh) { $lines += New-WkLine ((T 'battery.design') + ' / ' + (T 'battery.full') + ': ' + ('{0:N1} / {1:N1} Wh' -f ($d.designMWh / 1000), ($d.fullMWh / 1000))) 'C.Muted' }
            } elseif (-not $res.ok) { $lines += New-WkLine ([string]$res.error) 'C.Muted' 12 }
            $reasons = @($v.reasons)
            for ($i = 1; $i -lt $reasons.Count; $i++) { $lines += New-WkLine (Format-WkReason $reasons[$i]) $global:WkPalette[$v.status].fg 14 $true }
            Set-WkCard $P $v.status $big (Format-WkReason $reasons[0]) $lines
        }
        'disks' {
            $v = Get-WkDisksVerdict $res $rules $global:WkState.checks.diskManual
            $big = ''
            $statusText = ''
            if ($res.ok) {
                $disks = @($res.data.disks | Where-Object { $_ })
                $effs = @($v.effective)
                $hps = @($effs | Where-Object { $_ -and $null -ne $_.percent } | ForEach-Object { [double]$_.percent })
                if ($hps.Count -gt 0) { $big = ('{0}%' -f ($hps | Measure-Object -Minimum).Minimum) }
                for ($i = 0; $i -lt $disks.Count; $i++) {
                    $dk = $disks[$i]; $rowSt = $v.rows[$i]; $ef = $null; if ($i -lt $effs.Count) { $ef = $effs[$i] }
                    $hp = T 'common.notReported'
                    if ($ef -and $null -ne $ef.percent) {
                        $hp = ('{0}%' -f $ef.percent)
                        if ($ef.used -eq 'manual') { $hp += ' (' + (T 'disk.manualShort') + ', ' + $ef.source + ')' }
                        elseif ($dk.healthSource) { $hp += ' (' + (T ('disk.src.' + $dk.healthSource)) + ')' }
                        else { $hp += ' (' + (T 'disk.auto') + ')' }
                    }
                    # Two lines so Latin names and Persian labels never mix in one bidi run.
                    $head = New-WkLine ('{0}  |  {1} {2}  |  {3} GB' -f $dk.name, $dk.busType, $dk.mediaType, $dk.sizeGB) $global:WkPalette[$rowSt].fg 14 $true
                    $head.FlowDirection = 'LeftToRight'; $head.TextAlignment = 'Left'
                    if (Test-WkRtl) { $head.TextAlignment = 'Right' }
                    $lines += $head
                    $txt = (T 'disk.health') + ': ' + $hp + '  |  ' + (T 'disk.status') + ': ' + $dk.healthStatus
                    if ($dk.temperature) { $txt += ('  |  ' + (T 'disk.temp') + ': ' + $dk.temperature + [char]0x00B0 + 'C') }
                    if ($dk.powerOnHours) { $txt += ('  |  ' + (T 'disk.poh') + ': ' + $dk.powerOnHours) }
                    $lines += New-WkLine $txt $global:WkPalette[$rowSt].fg 14
                }
            } else { $lines += New-WkLine ([string]$res.error) 'C.Muted' 12 }
            # Card sentence: the reason of the first disk whose status equals the card status (reasons[i] belongs to rows[i]).
            $rs = @($v.reasons); $rowSts = @($v.rows)
            $main = $null
            for ($i = 0; $i -lt $rs.Count; $i++) {
                if ($rowSts.Count -eq 0 -or $rowSts[$i] -eq $v.status) { $main = $rs[$i]; break }
            }
            if ($main) { $ma = @($main.args); $statusText = T $main.key @ma }
            if ($res.ok -and @($v.effective | Where-Object { $_ -and $null -eq $_.percent }).Count -gt 0) {
                $lines += New-WkLine (T 'disk.enterHint') $global:WkPalette.amber.fg 13 $true
            }
            Set-WkCard $P $v.status $big $statusText $lines
        }
        'drivers' {
            $v = Get-WkDriversVerdict $res $rules
            foreach ($dv in @($v.alarm)) { $lines += New-WkLine ($dv.name + ' - ' + (Get-WkDriverMeaning $dv.code)) $global:WkPalette.red.fg 14 $true }
            if (@($v.info).Count -gt 0) {
                $lines += New-WkLine (T 'drivers.other') 'C.Muted' 13 $true
                foreach ($dv in @($v.info)) { $lines += New-WkLine ($dv.name + ' - ' + (Get-WkDriverMeaning $dv.code)) 'C.Muted' 13 }
            }
            if (-not $res.ok) { $lines += New-WkLine ([string]$res.error) 'C.Muted' 12 }
            $big = ''; if ($res.ok) { $big = [string]@($v.alarm).Count }
            Set-WkCard $P $v.status $big (Format-WkReason $v.reasons[0]) $lines
        }
        'updates' {
            $v = Get-WkUpdatesVerdict $res $rules
            $big = ''
            if ($res.ok -and $res.data.checked) {
                $big = [string]$res.data.pendingCount
                $titles = @($res.data.titles)
                foreach ($t in $titles) { $lines += New-WkLine ([string]$t) 'C.Text' 13 }
                if ($res.data.lastInstallDate) { $lines += New-WkLine (T 'updates.lastInstall' $res.data.lastInstallDate) 'C.Muted' 13 }
            } elseif ($res.ok -and $res.data.error) { $lines += New-WkLine ([string]$res.data.error) 'C.Muted' 12 }
            elseif (-not $res.ok) { $lines += New-WkLine ([string]$res.error) 'C.Muted' 12 }
            $reasons = @($v.reasons)
            for ($i = 1; $i -lt $reasons.Count; $i++) { $lines = @((New-WkLine (Format-WkReason $reasons[$i]) $global:WkPalette[$v.status].fg 14 $true)) + $lines }
            Set-WkCard $P $v.status $big (Format-WkReason $reasons[0]) $lines
        }
    }
}

# ---------------- stress ----------------

$global:WkStressPrefix = @{ cpu = 'Cpu'; ram = 'Ram'; disk = 'Disk'; gpu = 'Gpu' }

function Initialize-WkDurations {
    $cmb = $global:WkUi.CmbDuration
    $sel = $cmb.SelectedIndex
    $cmb.Items.Clear()
    $rules = Get-WkRules
    $i = 0; $def = 0
    foreach ($m in @($rules.stress.durations_minutes)) {
        [void]$cmb.Items.Add((T 'stress.minutes' $m))
        if ([int]$m -eq [int]$rules.stress.default_minutes) { $def = $i }
        $i++
    }
    if ($sel -ge 0) { $cmb.SelectedIndex = $sel } else { $cmb.SelectedIndex = $def }
}

function Get-WkSelectedSeconds {
    $rules = Get-WkRules
    $arr = @($rules.stress.durations_minutes)
    $i = $global:WkUi.CmbDuration.SelectedIndex
    if ($i -lt 0 -or $i -ge $arr.Count) { return [int]$rules.stress.default_minutes * 60 }
    return [int]$arr[$i] * 60
}

function Get-WkStressResultText($R) {
    switch ([string]$R.result) {
        'completed'   { return (T 'stress.completed') }
        'errors'      { return (T 'stress.errors' $R.errors) }
        'crashed'     { return (T 'stress.crashed') }
        'stopped'     { return (T 'stress.stopped') }
        'unavailable' { return (T 'stress.unavailable' $R.error) }
        'running'     { if ($global:WkState.stopping) { return (T 'stress.stopping') }; return (T 'stress.running') }
        default       { return (T 'stress.notRun') }
    }
}

function Get-WkStressColor([string]$Result) {
    switch ($Result) {
        'completed' { return 'green' }
        'errors' { return 'red' }
        'crashed' { return 'red' }
        'stopped' { return 'amber' }
        'running' { return 'busy' }
        default { return 'grey' }
    }
}

function Update-WkStressRow([string]$Kind, $Live = $null) {
    $P = $global:WkStressPrefix[$Kind]
    $r = $global:WkState.stress[$Kind]
    if (-not $r) { $r = @{ result = 'notRun' } }
    $pal = $global:WkPalette[(Get-WkStressColor $r.result)]
    $global:WkUi[$P + 'Pill'].Background = Get-WkBrush $pal.fill
    $global:WkUi[$P + 'PillText'].Foreground = Get-WkBrush $pal.fg
    $global:WkUi[$P + 'PillText'].Text = Get-WkStressResultText $r
    if ($Live) {
        $global:WkUi[$P + 'Prog'].Value = [double]$Live.progress
        $left = [TimeSpan]::FromSeconds([int]$Live.secondsLeft).ToString('mm\:ss')
        $txt = ''
        switch ($Kind) {
            'cpu' { $txt = T 'stress.cpuLive' $Live.threads $Live.errors }
            'ram' { $txt = T 'stress.ramLive' $Live.gb $Live.errors }
            'disk' { $txt = T 'stress.diskLive' $Live.mbps $Live.errors }
            'gpu' { $txt = T 'stress.gpuLive' }
        }
        $txt = $txt + '  |  ' + (T 'stress.timeLeft' $left)
        if ($null -ne $global:WkState.temp) { $txt += '  |  ' + (T 'stress.temp' $global:WkState.temp) }
        $global:WkUi[$P + 'Live'].Text = $txt
    } elseif ($r.result -ne 'running') {
        if ($r.result -eq 'notRun') { $global:WkUi[$P + 'Prog'].Value = 0 } else { $global:WkUi[$P + 'Prog'].Value = 1 }
        $detail = ''
        if ($r.detail) { $detail = [string]$r.detail }
        if ($r.error -and $r.result -ne 'unavailable') { $detail = ($detail + ' ' + [string]$r.error).Trim() }
        $global:WkUi[$P + 'Live'].Text = $detail
    }
}

function Update-WkStressButtons {
    $busy = [bool]$global:WkState.currentKind
    foreach ($k in $global:WkStressKinds) { $global:WkUi[$global:WkStressPrefix[$k] + 'Start'].IsEnabled = -not $busy }
    $global:WkUi.BtnRunAll.IsEnabled = -not $busy
    $global:WkUi.CmbDuration.IsEnabled = -not $busy
    $global:WkUi.BtnStressBack.IsEnabled = -not $busy
    $global:WkUi.BtnToReport.IsEnabled = -not $busy
    Set-WkVisible $global:WkUi.BtnStop $busy
    $global:WkUi.BtnStop.IsEnabled = -not [bool]$global:WkState.stopping
    Update-WkStepper
}

# Temperature for the stress screen (2.6.0, #3): a small background sampler instead of a CIM query on the UI thread.
function Start-WkTempSampler {
    if ($global:WkTempJob -or $global:WkTempUnavailable) { return }
    $global:WkTempSync = [hashtable]::Synchronized(@{ run = $true; temp = $null; unavailable = $false })
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($s)
        while ($s.run) {
            try {
                $z = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
                if ($z.Count -eq 0) { $s.unavailable = $true; break }
                $s.temp = [math]::Round((($z | Measure-Object CurrentTemperature -Maximum).Maximum / 10) - 273.15, 0)
            } catch { $s.unavailable = $true; break }
            for ($i = 0; $i -lt 50 -and $s.run; $i++) { Start-Sleep -Milliseconds 100 }
        }
    }.ToString()).AddArgument($global:WkTempSync)
    $global:WkTempJob = @{ ps = $ps; rs = $rs; h = $ps.BeginInvoke() }
}

function Stop-WkTempSampler {
    if (-not $global:WkTempJob) { return }
    $global:WkTempSync.run = $false
    if ($global:WkTempSync.unavailable) { $global:WkTempUnavailable = $true }
    $j = $global:WkTempJob; $global:WkTempJob = $null
    try { [void]$j.ps.BeginStop($null, $null) } catch { }
}

function Start-WkStressUi([string]$Kind) {
    if ($global:WkState.currentKind) { return }
    $secs = Get-WkSelectedSeconds
    $s = Start-WkStress $Kind $secs
    $global:WkState.stress[$Kind] = @{ result = 'running'; seconds = $secs }
    $global:WkState.currentKind = $Kind
    $global:WkState.stopping = $false
    Start-WkTempSampler
    if ($s.status -eq 'running') { Invoke-DokiEvent 'stressRunning' @{ kind = $Kind } }
    if ($s.status -ne 'running') { Complete-WkStressUi $s }
    Update-WkStressRow $Kind
    Update-WkStressButtons
}

function Complete-WkStressUi($S) {
    $k = $global:WkState.currentKind
    if (-not $k) { return }
    $global:WkState.stress[$k] = @{ result = [string]$S.status; errors = $S.errors; detail = $S.detail; error = $S.error; seconds = $S.seconds }
    if ($S.status -eq 'completed') { Invoke-WkSound 'test_done' }
    Invoke-DokiEvent 'stressDone' @{ result = [string]$S.status }
    Write-WkLog ('stress {0} finished: {1} {2} {3}' -f $k, $S.status, $S.detail, $S.error)
    $global:WkState.currentKind = $null
    $global:WkState.stopping = $false
    Update-WkStressRow $k
    if ($S.status -eq 'stopped') { $global:WkState.queue = @() }
    Set-WkDirty
    if (@($global:WkState.queue).Count -gt 0) {
        $next = $global:WkState.queue[0]
        $global:WkState.queue = @($global:WkState.queue | Select-Object -Skip 1)
        Start-WkStressUi $next
    } else { Stop-WkTempSampler }
    Update-WkStressButtons
}

function Update-WkStressPoll {
    $k = $global:WkState.currentKind
    if (-not $k) { return }
    if ($global:WkTempSync) { $global:WkState.temp = $global:WkTempSync.temp }
    $s = Get-WkStressState
    if (-not $s) { return }
    if ($s.status -eq 'running') { Update-WkStressRow $k $s } else { Complete-WkStressUi $s }
}

function Stop-WkStressUi {
    $global:WkState.queue = @()
    if (-not $global:WkState.currentKind) { return }
    $global:WkState.stopping = $true
    Stop-WkStress            # signal only: Update-WkStressPoll completes the row when the workers have stopped
    Update-WkStressRow $global:WkState.currentKind
    Update-WkStressButtons
}

# ---------------- report screen + save (2.6.0, #3 + #6) ----------------

function Get-WkCurrentVerdict {
    return Get-WkVerdict -Checks $global:WkState.checks -Stress $global:WkState.stress -Rules (Get-WkRules)
}

function Update-WkReportScreen {
    $v = Get-WkCurrentVerdict
    $st = $v.overall.status
    $pal = $global:WkPalette[$st]
    $global:WkUi.VerdictBox.Background = Get-WkBrush $pal.fill
    $global:WkUi.VerdictText.Foreground = Get-WkBrush $pal.fg
    $key = @{ green = 'report.ok'; amber = 'report.check'; red = 'report.bad' }[$st]
    $global:WkUi.VerdictText.Text = $pal.icon + '  ' + (T $key)
    $list = $global:WkUi.VerdictReasons
    $list.Children.Clear()
    $reasons = @($v.overall.reasons)
    if ($reasons.Count -eq 0) { [void]$list.Children.Add((New-WkLine (T 'report.allGood') 'C.Text' 16)) }
    foreach ($r in $reasons) {
        [void]$list.Children.Add((New-WkLine ([string][char]0x2022 + ' ' + (Format-WkReason $r)) $global:WkPalette[$r.status].fg 16))
    }
    $g = Get-WkGradeSafe $global:WkState.checks $global:WkState.stress $v
    if ($g) {
        $global:WkUi.GradeTag.Background = Get-WkBrush (Get-WkGradeColor $g.grade)
        $global:WkUi.GradeTagText.Text = $g.grade
        $global:WkUi.GradeDescText.Text = T ('grade.desc.' + (Get-WkGradeKeyId $g.grade))
        $sc = T 'grade.screenScore' $g.score; if (-not $g.complete) { $sc += ' *' }
        $global:WkUi.GradeScoreText.Text = $sc
        $global:WkUi.GradeTag.ToolTip = Get-WkGradeLine $g
        $global:WkUi.GradeTag.Visibility = 'Visible'
    } else { $global:WkUi.GradeTag.Visibility = 'Collapsed' }
    # 2.7.0: warranty return banner (org feature)
    $war = Get-WkWarrantySafe $g $global:WkState.checks
    if ($war -and $war.reject) { $global:WkUi.WarrantyText.Text = T 'warranty.reasons' (Format-WkWarrantyReasons $war); $global:WkUi.WarrantyBox.Visibility = 'Visible' }
    else { $global:WkUi.WarrantyBox.Visibility = 'Collapsed' }
    Update-WkCosmeticBox $war
    Invoke-DokiEvent 'report' @{ status = $st; count = $reasons.Count }
}

# 2.9.0: technician's decision on sticker residue / scratches (org feature "warranty"). Shown while a cosmetic defect is selected.
function Update-WkCosmeticBox($War) {
    $u = $global:WkUi
    Set-WkVisible $u.CosmeticBox ([bool]($War -and $War.cosmetic))
    $d = [string]$global:WkState.checks.cosmeticDecision
    foreach ($p in @(@($u.BtnCosReject, 'reject', 'C.Red.Fg'), @($u.BtnCosAccept, 'accept', 'C.Green.Fg'))) {
        if ($d -eq $p[1]) { $p[0].Background = Get-WkBrush $p[2]; $p[0].Foreground = Get-WkBrush 'C.White' }
        else { $p[0].Background = Get-WkBrush 'C.Surface'; $p[0].Foreground = Get-WkBrush 'C.Text' }
    }
}

function Set-WkCosmeticDecision([string]$Value) {
    $global:WkState.checks.cosmeticDecision = $Value
    $global:WkUi.ReportError.Visibility = 'Collapsed'
    Update-WkReportScreen
    Set-WkDirty
}

# Rules before saving (org): a cosmetic defect must be decided, a rejected device needs the technician's comment.
function Test-WkSaveAllowed {
    $u = $global:WkUi
    $u.ReportError.Visibility = 'Collapsed'
    if (-not (Test-WkFeature 'warranty')) { return $true }
    $g = Get-WkGradeSafe $global:WkState.checks $global:WkState.stress (Get-WkCurrentVerdict)
    $war = Get-WkWarrantySafe $g $global:WkState.checks
    if (-not $war) { return $true }
    $msg = ''
    if ($war.cosmeticPending) { $msg = T 'warranty.needDecision' }
    elseif ($war.reject -and -not $u.TxtNotes.Text.Trim()) {
        $o = Get-WkOrg; $req = $true; if ($o -and $o.warranty -and $null -ne $o.warranty.requireComment) { $req = [bool]$o.warranty.requireComment }
        if ($req) { $msg = T 'warranty.needComment'; [void]$u.TxtNotes.Focus() }
    }
    if ($msg) { $u.ReportError.Text = $msg; $u.ReportError.Visibility = 'Visible'; return $false }
    return $true
}

function Update-WkSaveButtons {
    $u = $global:WkUi
    if (-not $u.BtnSave) { return }
    $s = Get-WkSaveButtonState ([bool]$global:WkState.reportPath) ([bool]$global:WkState.dirty) ([bool]$global:WkState.saving)
    $style = 'Secondary'; if ($s.primary) { $style = 'Primary' }
    $u.BtnSave.Style = $global:WkWindow.FindResource($style)
    $u.BtnSave.SetResourceReference([System.Windows.FrameworkElement]::HeightProperty, 'PrimaryHeight')
    $u.BtnSave.Content = T $s.key
    $u.BtnSave.IsEnabled = $s.enabled
    Set-WkVisible $u.BtnNew $s.showNew
    if ($s.showNew) { $u.BtnSave.Margin = '0,0,12,0' } else { $u.BtnSave.Margin = '0' }
}

function Save-WkReportUi {
    if ($global:WkState.saving) { return }
    if (-not (Test-WkSaveAllowed)) { return }
    # Snapshot the state for the background save (the UI may keep changing it).
    $checks = $global:WkState.checks.Clone()
    foreach ($k in @('manual', 'diskManual', 'manualProgress')) { if ($checks[$k] -is [hashtable]) { $checks[$k] = $checks[$k].Clone() } }
    $stress = $global:WkState.stress.Clone()
    $v = Get-WkCurrentVerdict
    $l = $global:WkState.login
    $who = ''; $role = 'staff'; $sid = ''
    if ($l.role -eq 'guest') { $role = 'guest'; $who = $global:WkUi.TxtGuestName.Text.Trim() }
    else { $who = Get-WkStaffDisplayName $l.id; $sid = [string]$l.id }
    $p = @{ Checks = $checks; Stress = $stress; Verdict = $v; Technician = $who; Asset = $global:WkUi.TxtAsset.Text.Trim(); Notes = $global:WkUi.TxtNotes.Text
            Open = (-not $env:DOKI_SMOKE); Role = $role; StaffId = $sid }
    if ($global:WkState.reportInfo) { $p.Existing = @{ path = [string]$global:WkState.reportInfo.path; root = [string]$global:WkState.reportInfo.root } }
    if ((Test-WkFeature 'contractorLabel') -and $l.id -eq 'contractor') { $p.Summary = $true }   # 2.7.0: one-page summary to print
    $global:WkState.saving = $true
    $global:WkState.dirty = $false
    if (-not (Start-WkTask 'saveReport' 'saveReport' @(, $p) $global:WkReportModules)) { $global:WkState.saving = $false }
    Update-WkSaveButtons
    Update-WkStepper
}

function Complete-WkSaveUi($Out) {
    $u = $global:WkUi
    $global:WkState.saving = $false
    if (-not $Out.ok) {
        Write-WkLog ('report save failed: ' + [string]$Out.error) 'ERROR'
        $global:WkState.dirty = $true
        $u.SavedText.Text = T 'report.saveFailed' ([string]$Out.error)
        $u.SavedBox.Visibility = 'Visible'
        Update-WkSaveButtons; Update-WkStepper
        return
    }
    $first = -not $global:WkState.reportPath
    if (-not $global:WkState.checks.system -and $Out.system) { $global:WkState.checks.system = $Out.system }
    $global:WkState.reportPath = [string]$Out.path
    $global:WkState.reportInfo = $Out.last
    $global:WkLastReport = $Out.last
    $global:WkState.reportRev++
    if ($Out.last -and $Out.last.updated) { $u.SavedText.Text = T 'report.updated' $Out.path }
    elseif ($Out.last -and $Out.last.fallback) { $u.SavedText.Text = T 'report.savedFallback' $Out.last.intended $Out.path }
    else { $u.SavedText.Text = T 'report.saved' $Out.path }
    if ($first) { Invoke-WkSound 'report_saved' }
    # Jira: status is always shown (2.8.0); automatic send when configured.
    $base = Get-WkJiraBaseState
    if ($base -eq 'waiting') { Send-WkReportToJira }   # -> sending -> sent / partial / failed ("Update report" re-attaches the file)
    elseif ($global:WkJira.state -notin @('sent', 'partial', 'failed')) { Set-WkJiraState $base }
    $u.SavedBox.Visibility = 'Visible'
    Set-WkVisible $u.BtnPrintSummary ([bool]($Out.last -and $Out.last.summary))
    Update-WkDeployCard
    if ($first) { Start-WkFollowUp; Invoke-DokiEvent 'saved'; Invoke-DokiDeployStep }
    Update-WkSaveButtons
    Update-WkStepper
    if ($global:WkFinWin) { if ($first) { Show-WkFinish } else { Update-WkFinishContent } }
}

function Reset-WkForNewDevice {
    $u = $global:WkUi
    Clear-WkStress
    Stop-WkTempSampler
    Stop-WkBackground
    $global:WkSync = $null
    $global:WkState.checks = @{}; $global:WkState.stress = @{}; $global:WkState.queue = @(); $global:WkState.currentKind = $null
    $global:WkState.checksStarted = $null; $global:WkState.reportPath = $null; $global:WkState.reportInfo = $null
    $global:WkState.dirty = $false; $global:WkState.saving = $false; $global:WkState.reportRev = 0; $global:WkState.stopping = $false
    $global:WkState.reached = @{ ScreenHome = $true }; $global:WkState.expand = @{}
    $global:WkJiraSentRev = $null; $global:WkJiraSendingRev = $null; $global:WkJiraIssueKey = $null
    if ($global:WkFinWin -and $global:WkFinWin.IsVisible) { $global:WkFinWin.Hide() }
    $global:DokiState.checksAnnounced = $false
    $u.TxtAsset.Text = ''; $u.TxtNotes.Text = ''
    $u.SavedBox.Visibility = 'Collapsed'
    $u.DupBanner.Visibility = 'Collapsed'
    $u.BtnJira.Visibility = 'Collapsed'
    $u.BtnPrintSummary.Visibility = 'Collapsed'
    $u.WarrantyBox.Visibility = 'Collapsed'
    $u.FollowCard.Visibility = 'Collapsed'
    $global:WkState.follow = $null
    $global:WkState.diskManualOpen = $false
    $global:WkState.deploy = $null
    $u.DepStatus.Children.Clear()
    $u.DevDetails.Children.Clear()
    $u.TxtGuestName.Text = ''
    $u.ManualPanel.Children.Clear()
    $u.DiskManualPanel.Children.Clear()
    $u.DeviceLine.Text = ''
    foreach ($k in $global:WkStressKinds) { Update-WkStressRow $k }
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) { Update-WkCard $k }
    Update-WkStressButtons
    Update-WkSaveButtons
    $global:WkJira = @{ state = 'off'; key = ''; url = ''; error = '' }; Set-WkJiraState (Get-WkJiraBaseState)
    Show-WkScreen 'ScreenHome'
}

# ---------------- window size + compact layout (2.6.0, #7) ----------------

function Update-WkCompact {
    $w = $global:WkWindow
    $c = Get-WkCompactMode $w.ActualWidth $w.ActualHeight
    $prev = $global:WkCompact
    $global:WkCompact = $c
    if ($prev -and $prev.short -eq $c.short -and $prev.narrow -eq $c.narrow) { return }
    # ::new (not New-Object): a PSObject-wrapped Thickness in a ResourceDictionary fails later with InvalidCastException.
    $r = $w.Resources
    if ($c.short) {
        $r['H1Size'] = [double]22; $r['PrimaryHeight'] = [double]46
        $r['CardPad'] = [System.Windows.Thickness]::new(14); $r['CardMargin'] = [System.Windows.Thickness]::new(5)
    } else {
        $r['H1Size'] = [double]26; $r['PrimaryHeight'] = [double]56
        $r['CardPad'] = [System.Windows.Thickness]::new(20); $r['CardMargin'] = [System.Windows.Thickness]::new(8)
    }
    if ($global:DokiState.ready -and -not $global:DokiState.muted) { Move-DokiTo ([string]$global:DokiState.host) }
}

# ---------------- edition (2.6.0, #14) ----------------

function Initialize-WkEdition {
    $u = $global:WkUi
    $ed = Get-WkEdition
    Set-WkVisible $u.FooterBar ([bool]$ed.features.footerCredit)
    $u.FooterVersion.Text = 'Doki v' + $global:WkVersion
    if (-not (Test-WkFeature 'deploy')) { $u.DeployCard.Visibility = 'Collapsed' }
    if (-not (Test-WkFeature 'jira')) { $u.BtnJira.Visibility = 'Collapsed' }
    Write-WkLog ('edition ' + $ed.edition + ': ' + ((@($global:WkFeatureNames | Where-Object { Test-WkFeature $_ })) -join ','))
}

# ---------------- window ----------------

function Start-WkUi {
    $xamlPath = Join-Path $global:WkApp 'ui\MainWindow.xaml'
    $xamlText = [IO.File]::ReadAllText($xamlPath, [Text.Encoding]::UTF8)
    $global:WkWindow = [Windows.Markup.XamlReader]::Parse($xamlText)
    foreach ($m in [regex]::Matches($xamlText, 'x:Name="(\w+)"')) {
        $n = $m.Groups[1].Value
        $global:WkUi[$n] = $global:WkWindow.FindName($n)
    }
    $u = $global:WkUi
    try { $ip = Join-Path $global:WkApp 'ui\app.ico'; if (Test-Path -LiteralPath $ip) { $global:WkWindow.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$ip) } } catch { }
    # Fit the screen work area (1366x768 at 125% is only ~574 DIP high) (#7).
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $sz = Get-WkWindowSize $wa.Width $wa.Height
        $global:WkWindow.Width = $sz.width; $global:WkWindow.Height = $sz.height
        $global:WkWindow.MinWidth = [math]::Min(800, $sz.width); $global:WkWindow.MinHeight = [math]::Min(540, $sz.height)
    } catch { }

    # Remembered staff member + language (portable: config\last.json beside the app)
    $lang = $global:WkLang
    try {
        $lastPath = Join-Path $global:WkRoot 'config\last.json'
        if (Test-Path -LiteralPath $lastPath) {
            $last = Read-WkJson $lastPath
            if ($last.lang) { $lang = [string]$last.lang }
            $global:DokiStartMuted = [bool]$last.dokiMuted
            $global:DokiLastDay = [string]$last.dokiDay
            if ($last.staffId -and @((Get-WkStaff) | Where-Object { [string]$_.id -eq [string]$last.staffId }).Count -gt 0) {
                $global:WkState.login = @{ role = 'staff'; id = [string]$last.staffId; name = $null }
            }
        }
    } catch { }

    if (-not (Test-WkAdmin)) { $u.BannerNoAdmin.Visibility = 'Visible' }

    $u.TxtAsset.Add_TextChanged({ Invoke-WkUiSafe { Update-WkHomeButtons; if ($global:WkState.screen -eq 'ScreenHome') { Invoke-DokiLogin }; if ($global:WkState.reportPath) { Set-WkDirty } } })
    $u.TxtNotes.Add_TextChanged({ Invoke-WkUiSafe { Set-WkDirty } })
    $u.BtnDokiMute.Add_Click({ Invoke-WkUiSafe { Set-DokiMuted (-not $global:DokiState.muted); Save-WkLast; if (-not $global:DokiState.muted) { Update-DokiForScreen $global:WkState.screen } } })
    # WPF synthesizes MouseMove when an element (e.g. Doki's idle bob) moves under a still cursor: count only real pointer moves.
    $global:WkWindow.Add_PreviewMouseMove({ param($s, $e)
        $pt = $e.GetPosition($global:WkWindow)
        $lp = $global:DokiLastPoint
        if ($lp -and [math]::Abs($pt.X - $lp.X) -lt 1 -and [math]::Abs($pt.Y - $lp.Y) -lt 1) { return }
        $global:DokiLastPoint = $pt
        Register-DokiInput })
    $global:WkWindow.Add_PreviewMouseDown({ Register-DokiInput })
    $global:WkWindow.Add_PreviewKeyDown({ Register-DokiInput })
    $global:WkWindow.Add_SizeChanged({ Invoke-WkUiSafe { Update-WkCompact } })
    $u.CmbLogin.Add_SelectionChanged({ Invoke-WkUiSafe { if (-not $global:WkLoginBuilding -and $global:WkUi.CmbLogin.SelectedItem) { Select-WkLogin ([string]$global:WkUi.CmbLogin.SelectedItem.DataContext) } } })
    $u.TxtGuestName.Add_TextChanged({ Invoke-WkUiSafe { Update-WkRoleLine; Update-WkHomeButtons; $global:DokiGuestTimer.Stop(); $global:DokiGuestTimer.Start() } })
    # Greet the guest by name ~800 ms after the last keystroke (never a half-typed name).
    $global:DokiGuestTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:DokiGuestTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $global:DokiGuestTimer.Add_Tick({ Invoke-WkUiSafe { $global:DokiGuestTimer.Stop(); if ($global:WkState.screen -eq 'ScreenHome' -and $global:WkState.login.role -eq 'guest') { $global:DokiState.lastAt = [DateTime]::MinValue; Invoke-DokiLogin } } })
    $u.BtnLang.Add_Click({ Invoke-WkUiSafe { if ($global:WkLang -eq 'fa') { Set-WkUiLanguage 'en' } else { Set-WkUiLanguage 'fa' } } })
    $u.BtnStart.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenChecks'; Start-WkChecks; Update-WkStepper; Save-WkLast } })
    $u.BtnStressOnly.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenStress' } })
    $u.BtnChecksBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenHome' } })
    $u.BtnRecheck.Add_Click({ Invoke-WkUiSafe { Start-WkChecks; Update-WkStepper } })
    $u.BtnToStress.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenStress' } })
    $u.DrvAction.Add_Click({ Invoke-WkUiSafe { Start-Process 'devmgmt.msc' } })
    $u.UpdAction.Add_Click({ Invoke-WkUiSafe { Start-Process 'ms-settings:windowsupdate' } })
    $u.ChipBat.Add_Click({ Invoke-WkUiSafe { $global:WkUi.BatCard.BringIntoView() } })
    $u.ChipDisk.Add_Click({ Invoke-WkUiSafe { $global:WkUi.DiskCard.BringIntoView() } })
    $u.ChipDrv.Add_Click({ Invoke-WkUiSafe { $global:WkUi.DrvCard.BringIntoView() } })
    $u.ChipUpd.Add_Click({ Invoke-WkUiSafe { $global:WkUi.UpdCard.BringIntoView() } })
    foreach ($sn in $global:WkStepNames.Values) {
        $u[$sn].Add_Click({ param($s, $e) Invoke-WkUiSafe { if ($s.DataContext -and [string]$s.DataContext -ne $global:WkState.screen) { Show-WkScreen ([string]$s.DataContext) } } })
    }
    $u.CpuStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'cpu' } })
    $u.RamStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'ram' } })
    $u.DiskStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'disk' } })
    $u.GpuStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'gpu' } })
    $u.BtnRunAll.Add_Click({ Invoke-WkUiSafe { $global:WkState.queue = @('ram', 'disk', 'gpu'); Start-WkStressUi 'cpu' } })
    $u.BtnStop.Add_Click({ Invoke-WkUiSafe { Stop-WkStressUi } })
    $u.BtnStressBack.Add_Click({ Invoke-WkUiSafe { if ($global:WkState.checksStarted) { Show-WkScreen 'ScreenChecks' } else { Show-WkScreen 'ScreenHome' } } })
    $u.BtnToReport.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenManual' } })
    $u.BtnManualBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenStress' } })
    $u.BtnManualNext.Add_Click({ Invoke-WkUiSafe { Confirm-WkManualNext } })
    $u.BtnReportBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenManual' } })
    $u.BtnHistory.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenHistory' } })
    $u.BtnHistoryBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenHome' } })
    $u.BtnHistoryOpen.Add_Click({ Invoke-WkUiSafe { Open-WkHistorySelected } })
    $u.BtnHistoryFolder.Add_Click({ Invoke-WkUiSafe { Open-WkHistoryFolder } })
    $u.HistoryList.Add_MouseDoubleClick({ Invoke-WkUiSafe { Open-WkHistorySelected } })
    $u.HistoryList.Add_KeyDown({ param($s, $e) Invoke-WkUiSafe { if ($e.Key -eq 'Return') { Open-WkHistorySelected } } })
    $u.HistoryList.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{ param($s, $e) Invoke-WkUiSafe { Invoke-WkHistorySort $e.OriginalSource } })
    $u.TxtHistorySearch.Add_TextChanged({ Invoke-WkUiSafe { Update-WkHistory } })
    $u.CmbHistoryVerdict.Add_SelectionChanged({ Invoke-WkUiSafe { if (-not $global:WkHistoryBuilding) { Update-WkHistory } } })
    $u.CmbHistoryRange.Add_SelectionChanged({ Invoke-WkUiSafe { if (-not $global:WkHistoryBuilding) { Update-WkHistory } } })
    $u.BtnSave.Add_Click({ Invoke-WkUiSafe { Save-WkReportUi } })
    $u.BtnOpenFolder.Add_Click({ Invoke-WkUiSafe { if ($global:WkState.reportPath) { Start-Process 'explorer.exe' ('/select,"' + $global:WkState.reportPath + '"') } } })
    $u.BtnNew.Add_Click({ Invoke-WkUiSafe { Reset-WkForNewDevice } })
    $u.BtnAbout.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenAbout' } })
    $u.BtnAboutHome.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenAbout' } })
    $u.BtnAboutBack.Add_Click({ Invoke-WkUiSafe { $back = $global:WkState.prevScreen; if (-not $back) { $back = 'ScreenHome' }; Show-WkScreen $back } })
    $u.BtnCopy.Add_Click({ Invoke-WkUiSafe { Copy-WkReportUi } })
    $u.BtnPrintSummary.Add_Click({ Invoke-WkUiSafe { Open-WkSummaryPage } })
    $u.BtnFinPrintSummary.Add_Click({ Invoke-WkUiSafe { Open-WkSummaryPage } })
    $u.BtnFinOpenReport.Add_Click({ Invoke-WkUiSafe { $p = [string]$global:WkState.reportPath; if ($p -and (Test-WkReportPathSafe $p)) { Start-Process -FilePath $p } } })
    $u.BtnFinOpenFolder.Add_Click({ Invoke-WkUiSafe { if ($global:WkState.reportPath) { Start-Process 'explorer.exe' ('/select,"' + $global:WkState.reportPath + '"') } } })
    $u.BtnCosReject.Add_Click({ Invoke-WkUiSafe { Set-WkCosmeticDecision 'reject' } })
    $u.BtnCosAccept.Add_Click({ Invoke-WkUiSafe { Set-WkCosmeticDecision 'accept' } })
    $u.BtnFinNext.Add_Click({ Invoke-WkUiSafe { Hide-WkFinish $true } })
    $u.BtnFinBack.Add_Click({ Invoke-WkUiSafe { Hide-WkFinish $false } })
    $u.BtnJiraRetry.Add_Click({ Invoke-WkUiSafe { Invoke-WkJiraRetry } })
    $u.BtnFinJiraRetry.Add_Click({ Invoke-WkUiSafe { Invoke-WkJiraRetry } })
    $u.BtnJiraOpen.Add_Click({ Invoke-WkUiSafe { Open-WkJiraIssue } })
    $u.BtnFinJiraOpen.Add_Click({ Invoke-WkUiSafe { Open-WkJiraIssue } })
    if (Test-WkFeature 'settings') {
        $u.BtnSettings.Visibility = 'Visible'
        $u.BtnSettings.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenSettings' } })
        $u.BtnSettingsBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenHome' } })
        $u.BtnSettingsSave.Add_Click({ Invoke-WkUiSafe { Save-WkSettingsUi } })
        $u.BtnSettingsReset.Add_Click({ Invoke-WkUiSafe { Reset-WkSettingsUi } })
    }
    $u.BtnFollowYes.Add_Click({ Invoke-WkUiSafe { Submit-WkFollowUp $true } })
    $u.BtnFollowNo.Add_Click({ Invoke-WkUiSafe { Submit-WkFollowUp $false } })
    # Organization-only actions are wired only when their feature/module is present (2.6.0, D-034).
    if (Test-WkFeature 'contacts') {
        $u.AboutMailQc.Add_Click({ Invoke-WkUiSafe { $o = Get-WkOrg; if ($o -and $o.contacts.qcOwner) { Start-Process ('mailto:' + [string]$o.contacts.qcOwner) } } })
        $u.AboutMailSupport.Add_Click({ Invoke-WkUiSafe { $o = Get-WkOrg; if ($o -and $o.contacts.support) { Start-Process ('mailto:' + [string]$o.contacts.support) } } })
    }
    if (Test-WkFeature 'github') {
        $u.BtnGitHub.Add_Click({ Invoke-WkUiSafe { $o = Get-WkOrg; if ($o -and (Test-WkHttpsUrl ([string]$o.githubUrl))) { Start-Process ([string]$o.githubUrl) } } })
    }
    if (Test-WkFeature 'updater') {
        $u.BtnUpdateCheck.Add_Click({ Invoke-WkUiSafe { $global:WkUi.BtnUpdateCheck.IsEnabled = $false; $global:WkUi.AboutUpdateStatus.Text = T 'update.checking'; [void](Start-WkTask 'updateCheck' 'updateCheck' @() $global:WkUpdateModules) } })
        $u.BtnUpdateInstall.Add_Click({ Invoke-WkUiSafe { if ($global:DokiUpdateInfo -and $global:DokiUpdateInfo.available) { $global:WkUi.BtnUpdateInstall.IsEnabled = $false; $global:WkUi.AboutUpdateStatus.Text = T 'update.downloading'; [void](Start-WkTask 'updateDownload' 'updateDownload' @(, $global:DokiUpdateInfo) $global:WkUpdateModules) } } })
    }
    if (Test-WkFeature 'jira') {
        $u.BtnJiraTest.Add_Click({ Invoke-WkUiSafe { $global:WkUi.BtnJiraTest.IsEnabled = $false; $global:WkUi.AboutJiraResult.Text = T 'jira.testing'; [void](Start-WkTask 'jiraTest' 'jiraTest' @() $global:WkJiraModules) } })
        $u.BtnJira.Add_Click({ Invoke-WkUiSafe { Send-WkReportToJira } })
    }
    if (Test-WkFeature 'deploy') {
        foreach ($pf in (Get-WkNamePrefixes)) { [void]$u.CmbPrefix.Items.Add($pf) }
        if ($u.CmbPrefix.Items.Count -gt 0) { $u.CmbPrefix.SelectedIndex = 0 }
        $u.CmbPrefix.Add_SelectionChanged({ Invoke-WkUiSafe { Update-WkDeployCard } })
        $u.BtnRename.Add_Click({ Invoke-WkUiSafe { Invoke-WkRenameUi } })
        $u.BtnInstallEdr.Add_Click({ Invoke-WkUiSafe { Invoke-WkInstallEdrUi } })
        $u.BtnRestart.Add_Click({ Invoke-WkUiSafe { Invoke-WkRestartUi } })
    }

    $global:WkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:WkTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $global:WkTick = 0
    $global:WkTimer.Add_Tick({ Invoke-WkUiSafe {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Update-WkChecksPoll; Update-WkStressPoll; Update-WkTasksPoll
        if (Test-WkFeature 'deploy') { Update-WkDeployPoll }
        Update-DokiTick
        $global:WkTick++
        $scr = $global:WkState.screen
        if (($global:WkTick % 2) -eq 0 -and ($scr -eq 'ScreenStress' -or $scr -eq 'ScreenChecks')) { Update-WkMonitorUi }
        # 2.6.0 (#3): make UI-thread stalls visible in the log.
        if ($sw.ElapsedMilliseconds -gt 150) { Write-WkLog ('slow ui tick: ' + $sw.ElapsedMilliseconds + ' ms on ' + $scr) 'WARN' }
    } })

    # A launcher with a hidden/minimized console can pass that state to the first window: always open normal and in front.
    $global:WkWindow.Add_Loaded({ Invoke-WkUiSafe { $global:WkWindow.WindowState = 'Normal'; [void]$global:WkWindow.Activate(); Update-WkCompact } })
    $global:WkWindow.Add_Closing({ Invoke-WkUiSafe { $global:WkFinAllowClose = $true; if ($global:WkFinWin) { $global:WkFinWin.Close() }; $global:WkTimer.Stop(); Stop-DokiAll; Stop-WkMicMeter; Clear-WkStress; Stop-WkTempSampler; Stop-WkMonitorSampler; Stop-WkBackground; Write-WkLog 'window closed' } })

    Initialize-WkEdition
    try { Initialize-WkFinishWindow } catch { Write-WkLog ('finish window init failed: ' + $_.Exception.Message) 'WARN' }
    Set-WkJiraState (Get-WkJiraBaseState)
    try { Start-WkMonitorSampler } catch { Write-WkLog ('monitor sampler failed: ' + $_.Exception.Message) 'WARN' }
    Invoke-WkUiSafe { Initialize-Doki }
    Set-WkUiLanguage $lang
    foreach ($k in $global:WkStressKinds) { Update-WkStressRow $k }
    Update-WkStressButtons
    Show-WkScreen 'ScreenHome'
    $global:WkTimer.Start()
    if (Test-WkFeature 'updater') {
        try { $uc = Get-DokiUpdateConfig; if ($uc -and $uc.enabled -and $uc.checkOnStart) { [void](Start-WkTask 'updateCheck' 'updateCheck' @() $global:WkUpdateModules) } } catch { }
    }
    Write-WkLog 'ui shown'
    if ($global:WkUiHook) { & $global:WkUiHook }   # tests\Ui-Smoke.ps1 drives the window from here
    [void]$global:WkWindow.ShowDialog()
}
