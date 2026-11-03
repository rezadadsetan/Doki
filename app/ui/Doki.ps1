# Doki, the assistant mascot (Phase 8, D-026). Dot-sourced by Ui.ps1. ASCII only; all text comes from i18n keys "doki.*".
# One shared panel (DokiPanel) is re-parented between the Home host (large, beside the login card) and the side column (compact),
# so it never overlaps a card or a button. Everything is local and scripted: no network, no AI service.
#
# Pure functions (unit-tested, no WPF): Get-DokiPoseFile, Get-DokiGreetingKey, Get-DokiMessage, Get-DokiDecision, Test-DokiFlip.

$global:DokiPoseNames = @('hello', 'thinking', 'working', 'happy', 'concerned', 'celebrate', 'sleep', 'pointing')
$global:DokiState = @{
    mood = $null; host = 'home'; active = 'A'; muted = $false; sticky = $false
    lastKey = $null; lastArgs = @(); lastAt = [DateTime]::MinValue; queue = @(); shownAt = [DateTime]::MinValue
    lastInput = (Get-Date); sleeping = $false; checksAnnounced = $false; ready = $false
}
$global:DokiImages = @{}
$global:DokiAnim = @{}

# ---------------- config + pure helpers ----------------

function Get-DokiConfig {
    $c = @{ enabled = $true; animations = $true; splash = $false; poses = @{} }
    try {
        $d = (Get-WkRules).doki
        if ($d) {
            if ($null -ne $d.enabled) { $c.enabled = [bool]$d.enabled }
            if ($null -ne $d.animations) { $c.animations = [bool]$d.animations }
            if ($null -ne $d.splash) { $c.splash = [bool]$d.splash }
            if ($d.poses) { foreach ($p in $d.poses.PSObject.Properties) { $c.poses[$p.Name] = [string]$p.Value } }
        }
    } catch { }
    foreach ($m in $global:DokiPoseNames) { if (-not $c.poses.ContainsKey($m)) { $c.poses[$m] = 'pose_' + $m } }
    return $c
}

# mood -> file; missing pose -> doki_master.png; master missing -> $null (Doki is hidden). Never throws.
function Get-DokiPoseFile([string]$Mood, [switch]$Small, [string]$Dir = $null) {
    if (-not $Dir) { $Dir = Join-Path $global:WkRoot 'assets\doki' }
    $cfg = Get-DokiConfig
    $name = $cfg.poses[$Mood]
    if ($name) {
        $sub = $Dir; if ($Small) { $sub = Join-Path $Dir 'small' }
        $f = Join-Path $sub ($name + '.png')
        if (Test-Path -LiteralPath $f) { return $f }
        $f = Join-Path $Dir ($name + '.png')            # small missing -> large
        if (Test-Path -LiteralPath $f) { return $f }
    }
    $m = Join-Path $Dir 'doki_master.png'
    if (Test-Path -LiteralPath $m) { return $m }
    return $null
}

function Get-DokiGreetingKey([int]$Hour) {
    if ($Hour -ge 5 -and $Hour -lt 12) { return 'doki.greet.morning' }
    if ($Hour -ge 12 -and $Hour -lt 16) { return 'doki.greet.noon' }
    if ($Hour -ge 16 -and $Hour -lt 20) { return 'doki.greet.evening' }
    return 'doki.greet.night'
}

