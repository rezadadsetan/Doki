# WPF UI (D-006): STA main thread, background runspaces for checks, a 500 ms DispatcherTimer that only polls shared state.
# Event handlers are plain script blocks that call functions defined here (no GetNewClosure: it would hide script-scope functions).

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'ManualTests.ps1')
. (Join-Path $PSScriptRoot 'Doki.ps1')

$global:WkUi = @{}
$global:WkBg = @()
$global:WkState = @{
    screen = 'ScreenHome'; checks = @{}; stress = @{}; queue = @(); currentKind = $null
    checksStarted = $null; lastTempAt = [DateTime]::MinValue; temp = $null; reportPath = $null
    login = @{ role = $null; id = $null; name = $null }   # role: staff | guest
}
$global:WkPalette = @{
    green = @{ fill = '#EBFBF4'; border = '#BDEFD5'; fg = '#04A85A'; icon = [string][char]0x2713 }
    amber = @{ fill = '#FFF1E8'; border = '#FFD2B8'; fg = '#E0560F'; icon = '!' }
    red   = @{ fill = '#FDECEC'; border = '#F6C2C4'; fg = '#E5484D'; icon = [string][char]0x2715 }
    grey  = @{ fill = '#F4F5F8'; border = '#EBECF2'; fg = '#6B7080'; icon = [string][char]0x2013 }
    busy  = @{ fill = '#FFFFFF'; border = '#EBECF2'; fg = '#028EF9'; icon = [string][char]0x2026 }
}
$global:WkBrushConv = New-Object System.Windows.Media.BrushConverter

function Get-WkBrush([string]$Hex) { return $global:WkBrushConv.ConvertFromString($Hex) }

function Invoke-WkUiSafe([scriptblock]$Body) {
    try { & $Body } catch { Write-WkLog ('ui error: ' + $_.Exception.ToString() + ' at ' + $_.InvocationInfo.PositionMessage) 'ERROR' }
}

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
    if ($global:WkState.screen -eq 'ScreenReport') { Update-WkDeployCard }
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) { Update-WkCard $k }
    foreach ($k in $global:WkStressKinds) { Update-WkStressRow $k }
    if ($global:WkState.screen -eq 'ScreenReport') { Update-WkReportScreen }
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

function Show-WkScreen([string]$Name) {
    if ($Name -eq 'ScreenAbout' -and $global:WkState.screen -ne 'ScreenAbout') { $global:WkState.prevScreen = $global:WkState.screen }
    foreach ($s in @('ScreenHome', 'ScreenChecks', 'ScreenStress', 'ScreenManual', 'ScreenReport', 'ScreenHistory', 'ScreenAbout')) {
        if ($s -eq $Name) { $global:WkUi[$s].Visibility = 'Visible' } else { $global:WkUi[$s].Visibility = 'Collapsed' }
    }
    $global:WkState.screen = $Name
    if ($Name -eq 'ScreenAbout') { Update-WkAbout }
    if ($Name -eq 'ScreenStress') { Update-WkSpeakerRow }
    if ($Name -eq 'ScreenManual' -and $global:WkUi.ManualPanel.Children.Count -eq 0) { Build-WkManualPanel }
    if ($Name -eq 'ScreenManual') { Start-WkMicMeter } else { Stop-WkMicMeter }   # Phase 11: live mic level only while the checklist is open
    if ($Name -eq 'ScreenReport') { Update-WkReportScreen; Update-WkDeployCard }
    if ($Name -eq 'ScreenHistory') { $global:WkHistoryRows = $null; Update-WkHistory }
    Update-DokiForScreen $Name
}

# ---------------- Doki hooks (Phase 8) ----------------

