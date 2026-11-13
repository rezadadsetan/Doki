# Live resource monitor (Phase 6, D-024): CPU %, RAM %, disk busy %.
# PerformanceCounter names are English-only on some localized Windows builds; CPU falls back to WMI, disk to "n/a".
# 2.7.0: in the app, counters are created AND sampled in a background runspace (Start-WkMonitorSampler); the UI only reads
# the latest values, so the monitor never stalls the window. Without the sampler (self-test, unit tests) it samples directly.

function New-WkMonitorCounters {
    $m = @{ cpu = $null; disk = $null; ci = $null }
    try { $c = New-Object System.Diagnostics.PerformanceCounter 'Processor', '% Processor Time', '_Total'; [void]$c.NextValue(); $m.cpu = $c } catch { }
    try { $d = New-Object System.Diagnostics.PerformanceCounter 'PhysicalDisk', '% Idle Time', '_Total'; [void]$d.NextValue(); $m.disk = $d } catch { }
    try { Add-Type -AssemblyName Microsoft.VisualBasic; $m.ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo } catch { }
    return $m
}

# @{ cpu; ram; ramUsedGB; ramTotalGB; disk } (values 0..100 or $null) from a counter set.
function Get-WkMonitorValues($M) {
    $s = @{ cpu = $null; ram = $null; ramUsedGB = $null; ramTotalGB = $null; disk = $null }
    if (-not $M) { return $s }
    try {
        if ($M.cpu) { $s.cpu = [math]::Round([math]::Min(100, [math]::Max(0, $M.cpu.NextValue())), 0) }
        else { $s.cpu = [int](@(Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average) }
    } catch { }
    try {
        if ($M.ci) {
            $t = [double]$M.ci.TotalPhysicalMemory; $a = [double]$M.ci.AvailablePhysicalMemory
            $s.ramTotalGB = [math]::Round($t / 1GB, 1); $s.ramUsedGB = [math]::Round(($t - $a) / 1GB, 1)
            $s.ram = [math]::Round(($t - $a) / $t * 100, 0)
        }
    } catch { }
    try { if ($M.disk) { $s.disk = [math]::Round([math]::Min(100, [math]::Max(0, 100 - $M.disk.NextValue())), 0) } } catch { }
    return $s
}

# Background sampler: one sample per second into $global:WkMonSync.sample until Stop-WkMonitorSampler.
function Start-WkMonitorSampler {
    if ($global:WkMonSync) { return }
    $global:WkMonSync = [hashtable]::Synchronized(@{ run = $true; sample = $null })
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $fn = 'function New-WkMonitorCounters {' + ${function:New-WkMonitorCounters}.ToString() + "}`n" + 'function Get-WkMonitorValues {' + ${function:Get-WkMonitorValues}.ToString() + "}`n"
    # param() must be the first statement of the script, the helper functions follow it.
    [void]$ps.AddScript("param(`$s)`n" + $fn + {
        $m = New-WkMonitorCounters
        while ($s.run) {
            $s.sample = Get-WkMonitorValues $m
            for ($i = 0; $i -lt 10 -and $s.run; $i++) { Start-Sleep -Milliseconds 100 }
        }
    }.ToString()).AddArgument($global:WkMonSync)
    $global:WkMonJob = @{ ps = $ps; rs = $rs; h = $ps.BeginInvoke() }
}

function Stop-WkMonitorSampler {
    if (-not $global:WkMonSync) { return }
    $global:WkMonSync.run = $false
    if ($global:WkMonJob) { try { [void]$global:WkMonJob.ps.BeginStop($null, $null) } catch { } }
}

function Get-WkMonitorSample {
    if ($global:WkMonSync) {
        $x = $global:WkMonSync.sample
        if ($x) { return $x }
        return @{ cpu = $null; ram = $null; ramUsedGB = $null; ramTotalGB = $null; disk = $null }   # still warming up: never block
    }
    if (-not $global:WkMon) { $global:WkMon = New-WkMonitorCounters }
    return (Get-WkMonitorValues $global:WkMon)
}