# State -> @{ key; args; mood }. $State.event plus event data. Pure.
function Get-DokiMessage($State) {
    $ev = [string]$State.event
    switch ($ev) {
        'login' {
            $g = Get-DokiGreetingKey ([int]$State.hour)
            if ($State.role -eq 'guest') {
                if ([string]$State.name) { return @{ key = 'doki.hello.guestNamed'; args = @([string]$State.name); mood = 'hello' } }
                return @{ key = 'doki.hello.guest'; args = @($g); mood = 'hello' }
            }
            if ($State.role -eq 'staff') {
                if ($State.hasAsset) { return @{ key = 'doki.hello.ready'; args = @([string]$State.name); mood = 'pointing' } }
                return @{ key = 'doki.hello.staff'; args = @($g, [string]$State.name); mood = 'hello' }
            }
            return @{ key = 'doki.hello.pick'; args = @($g); mood = 'hello' }
        }
        'checksRunning' {
            if ($State.admin -eq $false) { return @{ key = 'doki.checks.runningNoAdmin'; args = @(); mood = 'thinking' } }
            return @{ key = 'doki.checks.running'; args = @(); mood = 'thinking' }
        }
        'checksDone' {
            $v = $State.verdict
            $cards = @('battery', 'disks', 'drivers', 'updates')
            $bad = @($cards | Where-Object { $v.$_ -and ($v.$_.status -eq 'red' -or $v.$_.status -eq 'amber') }).Count
            if ($bad -eq 0) { return @{ key = 'doki.checks.allGood'; args = @(); mood = 'happy' } }
            if ($v.battery.status -eq 'red') { return @{ key = 'doki.tip.battery'; args = @(); mood = 'concerned' } }
            if ($v.disks.status -eq 'red') { return @{ key = 'doki.tip.disk'; args = @(); mood = 'concerned' } }
            if ($v.disks.status -eq 'amber' -and @($v.disks.reasons | Where-Object { $_.key -eq 'disk.noPercent' }).Count -gt 0) { return @{ key = 'doki.tip.diskAdmin'; args = @(); mood = 'concerned' } }
            if ($v.drivers.status -eq 'red') { return @{ key = 'doki.tip.drivers'; args = @(); mood = 'concerned' } }
            if ($v.updates.status -eq 'red') { return @{ key = 'doki.tip.updates'; args = @(); mood = 'concerned' } }
            if ($v.updates.status -eq 'amber') { return @{ key = 'doki.tip.noInternet'; args = @(); mood = 'concerned' } }
            return @{ key = 'doki.checks.problems'; args = @($bad); mood = 'concerned' }
        }
        'duplicate'     { return @{ key = 'doki.tip.duplicate'; args = @(); mood = $null } }
        'stressScreen'  { return @{ key = 'doki.stress.intro'; args = @(); mood = 'pointing' } }
        'stressRunning' { return @{ key = ('doki.stress.running.' + [string]$State.kind); args = @(); mood = 'working' } }
        'stressDone' {
            if ($State.result -eq 'completed') { return @{ key = 'doki.stress.done'; args = @(); mood = 'happy' } }
            if ($State.result -eq 'errors' -or $State.result -eq 'crashed') { return @{ key = 'doki.stress.problem'; args = @(); mood = 'concerned' } }
            return @{ key = $null; args = @(); mood = 'hello' }
        }
        'manual'     { return @{ key = 'doki.manual.intro'; args = @(); mood = 'pointing' } }
        'manualDone' { return @{ key = 'doki.manual.done'; args = @(); mood = 'happy' } }
        'report' {
            if ($State.status -eq 'green') { return @{ key = 'doki.report.good'; args = @(); mood = 'happy' } }
            return @{ key = 'doki.report.attention'; args = @([int]$State.count); mood = 'concerned' }
        }
        'saved'   { return @{ key = 'doki.report.saved'; args = @(); mood = 'celebrate' } }
        'deploy'  { if ($State.step) { return @{ key = ('doki.deploy.' + [string]$State.step); args = @(); mood = 'pointing' } }; return @{ key = $null; args = @(); mood = $null } }
        'followAsk'   { return @{ key = 'doki.follow.ask'; args = @(); mood = 'pointing' } }
        'followBimax' { return @{ key = 'doki.follow.bimax'; args = @(); mood = 'happy' } }
        'followDone'  { return @{ key = 'doki.follow.done'; args = @(); mood = 'happy' } }
        'history' { return @{ key = 'doki.history'; args = @(); mood = 'hello' } }
        'about'   { return @{ key = 'doki.about'; args = @(); mood = 'hello' } }
        'sleep'   { return @{ key = $null; args = @(); mood = 'sleep' } }
        'wake'    { return @{ key = 'doki.wake'; args = @(); mood = 'hello' } }
    }
    return @{ key = $null; args = @(); mood = $null }
}