function Invoke-DokiLogin {
    $l = $global:WkState.login
    $name = ''
    if ($l.role -eq 'staff') { $name = ([string](Get-WkStaffDisplayName $l.id)).Trim().Split(' ')[0] }   # first name is friendlier
    elseif ($l.role -eq 'guest') { $gn = $global:WkUi.TxtGuestName.Text.Trim(); if ($gn) { $name = $gn.Split(' ')[0] } }   # Phase 9: guest says hello by name
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
function Invoke-DokiDeployStep { return }

# ---------------- device facts card + live monitor (Phase 6) ----------------

function Update-WkDeviceCard {
    $p = $global:WkUi.DevDetails
    $p.Children.Clear()
    $res = $global:WkState.checks.device
    if (-not $res) { [void]$p.Children.Add((New-WkLine (T 'common.checking') '#028EF9' 14)); return }
    if (-not $res.ok) { [void]$p.Children.Add((New-WkLine ((T 'common.couldNotCheck') + ': ' + [string]$res.error) '#6B7080' 13)); return }
    foreach ($r in (Get-WkDeviceRows $res.data)) {
        $g = New-Object System.Windows.Controls.DockPanel
        $l = New-WkLine ([string]$r[0]) '#6B7080' 14
        $l.Width = 210; [System.Windows.Controls.DockPanel]::SetDock($l, 'Left')
        $vv = New-WkLine ([string]$r[1]) '#252A3C' 14 $true
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
        $c = '#06D170'; if ($b.Value -ge 90) { $c = '#E5484D' } elseif ($b.Value -ge 70) { $c = '#FF661F' }
        $b.Foreground = Get-WkBrush $c
    }
    $strip = 'CPU ' + $s.cpu + '%   |   RAM ' + $s.ram + '%   |   Disk ' + $s.disk + '%'
    if ($null -ne $global:WkState.temp) { $strip += '   |   ' + $global:WkState.temp + [char]0x00B0 + 'C' }
    $u.MonStrip.Text = $strip
}

# ---------------- deployment: rename -> EDR -> restart (Phase 6, D-025) ----------------

function Get-WkDeployTargetName { return $null }

function Add-WkDeployLog([string]$Text, [string]$Color = '#252A3C') {
    if (-not $global:WkState.deploy) { $global:WkState.deploy = @{ log = @() } }
    $global:WkState.deploy.log += ((Get-Date).ToString('HH:mm') + ' ' + $Text)
    $global:WkState.checks.deploy = $global:WkState.deploy
    [void]$global:WkUi.DepStatus.Children.Add((New-WkLine $Text $Color 14 $true))
}

function Update-WkDeployCard { $global:WkUi.DeployCard.Visibility="Collapsed" }

function Invoke-WkRenameUi { return }

function Invoke-WkInstallEdrUi { return }

function Update-WkDeployPoll { return }

function Invoke-WkRestartUi { return }

# ---------------- background tasks (Jira calls etc.; polled by the timer) ----------------

$global:WkTasks = @{}
$global:WkTaskScript = @'
param($mods, $app, $root, $lang, $what, $a1, $a2, $a3)
$global:WkApp = $app; $global:WkRoot = $root
foreach ($m in $mods) { . $m }
Set-WkLanguage $lang
try {
    if ($what -eq 'jiraTest') { Test-WkSupportConnection }          # Phase 9: support connector (servicedesk / jira / webhook)
    elseif ($what -eq 'jiraSend') { Send-WkSupportTicket $a1 }
    elseif ($what -eq 'updateCheck') { Get-DokiLatestRelease }
    elseif ($what -eq 'updateDownload') { Save-DokiUpdate $a1 }
} catch { @{ ok = $false; error = $_.Exception.Message } }
'@

function Start-WkTask([string]$Name, [string]$What, [object[]]$TaskArgs = @()) {
    if ($global:WkTasks.ContainsKey($Name)) { return }
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($global:WkTaskScript).AddArgument(@($global:WkModules)).AddArgument($global:WkApp).AddArgument($global:WkRoot).AddArgument($global:WkLang).AddArgument($What)
    foreach ($a in @($TaskArgs + @($null, $null, $null))[0..2]) { [void]$ps.AddArgument($a) }
    $global:WkTasks[$Name] = @{ ps = $ps; h = $ps.BeginInvoke(); rs = $rs }
}

function Update-WkTasksPoll {
    foreach ($name in @($global:WkTasks.Keys)) {
        $t = $global:WkTasks[$name]
        if (-not $t.h.IsCompleted) { continue }
        $out = $null
        try { $out = @($t.ps.EndInvoke($t.h)) | Select-Object -Last 1 } catch { $out = @{ ok = $false; error = $_.Exception.Message } }
        try { $t.ps.Dispose(); $t.rs.Dispose() } catch { }
        $global:WkTasks.Remove($name)
        if ($name -eq 'jiraTest') {
            if ($out.ok) { $global:WkUi.AboutJiraResult.Text = T 'jira.ok' $out.user; $global:WkUi.AboutJiraResult.Foreground = Get-WkBrush '#04A85A' }
            else { Write-WkLog ([string]$out.error) 'ERROR'; $global:WkUi.AboutJiraResult.Text = T 'jira.connectionFailed'; $global:WkUi.AboutJiraResult.Foreground = Get-WkBrush '#E5484D' }
            $global:WkUi.BtnJiraTest.IsEnabled = $true
        }
        if ($name -eq 'jiraSend') {
            $global:WkJiraSendingReportPath = $null
            $global:WkUi.SavedText.Text = T 'report.saved' ([string]$global:WkState.reportPath)
            if ($out.ok) { $global:WkJiraSentReportPath = [string]$global:WkState.reportPath; $global:WkJiraPendingKey = $null; $global:WkUi.SavedText.Text = $global:WkUi.SavedText.Text + "`r`n" + (T 'jira.sent' ($out.key + ' ' + $out.url)) }
            else {
                if ($out.partial -and $out.key) { $global:WkJiraPendingKey = [string]$out.key }
                Write-WkLog ([string]$out.error) 'ERROR'
                $message = T 'jira.sendFailed'
                if ($out.partial -and $out.key) { $message = T 'jira.attachmentFailed' ([string]$out.key) }
                $global:WkUi.SavedText.Text += "`r`n" + $message
            }
            $global:WkUi.BtnJira.IsEnabled = -not [bool]$out.ok
        }
        if ($name -eq 'updateCheck') {
            $global:WkUi.BtnUpdateCheck.IsEnabled = $true
            $global:DokiUpdateInfo = $out
            if ($out.ok -and $out.available) { $global:WkUi.AboutUpdateStatus.Text = T 'update.available' $out.version; $global:WkUi.BtnUpdateInstall.Visibility = 'Visible' }
            elseif ($out.ok) { $global:WkUi.AboutUpdateStatus.Text = T 'update.current'; $global:WkUi.BtnUpdateInstall.Visibility = 'Collapsed' }
            elseif ($out.status -eq 'disabled') { $global:WkUi.AboutUpdateStatus.Text = T 'update.disabled' }
            else { $global:WkUi.AboutUpdateStatus.Text = T 'update.unavailable' }
        }
        if ($name -eq 'updateDownload') {
            $global:WkUi.BtnUpdateInstall.IsEnabled = $true
            if ($out.ok) {
                $global:WkUi.AboutUpdateStatus.Text = T 'update.ready' $out.version
                $answer = [System.Windows.MessageBox]::Show((T 'update.confirm' $out.version), (T 'update.title'), 'YesNo', 'Question')
                if ($answer -eq 'Yes') { Start-DokiUpdateInstall $out; $global:WkWindow.Close() }
            } else { $global:WkUi.AboutUpdateStatus.Text = T 'update.failed' $out.error }
        }
    }
}

# ---------------- About (Phase 4) ----------------

function Update-WkAbout {
    $b = $global:WkBuild
    $global:WkUi.AboutVersion.Text = (T 'about.version') + ': ' + $global:WkVersion
    $date = [string]$b.buildDate
    if (-not $date) {
        $date = (Get-Item -LiteralPath (Join-Path $global:WkApp 'main.ps1')).LastWriteTime.ToString('yyyy-MM-dd') + ' - ' + (T 'about.dev')
    }
    $bt = (T 'about.buildDate') + ': ' + $date
    if ($b.commit) { $bt += '   |   ' + (T 'about.build') + ': ' + [string]$b.commit }
    $global:WkUi.AboutBuild.Text = $bt
    if (-not $global:WkUi.AboutUpdateStatus.Text) { $global:WkUi.AboutUpdateStatus.Text = T 'update.notChecked' }
    $global:WkUi.AboutConfig.Text = (Join-Path $global:WkRoot 'config')
    $roots = @()
    try {
        $p = (Get-WkRules).paths
        $roots += ('Staff: ' + [Environment]::ExpandEnvironmentVariables([string]$p.staff_root))
        $roots += ('Guest: ' + [Environment]::ExpandEnvironmentVariables([string]$p.guest_root))
    } catch { }
    $global:WkUi.AboutReports.Text = ($roots -join "`r`n")
    $global:WkUi.AboutSoundsHint.Text = T 'about.soundsHint' (Get-WkSoundDir)
    $sp = $global:WkUi.AboutSounds; $sp.Children.Clear()
    foreach ($n in $global:WkSoundNames) {
        if (Get-WkSoundFile $n) { [void]$sp.Children.Add((New-WkLine (T 'about.soundFound' $n) '#04A85A' 13)) }
        else { [void]$sp.Children.Add((New-WkLine (T 'about.soundMissing' $n) '#6B7080' 13)) }
    }
    $jt = Test-WkSupportConfig
    if (-not $jt.enabled) { $global:WkUi.AboutJiraStatus.Text = T 'jira.disabled'; $global:WkUi.BtnJiraTest.IsEnabled = $false }
    elseif (-not $jt.ok) { $global:WkUi.AboutJiraStatus.Text = T 'jira.incomplete' ($jt.missing -join ', '); $global:WkUi.BtnJiraTest.IsEnabled = $false }
    else { $c = Get-WkSupportConfig; $global:WkUi.AboutJiraStatus.Text = T 'jira.enabled' $c.baseUrl $c.mode; $global:WkUi.BtnJiraTest.IsEnabled = $true }
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

# ---------------- follow-up after saving (Phase 9): still a problem? -> tell Bimax? ----------------

function Get-WkFollowConfig { return @{enabled=$false} }

function Start-WkFollowUp { return }

function Update-WkFollowUp { return }

function Submit-WkFollowUp { return }

function Copy-WkReportUi {
    $txt = Get-WkCurrentReportText
    [System.Windows.Clipboard]::SetText($txt)
    $global:WkUi.SavedText.Text = T 'report.copied'
    $global:WkUi.SavedBox.Visibility = 'Visible'
}

function Send-WkReportToJira { return }

# ---------------- speaker test (Phase 4): writes the checklist "speakers" item ----------------

function Update-WkSpeakerRow {
    $val = $null; if ($global:WkState.checks.manual) { $val = $global:WkState.checks.manual['speakers'] }
    $st = 'grey'; if ($val -eq 'ok') { $st = 'green' } elseif ($val -eq 'fail') { $st = 'red' }
    $global:WkUi.SpkCard.Background = Get-WkBrush $global:WkPalette[$st].fill
    $global:WkUi.SpkCard.BorderBrush = Get-WkBrush $global:WkPalette[$st].border
    if ($val -eq 'ok') { $global:WkUi.SpkOk.Background = Get-WkBrush '#06D170'; $global:WkUi.SpkOk.Foreground = Get-WkBrush '#FFFFFF' } else { $global:WkUi.SpkOk.Background = Get-WkBrush '#FFFFFF'; $global:WkUi.SpkOk.Foreground = Get-WkBrush '#252A3C' }
    if ($val -eq 'fail') { $global:WkUi.SpkFail.Background = Get-WkBrush '#E5484D'; $global:WkUi.SpkFail.Foreground = Get-WkBrush '#FFFFFF' } else { $global:WkUi.SpkFail.Background = Get-WkBrush '#FFFFFF'; $global:WkUi.SpkFail.Foreground = Get-WkBrush '#252A3C' }
    # Phase 11: same gate as the checklist row (OK after a test sound played to the end)
    $gate = Get-WkManualGate 'speakers' $global:WkState.checks.manualProgress (Get-WkRules)
    $global:WkUi.SpkOk.IsEnabled = ($gate.ok -or $val -eq 'ok'); $global:WkUi.SpkFail.IsEnabled = ($gate.fail -or $val -eq 'fail')
    foreach ($b in @($global:WkUi.SpkOk, $global:WkUi.SpkFail)) { if ($b.IsEnabled) { $b.Opacity = 1.0 } else { $b.Opacity = 0.4 } }
}

function Set-WkSpeakerResult([string]$Value) {
    Set-WkManualValue 'speakers' $Value
    Update-WkSpeakerRow
}

# ---------------- history (P1) + duplicate guard (P1) ----------------

function Get-WkVerdictWord([string]$Status) {
    $k = @{ green = 'report.ok'; amber = 'report.check'; red = 'report.bad' }[$Status]
    if ($k) { return (T $k) }
    return $Status
}

function Update-WkHistory {
    if ($null -eq $global:WkHistoryRows) { $global:WkHistoryRows = @(Get-WkReportIndexRows) }
    $q = $global:WkUi.TxtHistorySearch.Text.Trim()
    $list = $global:WkUi.HistoryList
    $list.Items.Clear()
    $shown = 0
    foreach ($r in $global:WkHistoryRows) {
        if ($q -and -not (([string]$r.asset) -like ('*' + $q + '*') -or ([string]$r.serial) -like ('*' + $q + '*'))) { continue }
        $who = [string]$r.staff; if ($r.role -eq 'guest') { $who = T 'role.guest' }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $tb = New-Object System.Windows.Controls.TextBlock
        $asset = [string]$r.asset; if (-not $asset) { $asset = '-' }
        # RLM marks around separators keep each Latin field in its own place inside an RTL line (else serial/model/asset merge into one LTR run).
        $sep = '   |   '; if (Test-WkRtl) { $sep = [string][char]0x200F + '   |   ' + [char]0x200F }
        $tb.Text = (@([string]$r.date, $who, $asset, [string]$r.model, [string]$r.serial, (Get-WkVerdictWord ([string]$r.verdict))) -join $sep)
        $tb.Padding = '8,8'; $tb.TextWrapping = 'Wrap'
        $st = [string]$r.verdict; if (-not $global:WkPalette.ContainsKey($st)) { $st = 'grey' }
        $tb.Foreground = Get-WkBrush $global:WkPalette[$st].fg
        $item.Content = $tb
        $item.DataContext = [string]$r.report_path
        $item.Name = 'HistRow' + $shown
        [void]$list.Items.Add($item)
        $shown++
        if ($shown -ge 50) { break }
    }
    if ($shown -eq 0) { [void]$list.Items.Add((New-WkLine (T 'history.empty') '#6B7080' 15)) }
}

function Open-WkHistorySelected {
    $it = $global:WkUi.HistoryList.SelectedItem
    if ($it -is [System.Windows.Controls.ListBoxItem] -and $it.DataContext) {
        # Security (Phase 10): index.csv is an editable file, so only a local, existing .html report is opened, never an exe/script/UNC path.
        $p = [string]$it.DataContext
        if (Test-WkReportPathSafe $p) { Start-Process -FilePath $p } else { Write-WkLog ('history: refused to open ' + $p) 'WARN' }
    }
}

function Test-WkDuplicate {
    $global:WkUi.DupBanner.Visibility = 'Collapsed'
    $asset = $global:WkUi.TxtAsset.Text.Trim()
    $serial = ''
    if ($global:WkState.checks.system -and $global:WkState.checks.system.ok) { $serial = [string]$global:WkState.checks.system.data.serial }
    $hit = Find-WkSameDayReport @(Get-WkReportIndexRows) $asset $serial ((Get-Date).ToString('yyyy-MM-dd'))
    if ($hit) {
        $who = [string]$hit.staff; if ($hit.role -eq 'guest') { $who = T 'role.guest' }
        $global:WkUi.DupText.Text = T 'dup.warn' (([string]$hit.date) + ', ' + $who)
        $global:WkUi.DupBanner.Visibility = 'Visible'
        Invoke-DokiEvent 'duplicate'
    }
}

# ---------------- login (MUST-1): staff avatar cards from config\staff.json + guest ----------------

function Get-WkStaff { return @() }

function New-WkAvatarCard([string]$Id, [string]$Initials, [string]$Name, [string]$Color, [bool]$IsGuest) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $global:WkWindow.FindResource('AvatarCard')
    $btn.Name = 'Login_' + [regex]::Replace($Id, '[^A-Za-z0-9_]', '_')   # becomes the UI Automation id
    $btn.DataContext = $Id                                              # NOT Tag: Tag is reserved for i18n keys
    $sp = New-Object System.Windows.Controls.StackPanel
    $circle = New-Object System.Windows.Controls.Border
    $circle.Width = 58; $circle.Height = 58; $circle.CornerRadius = 29; $circle.HorizontalAlignment = 'Center'
    $txt = New-Object System.Windows.Controls.TextBlock
    $txt.HorizontalAlignment = 'Center'; $txt.VerticalAlignment = 'Center'; $txt.FontWeight = 'Bold'
    if ($IsGuest) {
        $circle.Background = Get-WkBrush '#FFF1E8'; $circle.BorderBrush = Get-WkBrush '#FF661F'; $circle.BorderThickness = 2
        $txt.FontFamily = 'Segoe MDL2 Assets'; $txt.Text = [string][char]0xE77B; $txt.FontSize = 28; $txt.Foreground = Get-WkBrush '#FF661F'
    } else {
        if (-not $Color) { $Color = '#06D170' }
        $circle.Background = Get-WkBrush $Color
        $txt.Text = $Initials; $txt.FontSize = 22; $txt.Foreground = Get-WkBrush '#FFFFFF'
    }
    $circle.Child = $txt
    $nm = New-Object System.Windows.Controls.TextBlock
    $nm.Text = $Name; $nm.TextWrapping = 'Wrap'; $nm.TextAlignment = 'Center'; $nm.HorizontalAlignment = 'Center'
    $nm.FontSize = 14; $nm.FontWeight = 'SemiBold'; $nm.Margin = '0,10,0,0'
    [void]$sp.Children.Add($circle); [void]$sp.Children.Add($nm)
    $btn.Content = $sp
    $btn.Add_Click({ param($s, $e) Invoke-WkUiSafe { Select-WkLogin ([string]$s.DataContext) } })
    return $btn
}

# Phase 5: login is a dropdown (user request). Items: staff from staff.json, then Guest. Item id lives in DataContext.
function Build-WkLoginCards { $global:WkUi.CmbLogin.Visibility = "Collapsed"; $global:WkState.login=@{role="guest";id="contractor"}; Update-WkHomeButtons }

function Update-WkLoginHighlight { return }

function Get-WkStaffDisplayName([string]$Id) {
    foreach ($p in (Get-WkStaff)) {
        if ([string]$p.id -eq $Id) {
            if (-not (Test-WkRtl) -and $p.nameEn) { return [string]$p.nameEn }
            return [string]$p.name
        }
    }
    return $Id
}

function Select-WkLogin([string]$Id) {
    $global:WkState.guestWelcomed = $false   # Phase 12: the welcome plays on "start", once per login / device
    if ($Id -in @('guest','contractor')) { $global:WkState.login = @{ role = 'guest'; id = $Id; name = $null } }
    else { $global:WkState.login = @{ role = 'staff'; id = $Id; name = (Get-WkStaffDisplayName $Id) } }
    Update-WkLoginHighlight
    Update-WkHomeButtons
    Update-WkRoleLine
    if ($global:WkState.screen -eq 'ScreenHome') { Invoke-DokiLogin }
}

# Phase 12: guest welcome sound (assets\sounds\guest_welcome.mp3) when a guest presses Start / Stress only.
function Invoke-WkGuestWelcome { return }

function Update-WkRoleLine {
    $l = $global:WkState.login
    if (-not $l.role) { $global:WkUi.RoleBox.Visibility = 'Collapsed'; return }
    if ($l.role -eq 'guest') {
        $t = T 'role.guest'
        if ($l.id -eq 'contractor') { $t = T 'login.contractor' }
        $gn = $global:WkUi.TxtGuestName.Text.Trim(); if ($gn) { $t += ' (' + $gn + ')' }
        $global:WkUi.RoleLine.Text = $t
        $global:WkUi.RoleBox.Background = Get-WkBrush '#FFF1E8'; $global:WkUi.RoleLine.Foreground = Get-WkBrush '#E0560F'
    } else {
        $l.name = Get-WkStaffDisplayName $l.id
        $global:WkUi.RoleLine.Text = T 'role.staff' $l.name
        $global:WkUi.RoleBox.Background = Get-WkBrush '#EBFBF4'; $global:WkUi.RoleLine.Foreground = Get-WkBrush '#04A85A'
    }
    $global:WkUi.RoleBox.Visibility = 'Visible'
}

function Save-WkLast {
    try {
        $last = @{ lang = $global:WkLang; staffId = $null; dokiMuted = [bool]$global:DokiState.muted; dokiDay = [string]$global:DokiLastDay }
        if ($global:WkState.login.role -eq 'staff') { $last.staffId = $global:WkState.login.id }
        Write-WkJson (Join-Path (Get-WkWritableDir 'config') 'last.json') $last
    } catch { }
}

function Update-WkHomeButtons {
    $role = $global:WkState.login.role
    $asset = $global:WkUi.TxtAsset.Text.Trim()
    $guestValid = ($global:WkUi.TxtGuestName.Text.Trim().Length -ge 2)
    $contractor = $global:WkState.login.id -eq 'contractor'
    if ($contractor) { $guestValid = $global:WkUi.TxtGuestName.Text.Trim().Length -ge 2 -and $asset -ne '' }
    $global:WkUi.GuestNamePanel.Children[0].Text = if ($contractor) { T 'login.contractorName' } else { T 'login.guestName' }
    $ok = (($role -eq 'staff') -and ($asset -ne '')) -or (($role -eq 'guest') -and $guestValid)
    $global:WkUi.GuestEmailError.Visibility = if ($role -eq 'guest' -and -not $contractor -and -not $guestValid) { 'Visible' } else { 'Collapsed' }
    $global:WkUi.BtnStart.IsEnabled = $ok
    $global:WkUi.BtnStressOnly.IsEnabled = $ok
    if ($ok) { $global:WkUi.HintFill.Visibility = 'Hidden' } else { $global:WkUi.HintFill.Visibility = 'Visible' }
    if ($role -eq 'guest') { $global:WkUi.GuestNamePanel.Visibility = 'Visible'; $global:WkUi.AssetHint.Visibility = 'Visible' }
    else { $global:WkUi.GuestNamePanel.Visibility = 'Collapsed'; $global:WkUi.AssetHint.Visibility = 'Collapsed' }
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
    # Phase 4: automatic health is the main path; the manual field is an optional override behind a link,
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
    if ($tb.Text.Trim() -and $null -eq (ConvertTo-WkPercent $tb.Text)) { $tb.BorderBrush = Get-WkBrush '#E5484D' } else { $tb.BorderBrush = Get-WkBrush '#DADCE5' }
    Update-WkCard 'disks'
}

function Update-WkDeviceLine {
    $sys = $global:WkState.checks.system
    if ($sys -and $sys.ok) {
        $d = $sys.data
        $global:WkUi.DeviceLine.Text = T 'checks.device' $d.manufacturer $d.model $d.serial
    }
}

function New-WkLine([string]$Text, [string]$Color = '#252A3C', [int]$Size = 14, [bool]$Bold = $false) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.TextWrapping = 'Wrap'; $tb.FontSize = $Size; $tb.Margin = '0,2,0,2'
    $tb.Foreground = Get-WkBrush $Color
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    return $tb
}

