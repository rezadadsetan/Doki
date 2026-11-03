# Manual checklist screen (Phase 3, P1): rows with OK / Problem toggles, plus offline helpers:
# full-screen color test, on-screen keyboard tester, test sound, camera app, sound settings.
# Dot-sourced by Ui.ps1. Same rules: ASCII only, every handler wrapped in Invoke-WkUiSafe.

# ---------------- checklist rows ----------------

function Get-WkManualItems { return @((Get-WkRules).manual_checks | ForEach-Object { [string]$_ }) }

function New-WkToggle([string]$Name, [string]$Text, [string]$Item, [string]$Value) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $global:WkWindow.FindResource('Secondary')
    $b.Name = $Name; $b.Content = $Text; $b.Height = 42; $b.MinWidth = 110; $b.Margin = '6,0,0,0'; $b.FontSize = 15
    $b.DataContext = $Item + '|' + $Value
    $b.Add_Click({ param($s, $e) Invoke-WkUiSafe { $p = ([string]$s.DataContext).Split('|'); Set-WkManualValue $p[0] $p[1] } })
    return $b
}

function New-WkHelperButton([string]$Name, [string]$Text, [string]$Action) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $global:WkWindow.FindResource('Link')
    $b.Name = $Name; $b.Content = $Text; $b.Height = 36; $b.FontSize = 14; $b.HorizontalAlignment = 'Left'; $b.Padding = '0,0'
    $b.DataContext = $Action
    $b.Add_Click({ param($s, $e) Invoke-WkUiSafe { Invoke-WkManualHelper ([string]$s.DataContext) } })
    return $b
}

function Build-WkManualPanel {
    $panel = $global:WkUi.ManualPanel
    $panel.Children.Clear()
    if (-not $global:WkState.checks.manual) { $global:WkState.checks.manual = @{} }
    # Unary comma keeps one-pair lists nested (@(@(a,b)) would flatten to @(a,b)).
    $helpers = @{
        display = , @('testScreen', 'manual.testScreen')
        keyboard = , @('testKeyboard', 'manual.testKeyboard')
        speakers = @(@('playSound', 'manual.playSound'), @('openSound', 'manual.openSound'))
        microphone = , @('openSound', 'manual.openSound')
        camera = , @('openCamera', 'manual.openCamera')
    }
    foreach ($it in (Get-WkManualItems)) {
        $card = New-Object System.Windows.Controls.Border
        $card.Style = $global:WkWindow.FindResource('Card'); $card.Padding = '18,10'; $card.Margin = '8,4'
        $card.Name = 'ManCard_' + $it
        $g = New-Object System.Windows.Controls.Grid
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = '*'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
        $left = New-Object System.Windows.Controls.StackPanel
        $left.VerticalAlignment = 'Center'
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = T ('manual.' + $it); $lbl.FontSize = 17; $lbl.FontWeight = 'SemiBold'; $lbl.TextWrapping = 'Wrap'
        [void]$left.Children.Add($lbl)
        if ($helpers.ContainsKey($it)) {
            $hp = New-Object System.Windows.Controls.StackPanel; $hp.Orientation = 'Horizontal'
            foreach ($h in $helpers[$it]) { [void]$hp.Children.Add((New-WkHelperButton ('ManHelp_' + $it + '_' + $h[0]) (T $h[1]) $h[0])); $hp.Children[$hp.Children.Count - 1].Margin = '0,0,16,0' }
            [void]$left.Children.Add($hp)
        }
        if ($it -eq 'microphone') { [void]$left.Children.Add((New-WkMicMeterUi)) }
        # Phase 11: why OK / Problem are still locked
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Name = 'ManHint_' + $it; $hint.FontSize = 13; $hint.Foreground = Get-WkBrush '#E0560F'; $hint.TextWrapping = 'Wrap'; $hint.Visibility = 'Collapsed'
        [void]$left.Children.Add($hint)
        $right = New-Object System.Windows.Controls.StackPanel
        $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
        if ($it -eq 'physical') {
            # Phase 10: several conditions can be selected together ("healthy" is exclusive), see Grade.ps1.
            foreach ($o in @((Get-WkRules).grading.physical)) {
                $tb = New-WkToggle ('Man_physical_' + $o) (T ('manual.phys.' + $o)) 'physical' ([string]$o)
                $tb.MinWidth = 92; $tb.Padding = '10,0'
                [void]$right.Children.Add($tb)
            }
        } else {
            [void]$right.Children.Add((New-WkToggle ('Man_' + $it + '_ok') (T 'manual.ok') $it 'ok'))
            [void]$right.Children.Add((New-WkToggle ('Man_' + $it + '_fail') (T 'manual.fail') $it 'fail'))
        }
        [System.Windows.Controls.Grid]::SetColumn($left, 0); [System.Windows.Controls.Grid]::SetColumn($right, 1)
        [void]$g.Children.Add($left); [void]$g.Children.Add($right)
        $card.Child = $g
        [void]$panel.Children.Add($card)
    }
    Update-WkManualPanel
}