# Rate limit decision: 'show' | 'queue' | 'skip'. Never the same key twice in a row; min 3 s between messages. Pure.
function Get-DokiDecision([string]$LastKey, [datetime]$LastAt, [datetime]$Now, [string]$Key, [double]$MinSeconds = 3) {
    if (-not $Key) { return 'skip' }
    if ($Key -eq $LastKey) { return 'skip' }
    if (($Now - $LastAt).TotalSeconds -lt $MinSeconds) { return 'queue' }
    return 'show'
}

# The pointing pose points to the viewer's right; flip it when the content is on Doki's left. Pure.
#   side column = start side (left in LTR, right in RTL); home host = end side of the login card.
function Test-DokiFlip([string]$Mood, [string]$HostName, [bool]$Rtl) {
    if ($Mood -ne 'pointing') { return $false }
    $contentOnLeft = (($HostName -eq 'side') -and $Rtl) -or (($HostName -eq 'home') -and -not $Rtl)
    return $contentOnLeft
}

# ---------------- images ----------------

function Get-DokiImage([string]$Mood, [switch]$Small) {
    $file = Get-DokiPoseFile $Mood -Small:$Small
    if (-not $file) { return $null }
    if ($global:DokiImages.ContainsKey($file)) { return $global:DokiImages[$file] }
    try {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.UriSource = [Uri]$file
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        if ($Small) { $bi.DecodePixelWidth = 256 } else { $bi.DecodePixelWidth = 512 }
        $bi.EndInit()
        $bi.Freeze()
        $global:DokiImages[$file] = $bi
        return $bi
    } catch { Write-WkLog ('doki image failed: ' + $file + ' ' + $_.Exception.Message) 'WARN'; return $null }
}

# ---------------- motions ----------------

function New-DokiAnim([double]$From, [double]$To, [int]$Ms, [switch]$Forever, [switch]$Reverse, [double]$Count = 0) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $From; $a.To = $To
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
    $a.AutoReverse = [bool]$Reverse
    if ($Forever) { $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
    elseif ($Count -gt 0) { $a.RepeatBehavior = New-Object System.Windows.Media.Animation.RepeatBehavior ($Count) }
    $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
    return $a
}

function Initialize-DokiTransforms {
    $u = $global:WkUi
    $global:DokiAnim.flip = New-Object System.Windows.Media.ScaleTransform 1, 1
    $u.DokiFlip.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $u.DokiFlip.RenderTransform = $global:DokiAnim.flip
    $grp = New-Object System.Windows.Media.TransformGroup
    $global:DokiAnim.scale = New-Object System.Windows.Media.ScaleTransform 1, 1
    $global:DokiAnim.rot = New-Object System.Windows.Media.RotateTransform 0
    $global:DokiAnim.bob = New-Object System.Windows.Media.TranslateTransform 0, 0
    $global:DokiAnim.hop = New-Object System.Windows.Media.TranslateTransform 0, 0
    foreach ($t in @($global:DokiAnim.scale, $global:DokiAnim.rot, $global:DokiAnim.bob, $global:DokiAnim.hop)) { $grp.Children.Add($t) }
    $u.DokiFigure.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.95   # pivot near the feet
    $u.DokiFigure.RenderTransform = $grp
}

function Stop-DokiMotion {
    $a = $global:DokiAnim
    if (-not $a.scale) { return }
    $a.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $a.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $a.rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $a.bob.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $a.hop.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $a.scale.ScaleX = 1; $a.scale.ScaleY = 1; $a.rot.Angle = 0; $a.bob.Y = 0; $a.hop.Y = 0
}

function Start-DokiMotion([string]$Mood) {
    Stop-DokiMotion
    if (-not (Get-DokiConfig).animations) { return }
    $a = $global:DokiAnim
    $bobMs = 1200; if ($Mood -eq 'sleep') { $bobMs = 2000 }
    if ($Mood -ne 'concerned') { $a.bob.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-DokiAnim 0 -4 $bobMs -Forever -Reverse)) }
    switch ($Mood) {
        'hello' {
            $a.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-DokiAnim 0.96 1 250))
            $a.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-DokiAnim 0.96 1 250))
        }
        'thinking' { $a.rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, (New-DokiAnim -2 2 800 -Forever -Reverse)) }
        'working' {
            $a.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-DokiAnim 1 1.025 450 -Forever -Reverse))
            $a.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-DokiAnim 1 1.025 450 -Forever -Reverse))
        }
        { $_ -eq 'happy' -or $_ -eq 'celebrate' } { $a.hop.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-DokiAnim 0 -14 110 -Reverse -Count 2)) }
        'concerned' { $a.rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, (New-DokiAnim -1.5 1.5 1500 -Forever -Reverse)) }
    }
}