# ---------------- background checks ----------------

$global:WkBgScript = @'
param($sync, $mods, $app, $root, $which)
$global:WkApp = $app; $global:WkRoot = $root
foreach ($m in $mods) { . $m }
try {
    if ($which -eq 'main') {
        $sync.system = Get-WkSystemInfo
        $sync.battery = Get-WkBattery
        $sync.disks = Get-WkDisks
        $sync.drivers = Get-WkDriverProblems
        $sync.device = Get-WkDeviceFacts
    } else {
        $rules = Get-WkRules
        $sync.updates = Get-WkUpdates -TimeoutSec ([int]$rules.updates.search_timeout_seconds)
    }
} catch { $sync['error_' + $which] = $_.Exception.Message }
'@

function Start-WkChecks {
    Stop-WkBackground
    $global:WkSync = [hashtable]::Synchronized(@{})
    # Keep the technician's manual disk % across a re-check of the same device.
    $keepManual = $global:WkState.checks.diskManual
    $keepList = $global:WkState.checks.manual
    $global:WkState.checks = @{}
    if ($keepManual) { $global:WkState.checks.diskManual = $keepManual }
    if ($keepList) { $global:WkState.checks.manual = $keepList }
    $global:WkState.checksStarted = Get-Date
    $global:DokiState.checksAnnounced = $false
    Invoke-DokiEvent 'checksRunning' @{ admin = (Test-WkAdmin) }
    $global:WkUi.DiskManualPanel.Children.Clear()
    Update-WkDeviceCard
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) { Update-WkCard $k }
    foreach ($which in @('main', 'updates')) {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($global:WkBgScript).AddArgument($global:WkSync).AddArgument(@($global:WkModules)).AddArgument($global:WkApp).AddArgument($global:WkRoot).AddArgument($which)
        $h = $ps.BeginInvoke()
        $global:WkBg += @{ ps = $ps; handle = $h; rs = $rs }
    }
    Write-WkLog 'checks started'
}