function Set-WkManualValue([string]$Item, [string]$Value) {
    if (-not $global:WkState.checks.manual) { $global:WkState.checks.manual = @{} }
    # Pressing the selected toggle again clears it (back to "not checked").
    if ($Item -eq 'physical') {
        $nv = Switch-WkPhysicalOption $global:WkState.checks.manual[$Item] $Value
        if ($nv) { $global:WkState.checks.manual[$Item] = $nv } else { $global:WkState.checks.manual[$Item] = $null }
    }
    elseif ($global:WkState.checks.manual[$Item] -eq $Value) { $global:WkState.checks.manual[$Item] = $null }
    else {
        # Phase 11: a result can only be chosen after the helper test (Get-WkManualGate); the buttons are disabled too.
        $gate = Get-WkManualGate $Item $global:WkState.checks.manualProgress (Get-WkRules)
        if (($Value -eq 'ok' -and -not $gate.ok) -or ($Value -eq 'fail' -and -not $gate.fail)) { return }
        $global:WkState.checks.manual[$Item] = $Value
    }
    Update-WkManualPanel
    # Doki (Phase 8): once every item has a value, point to the report.
    $open = @((Get-WkManualItems) | Where-Object { -not $global:WkState.checks.manual[$_] }).Count
    if ($open -eq 0 -and (Get-Command Invoke-DokiEvent -ErrorAction SilentlyContinue)) { Invoke-DokiEvent 'manualDone' }
}

function Update-WkManualPanel {
    $m = $global:WkState.checks.manual
    foreach ($card in $global:WkUi.ManualPanel.Children) {
        $it = ([string]$card.Name).Substring(8)
        $val = $null; if ($m) { $val = $m[$it] }
        $st = 'grey'; if ($val -eq 'ok') { $st = 'green' } elseif ($val -eq 'fail') { $st = 'red' }
        $right = $card.Child.Children[1]
        if ($it -eq 'physical') {
            $sel = @(ConvertTo-WkPhysicalList $val)
            $st = Get-WkPhysicalStatus $val; if (-not $st) { $st = 'grey' } elseif ($st -eq 'green' -and ($sel -notcontains 'ok')) { $st = 'amber' }
            $pal = $global:WkPalette[$st]
            $card.Background = Get-WkBrush $pal.fill; $card.BorderBrush = Get-WkBrush $pal.border
            foreach ($b in $right.Children) {
                $o = ([string]$b.Name).Substring(13)
                if ($sel -contains $o) {
                    $c = '#E0560F'; if ($o -eq 'ok') { $c = '#06D170' } elseif ($o -eq 'broken') { $c = '#E5484D' }
                    $b.Background = Get-WkBrush $c; $b.Foreground = Get-WkBrush '#FFFFFF'
                } else { $b.Background = Get-WkBrush '#FFFFFF'; $b.Foreground = Get-WkBrush '#252A3C' }
            }
            continue
        }
        $pal = $global:WkPalette[$st]
        $card.Background = Get-WkBrush $pal.fill; $card.BorderBrush = Get-WkBrush $pal.border
        $gate = Get-WkManualGate $it $global:WkState.checks.manualProgress (Get-WkRules)
        foreach ($b in $right.Children) {
            $isOk = ([string]$b.Name).EndsWith('_ok')
            $on = ($isOk -and $val -eq 'ok') -or (-not $isOk -and $val -eq 'fail')
            if ($on -and $isOk) { $b.Background = Get-WkBrush '#06D170'; $b.Foreground = Get-WkBrush '#FFFFFF' }
            elseif ($on) { $b.Background = Get-WkBrush '#E5484D'; $b.Foreground = Get-WkBrush '#FFFFFF' }
            else { $b.Background = Get-WkBrush '#FFFFFF'; $b.Foreground = Get-WkBrush '#252A3C' }
            $en = $gate.fail; if ($isOk) { $en = $gate.ok }
            $b.IsEnabled = ($en -or $on); if ($b.IsEnabled) { $b.Opacity = 1.0 } else { $b.Opacity = 0.4 }
        }
        $hint = $null; foreach ($c in $card.Child.Children[0].Children) { if ([string]$c.Name -eq ('ManHint_' + $it)) { $hint = $c } }
        if ($hint) {
            $hk = ''
            if (-not $val -and $gate.locked) { if ($gate.fail) { $hk = 'manual.lockedPartial' } else { $hk = 'manual.locked' } }
            if ($hk) { $hint.Text = T $hk; $hint.Visibility = 'Visible' } else { $hint.Visibility = 'Collapsed' }
        }
    }
}

