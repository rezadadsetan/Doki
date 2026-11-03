# Stress tests (D-011): CPU/RAM/Disk via WonderKid.StressRunner (C#, Add-Type), GPU via an Edge app window (D-002).
# The UI polls Get-WkStressState every 500 ms; nothing here blocks for long.

function Initialize-WkStressType {
    if (-not ('WonderKid.StressRunner' -as [type])) {
        if (-not (Import-WkNative)) { Add-Type -Path (Join-Path $global:WkApp 'stress\StressNative.cs') -ErrorAction Stop }
    }
    if (-not $global:WkRunner) { $global:WkRunner = New-Object WonderKid.StressRunner }
}

function Get-WkStressSize([string]$Kind) {
    $rules = Get-WkRules
    if ($Kind -eq 'ram') {
        $freeBytes = [double](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
        $size = [math]::Min($freeBytes * [double]$rules.stress.ram_max_fraction_of_free, [double]$rules.stress.ram_max_gb * 1GB)
        return [long]$size
    }
    if ($Kind -eq 'disk') {
        $drive = (Split-Path -Qualifier $env:TEMP).TrimEnd(':')
        $free = [double](Get-PSDrive -Name $drive).Free
        if ($free -lt [double]$rules.stress.disk_min_free_gb * 1GB) { throw ('not enough free space on ' + $drive + ': (' + [math]::Round($free / 1GB, 1) + ' GB)') }
        $size = [math]::Min([double]$rules.stress.disk_file_max_gb * 1GB, $free * [double]$rules.stress.disk_file_max_fraction_of_free)
        return [long]$size
    }
    return [long]0
}

# ---------------- GPU (Edge app window running app\stress\gpu.html) ----------------

function Find-WkEdge {
    $cands = @()
    try { $cands += (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)' } catch { }
    $cands += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    $cands += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Get-WkGpuWindow {
    # The page sets its title to WK-GPU-<state>; the Edge process that owns that window is the browser process.
    return @(Get-Process -Name msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'WK-GPU-*' }) | Select-Object -First 1
}

function Stop-WkGpuProcesses {
    $w = Get-WkGpuWindow
    if ($w) { try { & taskkill.exe /PID $w.Id /T /F 2>$null | Out-Null } catch { } }
    # Safety net: anything still running with our private profile folder.
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*wk-edge*' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    } catch { }
}

function Start-WkGpuStress([int]$Seconds) {
    $g = @{ kind = 'gpu'; status = 'running'; error = ''; started = [DateTime]::UtcNow; seconds = $Seconds; seen = $false; lastSeen = $null; title = '' }
    $edge = Find-WkEdge
    if (-not $edge) { $g.status = 'unavailable'; $g.error = 'Microsoft Edge not found'; return $g }
    $page = Join-Path $global:WkApp 'stress\gpu.html'
    $url = ([Uri]$page).AbsoluteUri + '?sec=' + $Seconds
    $profileDir = Join-Path $env:TEMP 'wk-edge'
    $argList = '--app="' + $url + '" --user-data-dir="' + $profileDir + '" --no-first-run --no-default-browser-check --start-fullscreen --disable-features=Translate --autoplay-policy=no-user-gesture-required'
    Start-Process -FilePath $edge -ArgumentList $argList | Out-Null
    Write-WkLog ('gpu stress started: ' + $url)
    return $g
}

function Update-WkGpuState($g) {
    if ($g.status -ne 'running') { return $g }
    $now = [DateTime]::UtcNow
    $elapsed = ($now - $g.started).TotalSeconds
    $w = Get-WkGpuWindow
    if ($w) {
        $g.seen = $true; $g.lastSeen = $now; $g.title = $w.MainWindowTitle
        if ($g.title -eq 'WK-GPU-ERROR') { $g.status = 'errors'; $g.error = 'WebGL context lost (GPU reset)'; Stop-WkGpuProcesses }
        elseif ($g.title -eq 'WK-GPU-NOWEBGL') { $g.status = 'unavailable'; $g.error = 'WebGL2 not available'; Stop-WkGpuProcesses }
        elseif ($g.title -eq 'WK-GPU-DONE' -or $elapsed -ge ($g.seconds + 3)) { $g.status = 'completed'; Stop-WkGpuProcesses }
    } else {
        if (-not $g.seen -and $elapsed -gt 20) { $g.status = 'unavailable'; $g.error = 'GPU window did not open' }
        elseif ($g.seen -and ($now - $g.lastSeen).TotalSeconds -gt 3) {
            if ($elapsed -ge $g.seconds - 1) { $g.status = 'completed' } else { $g.status = 'crashed'; $g.error = 'GPU window closed early' }
        }
    }
    return $g
}

# ---------------- common API used by the UI ----------------

# Returns a state hashtable for the started test (also stored in $global:WkStressCurrent).
function Start-WkStress([string]$Kind, [int]$Seconds) {
    if ($Kind -eq 'gpu') {
        $global:WkStressCurrent = Start-WkGpuStress $Seconds
        return $global:WkStressCurrent
    }
    $s = @{ kind = $Kind; status = 'running'; error = ''; seconds = $Seconds; started = [DateTime]::UtcNow }
    try {
        Initialize-WkStressType
        $size = Get-WkStressSize $Kind
        $file = Join-Path $env:TEMP ('stress_' + [guid]::NewGuid().ToString('N') + '.bin')
        $global:WkRunner.Start($Kind, $Seconds, $size, $file)
        Write-WkLog ('stress {0} started: {1} s, size {2} MB' -f $Kind, $Seconds, [math]::Round($size / 1MB))
    } catch {
        $s.status = 'unavailable'; $s.error = $_.Exception.Message
        Write-WkLog ('stress {0} unavailable: {1}' -f $Kind, $s.error) 'WARN'
    }
    $global:WkStressCurrent = $s
    return $s
}

function Get-WkTemperature {
    # ACPI thermal zone (admin only; often missing). Cached failure so we do not query again and again.
    if ($global:WkTempUnavailable) { return $null }
    try {
        $z = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        if ($z.Count -eq 0) { $global:WkTempUnavailable = $true; return $null }
        return [math]::Round((($z | Measure-Object CurrentTemperature -Maximum).Maximum / 10) - 273.15, 0)
    } catch { $global:WkTempUnavailable = $true; return $null }
}

# Polled by the UI: returns @{ kind; status; progress 0..1; secondsLeft; errors; live fields; error }
function Get-WkStressState {
    $s = $global:WkStressCurrent
    if (-not $s) { return $null }
    if ($s.kind -eq 'gpu') {
        $s = Update-WkGpuState $s
        $elapsed = ([DateTime]::UtcNow - $s.started).TotalSeconds
        $s.progress = [math]::Min(1.0, $elapsed / [math]::Max(1, $s.seconds))
        $s.secondsLeft = [int][math]::Max(0, $s.seconds - $elapsed)
        $s.errors = 0
        if ($s.status -ne 'running') { $s.progress = 1; $s.secondsLeft = 0 }
        return $s
    }
    if ($s.status -eq 'running' -and $global:WkRunner) {
        $r = $global:WkRunner
        $s.progress = $r.Progress; $s.secondsLeft = $r.SecondsLeft; $s.errors = $r.Errors
        $s.threads = $r.Threads; $s.gb = [math]::Round($r.GBTested, 1); $s.mbps = $r.MBps; $s.detail = $r.Detail
        if (-not $r.IsRunning) { $s.status = $r.Status; $s.error = $r.Error; $s.progress = 1; $s.secondsLeft = 0 }
    }
    return $s
}

function Stop-WkStress {
    $s = $global:WkStressCurrent
    if (-not $s) { return }
    if ($s.kind -eq 'gpu') {
        if ($s.status -eq 'running') { $s.status = 'stopped' }
        Stop-WkGpuProcesses
        return
    }
    if ($global:WkRunner -and $global:WkRunner.IsRunning) {
        $global:WkRunner.Stop()
        [void]$global:WkRunner.Wait(15000)
    }
}

# Called on window close: stop everything and remove leftovers.
function Clear-WkStress {
    try { Stop-WkStress } catch { }
    try { Stop-WkGpuProcesses } catch { }
    try { Get-ChildItem -Path $env:TEMP -Filter 'stress_*.bin' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
}

# Headless check for agents/CI: CPU, RAM, Disk for N seconds each.
function Invoke-WkStressSelfTest([int]$Seconds = 10) {
    $out = [ordered]@{}
    $memBefore = [math]::Round((Get-Process -Id $PID).WorkingSet64 / 1MB)
    foreach ($k in @('cpu', 'ram', 'disk')) {
        $s = Start-WkStress $k $Seconds
        $deadline = (Get-Date).AddSeconds($Seconds + 60)
        while ($s.status -eq 'running' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $s = Get-WkStressState
        }
        if ($s.status -eq 'running') { Stop-WkStress; $s = Get-WkStressState; $s.error = 'self-test deadline' }
        $out[$k] = @{ result = $s.status; errors = $s.errors; detail = $s.detail; error = $s.error; mbps = $s.mbps; gb = $s.gb; threads = $s.threads }
    }
    [GC]::Collect()
    $out.tempFilesLeft = @(Get-ChildItem -Path $env:TEMP -Filter 'stress_*.bin' -ErrorAction SilentlyContinue).Count
    $out.workingSetMBBefore = $memBefore
    $out.workingSetMBAfter = [math]::Round((Get-Process -Id $PID).WorkingSet64 / 1MB)
    $out.temperature = Get-WkTemperature
    return $out
}
