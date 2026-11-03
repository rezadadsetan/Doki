# Live resource monitor (Phase 6, D-024): CPU %, RAM %, disk busy %. Cheap enough for the UI thread once per second.
# PerformanceCounter names are English-only on some localized Windows builds; CPU falls back to WMI, disk to "n/a".

function Initialize-WkMonitor {
    if ($global:WkMon) { return }
    $m = @{ cpu = $null; disk = $null; ci = $null }
    try { $c = New-Object System.Diagnostics.PerformanceCounter 'Processor', '% Processor Time', '_Total'; [void]$c.NextValue(); $m.cpu = $c } catch { }
    try { $d = New-Object System.Diagnostics.PerformanceCounter 'PhysicalDisk', '% Idle Time', '_Total'; [void]$d.NextValue(); $m.disk = $d } catch { }
    try { Add-Type -AssemblyName Microsoft.VisualBasic; $m.ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo } catch { }
    $global:WkMon = $m
}

# @{ cpu; ram; ramUsedGB; ramTotalGB; disk } (values 0..100 or $null)
function Get-WkMonitorSample {
    Initialize-WkMonitor
    $m = $global:WkMon
    $s = @{ cpu = $null; ram = $null; ramUsedGB = $null; ramTotalGB = $null; disk = $null }
    try {
        if ($m.cpu) { $s.cpu = [math]::Round([math]::Min(100, [math]::Max(0, $m.cpu.NextValue())), 0) }
        else { $s.cpu = [int](@(Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average) }
    } catch { }
    try {
        if ($m.ci) {
            $t = [double]$m.ci.TotalPhysicalMemory; $a = [double]$m.ci.AvailablePhysicalMemory
            $s.ramTotalGB = [math]::Round($t / 1GB, 1); $s.ramUsedGB = [math]::Round(($t - $a) / 1GB, 1)
            $s.ram = [math]::Round(($t - $a) / $t * 100, 0)
        }
    } catch { }
    try { if ($m.disk) { $s.disk = [math]::Round([math]::Min(100, [math]::Max(0, 100 - $m.disk.NextValue())), 0) } } catch { }
    return $s
}