# Phase 11: helper test progress per item ('started' | 'done'; never goes back from done).
function Set-WkManualProgress([string]$Item, [string]$State) {
    if (-not $global:WkState.checks.manualProgress) { $global:WkState.checks.manualProgress = @{} }
    $p = $global:WkState.checks.manualProgress
    if ($p[$Item] -eq 'done') { return }
    if ($p[$Item] -eq $State) { return }
    $p[$Item] = $State
    Write-WkLog ('manual test ' + $Item + ': ' + $State)
    if ($global:WkUi.ManualPanel.Children.Count -gt 0) { Update-WkManualPanel }
    if (Get-Command Update-WkSpeakerRow -ErrorAction SilentlyContinue) { Update-WkSpeakerRow }
}

# Speaker test from the checklist or the stress screen: started now, done when the test sound plays to its end.
function Invoke-WkSpeakerSide([string]$Side) {
    Set-WkManualProgress 'speakers' 'started'
    $global:WkMediaEnded = { Invoke-WkUiSafe { if ($global:WkMediaPurpose -eq 'speaker') { Set-WkManualProgress 'speakers' 'done' } } }
    Start-WkSpeakerTest $Side
}

function Invoke-WkSpeakerVideoUi {
    Set-WkManualProgress 'speakers' 'started'
    $global:WkMediaEnded = { Invoke-WkUiSafe { if ($global:WkMediaPurpose -eq 'speaker') { Set-WkManualProgress 'speakers' 'done' } } }
    $global:WkVideoEnded = $false
    Show-WkSpeakerVideo
    if ($global:WkVideoEnded) { Set-WkManualProgress 'speakers' 'done' }
}

# ---------------- live microphone level (Phase 11) ----------------

function New-WkMicMeterUi {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '0,6,0,2'
    $track = New-Object System.Windows.Controls.Border
    $track.Width = 280; $track.Height = 12; $track.CornerRadius = 6; $track.HorizontalAlignment = 'Left'
    $track.Background = Get-WkBrush '#E3E5EC'
    $fill = New-Object System.Windows.Controls.Border
    $fill.Width = 0; $fill.Height = 12; $fill.CornerRadius = 6; $fill.HorizontalAlignment = 'Left'; $fill.Background = Get-WkBrush '#9AA0B4'
    $track.Child = $fill
    $status = New-Object System.Windows.Controls.TextBlock
    $status.FontSize = 13; $status.Foreground = Get-WkBrush '#6B7080'; $status.Margin = '0,4,0,0'; $status.TextWrapping = 'Wrap'
    [void]$sp.Children.Add($track); [void]$sp.Children.Add($status)
    $global:WkMicFill = $fill; $global:WkMicStatus = $status; $global:WkMicTrack = $track
    return $sp
}