function Stop-WkBackground {
    foreach ($b in $global:WkBg) {
        try { [void]$b.ps.BeginStop($null, $null) } catch { }
    }
    $global:WkBg = @()
}

function Update-WkChecksPoll {
    if (-not $global:WkSync -or -not $global:WkState.checksStarted) { return }
    if (-not $global:WkState.checks.ContainsKey('device') -and $global:WkSync.ContainsKey('device')) {
        $global:WkState.checks['device'] = $global:WkSync['device']; Update-WkDeviceCard
    }
    foreach ($k in @('system', 'battery', 'disks', 'drivers', 'updates')) {
        if (-not $global:WkState.checks.ContainsKey($k) -and $global:WkSync.ContainsKey($k)) {
            $global:WkState.checks[$k] = $global:WkSync[$k]
            if ($k -eq 'system') { Update-WkDeviceLine; Test-WkDuplicate } else { Update-WkCard $k }
            if ($k -eq 'disks') { Build-WkDiskManual }
        }
    }
    if (-not $global:DokiState.checksAnnounced -and @('battery', 'disks', 'drivers', 'updates' | Where-Object { $global:WkState.checks.ContainsKey($_) }).Count -eq 4) {
        $global:DokiState.checksAnnounced = $true
        Invoke-DokiEvent 'checksDone' @{ verdict = (Get-WkCurrentVerdict) }
    }
    $elapsed = ((Get-Date) - $global:WkState.checksStarted).TotalSeconds
    $limit = [int](Get-WkRules).updates.search_timeout_seconds + 45
    foreach ($k in @('battery', 'disks', 'drivers', 'updates')) {
        if (-not $global:WkState.checks.ContainsKey($k)) {
            $runError = $global:WkSync['error_main']
            if ($k -eq 'updates') { $runError = $global:WkSync['error_updates'] }
            if ($runError -or $elapsed -gt $limit) {
                if (-not $runError) { $runError = 'no answer after ' + [int]$elapsed + ' s' }
                $global:WkState.checks[$k] = @{ ok = $false; data = $null; error = $runError }
                Write-WkLog ('check ' + $k + ' gave up: ' + $runError) 'WARN'
            }
            Update-WkCard $k
        }
    }
}