# ---------------- mood (pose swap with cross-fade) ----------------

function Update-DokiFlip {
    if (-not $global:DokiAnim.flip) { return }
    $flip = Test-DokiFlip ([string]$global:DokiState.mood) ([string]$global:DokiState.host) (Test-WkRtl)
    if ($flip) { $global:DokiAnim.flip.ScaleX = -1 } else { $global:DokiAnim.flip.ScaleX = 1 }
}

function Set-DokiMood([string]$Mood, [switch]$Force) {
    if (-not $Mood -or -not $global:DokiState.ready) { return }
    if ($Mood -eq $global:DokiState.mood -and -not $Force) { return }
    $u = $global:WkUi
    $small = ($global:DokiState.host -eq 'side')
    $img = Get-DokiImage $Mood -Small:$small
    if (-not $img) { $u.DokiFigure.Visibility = 'Collapsed'; return }
    $u.DokiFigure.Visibility = 'Visible'
    $global:DokiState.mood = $Mood
    if ($global:DokiState.active -eq 'A') { $in = $u.DokiImgB; $out = $u.DokiImgA; $global:DokiState.active = 'B' } else { $in = $u.DokiImgA; $out = $u.DokiImgB; $global:DokiState.active = 'A' }
    $in.Source = $img
    [System.Windows.Automation.AutomationProperties]::SetName($in, 'doki:' + $Mood)
    [System.Windows.Automation.AutomationProperties]::SetName($out, 'doki:hidden')
    if ((Get-DokiConfig).animations) {
        $in.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-DokiAnim 0 1 180))
        $out.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-DokiAnim 1 0 180))
    } else {
        $in.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $out.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $in.Opacity = 1; $out.Opacity = 0
    }
    Update-DokiFlip
    Start-DokiMotion $Mood
    if ($Mood -eq 'celebrate') {
        if ($global:DokiAnim.celebrate) { $global:DokiAnim.celebrate.Stop() }
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds(3)
        $t.Add_Tick({ Invoke-WkUiSafe { $global:DokiAnim.celebrate.Stop(); if ($global:DokiState.mood -eq 'celebrate') { Set-DokiMood 'happy' } } })
        $global:DokiAnim.celebrate = $t
        $t.Start()
    }
}

# ---------------- messages (bubble) ----------------

function Show-DokiBubbleText([string]$Text) {
    $u = $global:WkUi
    $u.DokiBubbleText.Text = $Text
    [System.Windows.Automation.AutomationProperties]::SetName($u.DokiBubbleText, $Text)
    $u.DokiFigure.ToolTip = $Text
    $global:DokiState.shownAt = Get-Date
    Update-DokiBubbleVisibility
}

function Update-DokiBubbleVisibility {
    $u = $global:WkUi
    $narrow = ($global:WkWindow.ActualWidth -gt 0 -and $global:WkWindow.ActualWidth -lt 1000)
    $age = ((Get-Date) - $global:DokiState.shownAt).TotalSeconds
    $show = [bool]$u.DokiBubbleText.Text
    if ($global:DokiState.host -eq 'side') {
        if ($narrow) { $show = $false }                      # narrow window: text on hover (tooltip) only
        elseif ($age -gt 8) { $show = $false }               # auto-collapse after 8 s
    } elseif (-not $global:DokiState.sticky -and $age -gt 8) { $show = $false }
    if ($show) { $u.DokiBubble.Visibility = 'Visible' } else { $u.DokiBubble.Visibility = 'Collapsed' }
}

function Format-DokiText([string]$Key, [object[]]$ArgList) {
    $a = @()
    foreach ($x in @($ArgList)) { if ($x -is [string] -and $global:WkStrings.ContainsKey($x)) { $a += (T $x) } else { $a += $x } }
    return (T $Key @a)
}