function Import-WkMicNative {
    if ('WonderKid.MicMeter' -as [type]) { return $true }
    if ((Import-WkNative) -and ('WonderKid.MicMeter' -as [type])) { return $true }
    try { Add-Type -Path (Join-Path $global:WkApp 'lib\MicNative.cs') -ErrorAction Stop; return $true } catch { Write-WkLog ('mic native load failed: ' + $_.Exception.Message) 'WARN'; return $false }
}

function Start-WkMicMeter {
    if (-not $global:WkMicFill) { return }
    if ($global:WkMicTimer -and $global:WkMicTimer.IsEnabled) { return }
    $global:WkMicVoice = 0; $global:WkMicShown = 0.0
    $ok = $false; $err = ''
    if (Import-WkMicNative) { $ok = [WonderKid.MicMeter]::Start(); $err = [string][WonderKid.MicMeter]::LastError } else { $err = 'native' }
    Set-WkManualProgress 'microphone' 'started'
    if (-not $ok) {
        $k = 'mic.error'; if ($err -eq 'nodevice') { $k = 'mic.noDevice' } elseif ($err -eq 'denied') { $k = 'mic.denied' }
        $global:WkMicStatus.Text = T $k $err; $global:WkMicStatus.Foreground = Get-WkBrush '#E5484D'
        Write-WkLog ('mic meter failed: ' + $err) 'WARN'
        return
    }
    $name = [string][WonderKid.MicMeter]::DeviceName
    Write-WkLog ('mic meter started: ' + $name)
    $global:WkMicDevice = $name
    Update-WkMicStatus
    if (-not $global:WkMicTimer) {
        $global:WkMicTimer = New-Object System.Windows.Threading.DispatcherTimer
        $global:WkMicTimer.Interval = [TimeSpan]::FromMilliseconds(80)
        $global:WkMicTimer.Add_Tick({ Invoke-WkUiSafe { Update-WkMicMeter } })
    }
    $global:WkMicTimer.Start()
}

function Update-WkMicStatus {
    $p = $null; if ($global:WkState.checks.manualProgress) { $p = $global:WkState.checks.manualProgress['microphone'] }
    if ($p -eq 'done') { $global:WkMicStatus.Text = T 'mic.heard' $global:WkMicDevice; $global:WkMicStatus.Foreground = Get-WkBrush '#04A85A' }
    else { $global:WkMicStatus.Text = T 'mic.listening' $global:WkMicDevice; $global:WkMicStatus.Foreground = Get-WkBrush '#6B7080' }
}

function Update-WkMicMeter {
    $peak = [double][WonderKid.MicMeter]::Peak()
    if ($peak -lt 0) { return }
    $cfg = (Get-WkRules).mic
    $thr = 0.03; $need = 6
    if ($cfg) { if ($cfg.voice_peak) { $thr = [double]$cfg.voice_peak }; if ($cfg.voice_samples) { $need = [int]$cfg.voice_samples } }
    # sqrt scale so quiet speech still moves the bar; fast attack, slow release like the Windows meter.
    $target = [math]::Min(1.0, [math]::Sqrt($peak))
    if ($target -gt $global:WkMicShown) { $global:WkMicShown = $target } else { $global:WkMicShown = [math]::Max($target, $global:WkMicShown * 0.82) }
    $w = $global:WkMicTrack.Width
    $global:WkMicFill.Width = [math]::Round($w * $global:WkMicShown)
    if ($peak -ge $thr) { $global:WkMicFill.Background = Get-WkBrush '#06D170'; $global:WkMicVoice++ } else { $global:WkMicFill.Background = Get-WkBrush '#9AA0B4' }
    if ($global:WkMicVoice -ge $need) {
        $before = $null; if ($global:WkState.checks.manualProgress) { $before = $global:WkState.checks.manualProgress['microphone'] }
        if ($before -ne 'done') { Set-WkManualProgress 'microphone' 'done'; Update-WkMicStatus }
    }
}

function Stop-WkMicMeter {
    if ($global:WkMicTimer) { $global:WkMicTimer.Stop() }
    if ('WonderKid.MicMeter' -as [type]) { try { [WonderKid.MicMeter]::Stop() } catch { } }
    if ($global:WkMicFill) { $global:WkMicFill.Width = 0 }
}