# ---------------- cards ----------------

function Set-WkCard([string]$P, [string]$Status, [string]$Big, [string]$StatusText, [object[]]$Lines) {
    $pal = $global:WkPalette[$Status]
    $global:WkUi[$P + 'Card'].Background = Get-WkBrush $pal.fill
    $global:WkUi[$P + 'Card'].BorderBrush = Get-WkBrush $pal.border
    $global:WkUi[$P + 'Badge'].Background = Get-WkBrush $pal.fg
    $global:WkUi[$P + 'Icon'].Text = $pal.icon
    $global:WkUi[$P + 'Icon'].Foreground = Get-WkBrush '#FFFFFF'
    $global:WkUi[$P + 'Big'].Text = $Big
    if ($Big) { $global:WkUi[$P + 'Big'].Visibility = 'Visible' } else { $global:WkUi[$P + 'Big'].Visibility = 'Collapsed' }
    $global:WkUi[$P + 'Big'].Foreground = Get-WkBrush $pal.fg
    $global:WkUi[$P + 'Status'].Text = $StatusText
    $global:WkUi[$P + 'Status'].Foreground = Get-WkBrush $pal.fg
    $d = $global:WkUi[$P + 'Details']
    $d.Children.Clear()
    foreach ($l in @($Lines)) { if ($l) { [void]$d.Children.Add($l) } }
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
        Set-WkCard $P 'busy' '' (T 'common.checking') @((New-WkLine (T 'common.seconds' $secs) '#6B7080'))
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
                if ($d.designMWh -and $d.fullMWh) { $lines += New-WkLine ((T 'battery.design') + ' / ' + (T 'battery.full') + ': ' + ('{0:N1} / {1:N1} Wh' -f ($d.designMWh / 1000), ($d.fullMWh / 1000))) '#6B7080' }
            } elseif (-not $res.ok) { $lines += New-WkLine ([string]$res.error) '#6B7080' 12 }
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
            } else { $lines += New-WkLine ([string]$res.error) '#6B7080' 12 }
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
                $lines += New-WkLine (T 'drivers.other') '#6B7080' 13 $true
                foreach ($dv in @($v.info)) { $lines += New-WkLine ($dv.name + ' - ' + (Get-WkDriverMeaning $dv.code)) '#6B7080' 13 }
            }
            if (-not $res.ok) { $lines += New-WkLine ([string]$res.error) '#6B7080' 12 }
            $big = ''; if ($res.ok) { $big = [string]@($v.alarm).Count }
            Set-WkCard $P $v.status $big (Format-WkReason $v.reasons[0]) $lines
        }
        'updates' {
            $v = Get-WkUpdatesVerdict $res $rules
            $big = ''
            if ($res.ok -and $res.data.checked) {
                $big = [string]$res.data.pendingCount
                $titles = @($res.data.titles)
                for ($i = 0; $i -lt [math]::Min(5, $titles.Count); $i++) { $lines += New-WkLine ([string]$titles[$i]) '#252A3C' 13 }
                if ($titles.Count -gt 5) { $lines += New-WkLine (T 'updates.more' ($titles.Count - 5)) '#6B7080' 13 }
                if ($res.data.lastInstallDate) { $lines += New-WkLine (T 'updates.lastInstall' $res.data.lastInstallDate) '#6B7080' 13 }
            } elseif ($res.ok -and $res.data.error) { $lines += New-WkLine ([string]$res.data.error) '#6B7080' 12 }
            elseif (-not $res.ok) { $lines += New-WkLine ([string]$res.error) '#6B7080' 12 }
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
        'running'     { return (T 'stress.running') }
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
    if ($busy) { $global:WkUi.BtnStop.Visibility = 'Visible' } else { $global:WkUi.BtnStop.Visibility = 'Collapsed' }
}