# The mood travels with its message: a queued message changes the pose only when it is actually shown
# (so a queued "next step" hint cannot cut a celebration short).
function Show-DokiMessage([string]$Key, [object[]]$ArgList = @(), [string]$Mood = $null, [switch]$Force) {
    if (-not $Key -or -not $global:DokiState.ready) { return }
    $now = Get-Date
    # "Never the same message twice in a row" compares key + arguments (a new name is a new message).
    $sig = $Key + '|' + (@($ArgList) -join '|')
    $d = 'show'
    if (-not $Force) { $d = Get-DokiDecision $global:DokiState.lastSig $global:DokiState.lastAt $now $sig }
    if ($d -eq 'skip') { if ($Mood) { Set-DokiMood $Mood }; return }
    if ($d -eq 'queue') {
        # Keep the newest 3 (one per key), drop stale ones in Update-DokiTick.
        $global:DokiState.queue = @(@($global:DokiState.queue | Where-Object { $_.key -ne $Key }) + @(@{ key = $Key; args = @($ArgList); mood = $Mood; at = $now }))
        if ($global:DokiState.queue.Count -gt 3) { $global:DokiState.queue = @($global:DokiState.queue | Select-Object -Last 3) }
        return
    }
    $global:DokiState.lastKey = $Key; $global:DokiState.lastArgs = @($ArgList); $global:DokiState.lastAt = $now; $global:DokiState.lastSig = $sig
    if ($Mood) { Set-DokiMood $Mood }
    Show-DokiBubbleText (Format-DokiText $Key $ArgList)
}

# Event entry point used by Ui.ps1 hooks. -Force: user navigation (screen entry) speaks immediately and clears older queued lines.
function Invoke-DokiEvent([string]$EventName, $Data = @{}, [switch]$Force) {
    if (-not $global:DokiState.ready -or $global:DokiState.muted) { return }
    $state = @{ event = $EventName }
    foreach ($k in @($Data.Keys)) { $state[$k] = $Data[$k] }
    $m = Get-DokiMessage $state
    if ($Force) { $global:DokiState.queue = @() }
    if ($m.key) { Show-DokiMessage $m.key @($m.args) $m.mood -Force:$Force }
    elseif ($m.mood) { Set-DokiMood $m.mood }
}

# ---------------- hosts, mute, language, idle ----------------

function Move-DokiTo([string]$HostName) {
    $u = $global:WkUi
    $panel = $u.DokiPanel
    if ($global:DokiState.muted -or -not (Get-DokiConfig).enabled) {
        $u.DokiSideHost.Visibility = 'Collapsed'; $u.DokiHomeHost.Visibility = 'Collapsed'; return
    }
    $target = $u.DokiHomeHost; if ($HostName -eq 'side') { $target = $u.DokiSideHost }
    if ($panel.Parent -ne $target) {
        if ($panel.Parent) { [void]$panel.Parent.Children.Remove($panel) }
        [void]$target.Children.Add($panel)
    }
    $changed = ($global:DokiState.host -ne $HostName)
    $global:DokiState.host = $HostName
    if ($HostName -eq 'side') {
        $u.DokiSideHost.Visibility = 'Visible'; $u.DokiHomeHost.Visibility = 'Collapsed'
        $u.DokiFlip.Height = 110; $u.DokiBubbleBox.MaxWidth = 140; $u.DokiBubbleText.FontSize = 13
    } else {
        $u.DokiSideHost.Visibility = 'Collapsed'; $u.DokiHomeHost.Visibility = 'Visible'
        $u.DokiFlip.Height = 220; $u.DokiBubbleBox.MaxWidth = 300; $u.DokiBubbleText.FontSize = 15
    }
    if ($changed -and $global:DokiState.mood) { Set-DokiMood $global:DokiState.mood -Force }   # swap to the right image size
    Update-DokiFlip
}

function Set-DokiMuted([bool]$Muted) {
    $global:DokiState.muted = $Muted
    $u = $global:WkUi
    if ($Muted) {
        Stop-DokiMotion
        $u.DokiSideHost.Visibility = 'Collapsed'; $u.DokiHomeHost.Visibility = 'Collapsed'
        $u.BtnDokiMute.Opacity = 0.45; $u.BtnDokiMute.ToolTip = T 'doki.unmute'
    } else {
        $u.BtnDokiMute.Opacity = 1; $u.BtnDokiMute.ToolTip = T 'doki.mute'
        $h = 'side'; if ($global:WkState.screen -eq 'ScreenHome') { $h = 'home' }
        Move-DokiTo $h
        if ($global:DokiState.mood) { Set-DokiMood $global:DokiState.mood -Force }
    }
}