function Invoke-WkManualHelper([string]$Action) {
    switch ($Action) {
        'testScreen'   { Show-WkColorTest }
        'testKeyboard' { Show-WkKeyboardTest }
        'playSound'    { Invoke-WkSpeakerSide 'both' }
        'openCamera'   { Start-Process 'microsoft.windows.camera:'; Set-WkManualProgress 'camera' 'started' }
        'openSound'    { Start-Process 'ms-settings:sound' }
    }
}

# ---------------- full-screen color test ----------------

function Show-WkColorTest {
    $colors = @('#FFFFFF', '#000000', '#FF0000', '#00FF00', '#0000FF', '#808080')
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'; $w.WindowState = 'Maximized'; $w.Topmost = $true
    $w.Background = Get-WkBrush $colors[0]; $w.Cursor = [System.Windows.Input.Cursors]::None
    $w.Owner = $global:WkWindow
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = T 'manual.screenHint'; $hint.FontSize = 22; $hint.Foreground = Get-WkBrush '#808080'
    $hint.HorizontalAlignment = 'Center'; $hint.VerticalAlignment = 'Bottom'; $hint.Margin = '0,0,0,40'
    $w.Content = $hint
    $global:WkColorIndex = 0; $global:WkColorList = $colors; $global:WkColorWin = $w
    Set-WkManualProgress 'display' 'started'
    $next = {
        $global:WkColorIndex++
        if ($global:WkColorIndex -ge $global:WkColorList.Count) { Set-WkManualProgress 'display' 'done'; $global:WkColorWin.Close(); return }   # all colours seen (Esc = not finished)
        $global:WkColorWin.Background = Get-WkBrush $global:WkColorList[$global:WkColorIndex]
        $global:WkColorWin.Content = $null
    }
    $global:WkColorNext = $next
    $w.Add_MouseDown({ Invoke-WkUiSafe { & $global:WkColorNext } })
    $w.Add_KeyDown({ param($s, $e) Invoke-WkUiSafe { if ($e.Key -eq 'Escape') { $global:WkColorWin.Close() } else { & $global:WkColorNext } } })
    [void]$w.ShowDialog()
}

# ---------------- keyboard tester ----------------