function Start-WkStressUi([string]$Kind) {
    if ($global:WkState.currentKind) { return }
    $secs = Get-WkSelectedSeconds
    $s = Start-WkStress $Kind $secs
    $global:WkState.stress[$Kind] = @{ result = 'running'; seconds = $secs }
    $global:WkState.currentKind = $Kind
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
    Update-WkStressRow $k
    if ($S.status -eq 'stopped') { $global:WkState.queue = @() }
    if (@($global:WkState.queue).Count -gt 0) {
        $next = $global:WkState.queue[0]
        $global:WkState.queue = @($global:WkState.queue | Select-Object -Skip 1)
        Start-WkStressUi $next
    }
    Update-WkStressButtons
}

function Update-WkStressPoll {
    $k = $global:WkState.currentKind
    if (-not $k) { return }
    if (((Get-Date) - $global:WkState.lastTempAt).TotalSeconds -ge 5) {
        $global:WkState.lastTempAt = Get-Date
        $global:WkState.temp = Get-WkTemperature
    }
    $s = Get-WkStressState
    if (-not $s) { return }
    if ($s.status -eq 'running') { Update-WkStressRow $k $s } else { Complete-WkStressUi $s }
}

# ---------------- report screen ----------------

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
    if ($reasons.Count -eq 0) { [void]$list.Children.Add((New-WkLine (T 'report.allGood') '#252A3C' 16)) }
    foreach ($r in $reasons) {
        [void]$list.Children.Add((New-WkLine ([string][char]0x2022 + ' ' + (Format-WkReason $r)) $global:WkPalette[$r.status].fg 16))
    }
    # Phase 10: grade tag
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
    Invoke-DokiEvent 'report' @{ status = $st; count = $reasons.Count }
}