function Update-DokiLanguage {
    $u = $global:WkUi
    if (-not $global:DokiState.ready) { return }
    if (Test-WkRtl) { $u.DokiBubbleText.FlowDirection = 'RightToLeft' } else { $u.DokiBubbleText.FlowDirection = 'LeftToRight' }
    if ($global:DokiState.muted) { $u.BtnDokiMute.ToolTip = T 'doki.unmute' } else { $u.BtnDokiMute.ToolTip = T 'doki.mute' }
    if ($global:DokiState.lastKey) { Show-DokiBubbleText (Format-DokiText $global:DokiState.lastKey $global:DokiState.lastArgs) }
    Update-DokiFlip
}

# Called by the 500 ms UI timer: queue, auto-collapse, idle sleep.
function Update-DokiTick {
    if (-not $global:DokiState.ready -or $global:DokiState.muted) { return }
    $now = Get-Date
    $q = @($global:DokiState.queue | Where-Object { ($now - $_.at).TotalSeconds -lt 10 })   # drop stale
    if ($q.Count -gt 0 -and ($now - $global:DokiState.lastAt).TotalSeconds -ge 3) {
        $next = $q[0]; $global:DokiState.queue = @($q | Select-Object -Skip 1)
        Show-DokiMessage $next.key @($next.args) $next.mood
    } else { $global:DokiState.queue = $q }
    Update-DokiBubbleVisibility
    $busy = [bool]$global:WkState.currentKind -or ($global:WkState.checksStarted -and -not $global:DokiState.checksAnnounced)
    if (-not $global:DokiState.sleeping -and -not $busy -and ($now - $global:DokiState.lastInput).TotalSeconds -ge 60) {
        $global:DokiState.sleeping = $true
        $global:DokiState.wakeMood = $global:DokiState.mood
        Set-DokiMood 'sleep'
        $global:WkUi.DokiBubble.Visibility = 'Collapsed'
    }
}

function Register-DokiInput {
    $global:DokiState.lastInput = Get-Date
    if ($global:DokiState.sleeping) {
        $global:DokiState.sleeping = $false
        Invoke-DokiEvent 'wake'
    }
}

function Initialize-Doki {
    $u = $global:WkUi
    $cfg = Get-DokiConfig
    if (-not $u.DokiPanel -or -not $cfg.enabled -or -not (Get-DokiPoseFile 'hello')) {
        if ($u.DokiHomeHost) { $u.DokiHomeHost.Visibility = 'Collapsed' }
        if ($u.DokiSideHost) { $u.DokiSideHost.Visibility = 'Collapsed' }
        if ($u.BtnDokiMute) { $u.BtnDokiMute.Visibility = 'Collapsed' }
        return
    }
    Initialize-DokiTransforms
    # small Doki on the mute button, top-bar logo and About
    $m = Get-DokiImage 'hello' -Small
    $master = Join-Path $global:WkRoot 'assets\doki\doki_master.png'
    if (-not (Test-Path -LiteralPath $master)) { $master = Get-DokiPoseFile 'hello' }
    $mi = $null; if ($master) { try { $mi = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri]$master); $mi.Freeze() } catch { } }
    if ($u.TopLogoImg -and $mi) { $u.TopLogoImg.Source = $mi }
    if ($u.AboutDokiImg -and $mi) { $u.AboutDokiImg.Source = $mi }
    if ($u.DokiMuteImg -and $m) { $u.DokiMuteImg.Source = $m }
    $global:DokiState.ready = $true
    # first launch of the day keeps the Home bubble open; later launches start collapsed
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $global:DokiState.sticky = ([string]$global:DokiLastDay -ne $today)
    $global:DokiLastDay = $today
    Set-DokiMuted ([bool]$global:DokiStartMuted)
}

function Stop-DokiAll {
    try { Stop-DokiMotion; if ($global:DokiAnim.celebrate) { $global:DokiAnim.celebrate.Stop() } } catch { }
}