function Show-WkKeyboardTest {
    $rows = @(
        @('Escape', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12', 'Delete'),
        @('Oem3', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'D8', 'D9', 'D0', 'OemMinus', 'OemPlus', 'Back'),
        @('Tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'Oem4', 'Oem6', 'Oem5'),
        @('Capital', 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'Oem1', 'Oem7', 'Return'),
        @('LeftShift', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', 'OemComma', 'OemPeriod', 'Oem2', 'RightShift'),
        @('LeftCtrl', 'LWin', 'LeftAlt', 'Space', 'RightAlt', 'RightCtrl', 'Left', 'Up', 'Down', 'Right')
    )
    $labels = @{ Escape = 'Esc'; Delete = 'Del'; Oem3 = '`'; OemMinus = '-'; OemPlus = '='; Back = 'Backspace'; Oem4 = '['; Oem6 = ']'; Oem5 = '\'
        Capital = 'Caps'; Oem1 = ';'; Oem7 = "'"; Return = 'Enter'; LeftShift = 'Shift'; RightShift = 'Shift'; OemComma = ','; OemPeriod = '.'; Oem2 = '/'
        LeftCtrl = 'Ctrl'; RightCtrl = 'Ctrl'; LWin = 'Win'; LeftAlt = 'Alt'; RightAlt = 'Alt'; Space = 'Space'
        Left = [string][char]0x2190; Up = [string][char]0x2191; Down = [string][char]0x2193; Right = [string][char]0x2192 }
    $wide = @{ Back = 2; Tab = 1.5; Capital = 1.8; Return = 2.2; LeftShift = 2.3; RightShift = 2.6; Space = 6; Oem5 = 1.5 }

    $w = New-Object System.Windows.Window
    $w.Title = T 'manual.kbTitle'; $w.Width = 1080; $w.Height = 520; $w.WindowStartupLocation = 'CenterOwner'
    $w.Owner = $global:WkWindow; $w.Background = Get-WkBrush '#F7F8FA'; $w.FontFamily = 'Segoe UI, Tahoma'
    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = '20'
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = T 'manual.kbHint'; $hint.FontSize = 16; $hint.Margin = '0,0,0,6'
    if (Test-WkRtl) { $hint.FlowDirection = 'RightToLeft' }
    $count = New-Object System.Windows.Controls.TextBlock
    $count.FontSize = 15; $count.FontWeight = 'SemiBold'; $count.Foreground = Get-WkBrush '#04A85A'; $count.Margin = '0,0,0,12'
    if (Test-WkRtl) { $count.FlowDirection = 'RightToLeft' }
    [void]$root.Children.Add($hint); [void]$root.Children.Add($count)

    $global:WkKbKeys = @{}   # [int]Key -> Border
    $total = 0
    foreach ($r in $rows) {
        $rp = New-Object System.Windows.Controls.StackPanel
        $rp.Orientation = 'Horizontal'; $rp.Margin = '0,3'; $rp.FlowDirection = 'LeftToRight'
        foreach ($k in $r) {
            $key = [System.Windows.Input.Key]$k
            $bd = New-Object System.Windows.Controls.Border
            $f = 1.0; if ($wide.ContainsKey($k)) { $f = [double]$wide[$k] }
            $bd.Width = 62 * $f; $bd.Height = 52; $bd.Margin = '3,0'; $bd.CornerRadius = 8
            $bd.Background = Get-WkBrush '#FFFFFF'; $bd.BorderBrush = Get-WkBrush '#DADCE5'; $bd.BorderThickness = 1.5
            $tx = New-Object System.Windows.Controls.TextBlock
            $lab = $k; if ($labels.ContainsKey($k)) { $lab = $labels[$k] } elseif ($k -match '^D\d$') { $lab = $k.Substring(1) }
            $tx.Text = $lab; $tx.FontSize = 15; $tx.HorizontalAlignment = 'Center'; $tx.VerticalAlignment = 'Center'
            $bd.Child = $tx
            [void]$rp.Children.Add($bd)
            $global:WkKbKeys[[int]$key] = $bd
            $total++
        }
        [void]$root.Children.Add($rp)
    }
    $done = New-Object System.Windows.Controls.Button
    $done.Style = $global:WkWindow.FindResource('Primary'); $done.Content = T 'manual.kbDone'; $done.Margin = '0,16,0,0'
    $done.HorizontalAlignment = 'Left'; $done.Focusable = $false; $done.Name = 'KbDone'
    [void]$root.Children.Add($done)
    $w.Content = $root

    $global:WkKbWin = $w; $global:WkKbCount = $count; $global:WkKbTotal = $total; $global:WkKbHit = @{}
    $count.Text = T 'manual.kbCount' 0 $total
    $done.Add_Click({ Invoke-WkUiSafe { $global:WkKbWin.Close() } })
    $mark = {
        param($e)
        $k = $e.Key
        if ($k -eq [System.Windows.Input.Key]::System) { $k = $e.SystemKey }   # Alt and F10 arrive as "System"
        $e.Handled = $true                                                     # keep Tab/Alt/arrows from moving focus or opening menus
        $id = [int]$k
        if ($global:WkKbKeys.ContainsKey($id)) {
            $b = $global:WkKbKeys[$id]
            $b.Background = Get-WkBrush '#06D170'; $b.BorderBrush = Get-WkBrush '#04A85A'; $b.Child.Foreground = Get-WkBrush '#FFFFFF'
            $global:WkKbHit[$id] = $true
            $global:WkKbCount.Text = T 'manual.kbCount' $global:WkKbHit.Count $global:WkKbTotal
        }
    }
    $global:WkKbMark = $mark
    $w.Add_PreviewKeyDown({ param($s, $e) Invoke-WkUiSafe { & $global:WkKbMark $e } })
    Set-WkManualProgress 'keyboard' 'started'   # Problem becomes possible (a dead key can never be pressed)
    [void]$w.ShowDialog()
    # A fully pressed keyboard marks the checklist item OK automatically (the technician can still change it).
    if ($global:WkKbHit.Count -ge $global:WkKbTotal) {
        Set-WkManualProgress 'keyboard' 'done'
        if (-not $global:WkState.checks.manual) { $global:WkState.checks.manual = @{} }; $global:WkState.checks.manual['keyboard'] = 'ok'; Update-WkManualPanel
    }
}