function Save-WkReportUi {
    $checks = $global:WkState.checks
    if (-not $checks.system) { $checks.system = Get-WkSystemInfo }
    $v = Get-WkCurrentVerdict
    $l = $global:WkState.login
    $who = ''; $role = 'staff'; $sid = ''
    if ($l.role -eq 'guest') { $role = 'guest'; $who = $global:WkUi.TxtGuestName.Text.Trim() }
    else { $who = Get-WkStaffDisplayName $l.id; $sid = [string]$l.id }
    $path = New-WkReport -Checks $checks -Stress $global:WkState.stress -Verdict $v -Technician $who -Asset $global:WkUi.TxtAsset.Text.Trim() -Notes $global:WkUi.TxtNotes.Text -Open:$true -Role $role -StaffId $sid
    $global:WkState.reportPath = $path
    if ($global:WkLastReport -and $global:WkLastReport.fallback) { $global:WkUi.SavedText.Text = T 'report.savedFallback' $global:WkLastReport.intended $path }
    else { $global:WkUi.SavedText.Text = T 'report.saved' $path }
    Invoke-WkSound 'report_saved'
    $supportTest = Test-WkSupportConfig
    if ($supportTest.ok -and $l.id -ne 'contractor') {
        $global:WkUi.BtnJira.Visibility = 'Visible'; $global:WkUi.BtnJira.IsEnabled = $true
        $supportConfig = Get-WkSupportConfig
        if ($supportConfig.autoSend) { $global:WkUi.SavedText.Text += "`r`n" + (T 'jira.autoSending'); Send-WkReportToJira }
    }
    $global:WkUi.SavedBox.Visibility = 'Visible'
    $global:WkUi.BtnNew.Visibility = 'Visible'      # Phase 9: "New device" only after the report is safely saved
    Update-WkDeployCard                              # Phase 11: device preparation appears only now
    Start-WkFollowUp
    Invoke-DokiEvent 'saved'
    Invoke-DokiDeployStep   # queued after the celebration (rate limit)
}

function Reset-WkForNewDevice {
    Clear-WkStress
    Stop-WkBackground
    $global:WkSync = $null
    $global:WkState.checks = @{}; $global:WkState.stress = @{}; $global:WkState.queue = @(); $global:WkState.currentKind = $null
    $global:WkState.checksStarted = $null; $global:WkState.reportPath = $null
    $global:WkJiraSentReportPath = $null; $global:WkJiraSendingReportPath = $null; $global:WkJiraPendingKey = $null
    $global:DokiState.checksAnnounced = $false
    $global:WkUi.TxtAsset.Text = ''; $global:WkUi.TxtNotes.Text = ''
    $global:WkUi.SavedBox.Visibility = 'Collapsed'
    $global:WkUi.DupBanner.Visibility = 'Collapsed'
    $global:WkUi.BtnJira.Visibility = 'Collapsed'
    $global:WkUi.BtnNew.Visibility = 'Collapsed'
    $global:WkUi.FollowCard.Visibility = 'Collapsed'
    $global:WkState.follow = $null
    $global:WkState.guestWelcomed = $false
    $global:WkState.diskManualOpen = $false
    $global:WkState.deploy = $null
    $global:WkUi.DepStatus.Children.Clear()
    $global:WkUi.DevDetails.Children.Clear()
    $global:WkUi.TxtGuestName.Text = ''
    $global:WkUi.ManualPanel.Children.Clear()
    $global:WkUi.DiskManualPanel.Children.Clear()
    foreach ($k in $global:WkStressKinds) { Update-WkStressRow $k }
    Update-WkStressButtons
    Show-WkScreen 'ScreenHome'
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

    $u.TxtAsset.Add_TextChanged({ Invoke-WkUiSafe { Update-WkHomeButtons; if ($global:WkState.screen -eq 'ScreenHome') { Invoke-DokiLogin } } })
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
    $u.CmbLogin.Add_SelectionChanged({ Invoke-WkUiSafe { if (-not $global:WkLoginBuilding -and $global:WkUi.CmbLogin.SelectedItem) { Select-WkLogin ([string]$global:WkUi.CmbLogin.SelectedItem.DataContext) } } })
    $u.SpkVideo.Add_Click({ Invoke-WkUiSafe { Invoke-WkSpeakerVideoUi } })
    $vf = Get-WkSoundFile 'speaker_test'
    if ($vf -and (Test-WkVideoFile $vf)) { $u.SpkVideo.Visibility = 'Visible' }
    $u.TxtGuestName.Add_TextChanged({ Invoke-WkUiSafe { Update-WkRoleLine; Update-WkHomeButtons; $global:DokiGuestTimer.Stop(); $global:DokiGuestTimer.Start() } })
    # Phase 9: greet the guest by name ~800 ms after the last keystroke (never a half-typed name).
    $global:DokiGuestTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:DokiGuestTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $global:DokiGuestTimer.Add_Tick({ Invoke-WkUiSafe { $global:DokiGuestTimer.Stop(); if ($global:WkState.screen -eq 'ScreenHome' -and $global:WkState.login.role -eq 'guest') { $global:DokiState.lastAt = [DateTime]::MinValue; Invoke-DokiLogin } } })
    $u.BtnLang.Add_Click({ Invoke-WkUiSafe { if ($global:WkLang -eq 'fa') { Set-WkUiLanguage 'en' } else { Set-WkUiLanguage 'fa' } } })
    $u.BtnStart.Add_Click({ Invoke-WkUiSafe { Invoke-WkGuestWelcome; Show-WkScreen 'ScreenChecks'; Start-WkChecks; Save-WkLast } })
    $u.BtnStressOnly.Add_Click({ Invoke-WkUiSafe { Invoke-WkGuestWelcome; Show-WkScreen 'ScreenStress' } })
    $u.BtnChecksBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenHome' } })
    $u.BtnRecheck.Add_Click({ Invoke-WkUiSafe { Start-WkChecks } })
    $u.BtnToStress.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenStress' } })
    $u.DrvAction.Add_Click({ Invoke-WkUiSafe { Start-Process 'devmgmt.msc' } })
    $u.UpdAction.Add_Click({ Invoke-WkUiSafe { Start-Process 'ms-settings:windowsupdate' } })
    $u.CpuStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'cpu' } })
    $u.RamStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'ram' } })
    $u.DiskStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'disk' } })
    $u.GpuStart.Add_Click({ Invoke-WkUiSafe { Start-WkStressUi 'gpu' } })
    $u.BtnRunAll.Add_Click({ Invoke-WkUiSafe { $global:WkState.queue = @('ram', 'disk', 'gpu'); Start-WkStressUi 'cpu' } })
    $u.BtnStop.Add_Click({ Invoke-WkUiSafe { $global:WkState.queue = @(); Stop-WkStress; Update-WkStressPoll } })
    $u.BtnStressBack.Add_Click({ Invoke-WkUiSafe { if ($global:WkState.checksStarted) { Show-WkScreen 'ScreenChecks' } else { Show-WkScreen 'ScreenHome' } } })
    $u.BtnToReport.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenManual' } })
    $u.BtnManualBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenStress' } })
    $u.BtnManualNext.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenReport' } })
    $u.BtnReportBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenManual' } })
    $u.BtnHistory.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenHistory' } })
    $u.BtnHistoryBack.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenHome' } })
    $u.BtnHistoryOpen.Add_Click({ Invoke-WkUiSafe { Open-WkHistorySelected } })
    $u.HistoryList.Add_MouseDoubleClick({ Invoke-WkUiSafe { Open-WkHistorySelected } })
    $u.TxtHistorySearch.Add_TextChanged({ Invoke-WkUiSafe { Update-WkHistory } })
    $u.BtnSave.Add_Click({ Invoke-WkUiSafe { Save-WkReportUi } })
    $u.BtnOpenFolder.Add_Click({ Invoke-WkUiSafe { if ($global:WkState.reportPath) { Start-Process 'explorer.exe' ('/select,"' + $global:WkState.reportPath + '"') } } })
    $u.BtnNew.Add_Click({ Invoke-WkUiSafe { Reset-WkForNewDevice } })

    $global:WkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $global:WkTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $u.BtnAbout.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenAbout' } })
    $u.BtnAboutHome.Add_Click({ Invoke-WkUiSafe { Show-WkScreen 'ScreenAbout' } })
    $u.BtnAboutBack.Add_Click({ Invoke-WkUiSafe { $back = $global:WkState.prevScreen; if (-not $back) { $back = 'ScreenHome' }; Show-WkScreen $back } })
    $u.BtnGitHub.Add_Click({ Invoke-WkUiSafe { Start-Process 'https://github.com/rezadadsetan/Doki' } })
    $u.BtnCopy.Add_Click({ Invoke-WkUiSafe { Copy-WkReportUi } })
    $u.BtnFollowYes.Add_Click({ Invoke-WkUiSafe { Submit-WkFollowUp $true } })
    $u.BtnFollowNo.Add_Click({ Invoke-WkUiSafe { Submit-WkFollowUp $false } })
    $u.SpkLeft.Add_Click({ Invoke-WkUiSafe { Invoke-WkSpeakerSide 'left' } })
    $u.SpkRight.Add_Click({ Invoke-WkUiSafe { Invoke-WkSpeakerSide 'right' } })
    $u.SpkBoth.Add_Click({ Invoke-WkUiSafe { Invoke-WkSpeakerSide 'both' } })
    $u.SpkOk.Add_Click({ Invoke-WkUiSafe { Set-WkSpeakerResult 'ok' } })
    $u.SpkFail.Add_Click({ Invoke-WkUiSafe { Set-WkSpeakerResult 'fail' } })

    if ($u.CmbPrefix.Items.Count -gt 0) { $u.CmbPrefix.SelectedIndex = 0 }
    $u.CmbPrefix.Add_SelectionChanged({ Invoke-WkUiSafe { Update-WkDeployCard } })

    $global:WkTick = 0
    $global:WkTimer.Add_Tick({ Invoke-WkUiSafe {
        Update-WkChecksPoll; Update-WkStressPoll; Update-WkTasksPoll; Update-WkDeployPoll; Update-DokiTick
        $global:WkTick++
        if (($global:WkTick % 2) -eq 0 -and ($global:WkState.screen -eq 'ScreenChecks' -or $global:WkState.screen -eq 'ScreenStress')) { Update-WkMonitorUi }
    } })

    # A launcher with a hidden/minimized console can pass that state to the first window: always open normal and in front.
    $global:WkWindow.Add_Loaded({ Invoke-WkUiSafe { $global:WkWindow.WindowState = 'Normal'; [void]$global:WkWindow.Activate() } })
    $global:WkWindow.Add_Closing({ Invoke-WkUiSafe { $global:WkTimer.Stop(); Stop-DokiAll; Stop-WkMicMeter; Clear-WkStress; Stop-WkBackground; Write-WkLog 'window closed' } })

    Invoke-WkUiSafe { Initialize-Doki }
    Set-WkUiLanguage $lang
    foreach ($k in $global:WkStressKinds) { Update-WkStressRow $k }
    Update-WkStressButtons
    Show-WkScreen 'ScreenHome'
    $global:WkTimer.Start()
    try { $uc = Get-DokiUpdateConfig; if ($uc -and $uc.enabled -and $uc.checkOnStart) { Start-WkTask 'updateCheck' 'updateCheck' } } catch { }
    Write-WkLog 'ui shown'
    [void]$global:WkWindow.ShowDialog()
}

function Get-WkPrimaryEmail { return '' }
