# Get-WkBattery: health, cycles, runtime estimate (DATA_SOURCES.md).
# Primary: powercfg /batteryreport /xml (works without admin). Fallback: WMI root\wmi classes.

function Get-WkBattery {
    Invoke-WkSafe 'battery' {
        $r = @{
            present = $false; name = $null; designMWh = $null; fullMWh = $null; cycles = $null
            healthPercent = $null; runtimeMinutes = $null; chargePercent = $null; onAc = $null; source = $null
        }

        # 1) powercfg XML report (temp file, always deleted)
        $xmlPath = Join-Path $env:TEMP ('wk_battery_' + [guid]::NewGuid().ToString('N') + '.xml')
        try {
            $exe = Join-Path $env:WINDIR 'System32\powercfg.exe'
            $okRun = Invoke-WkProcess $exe ('/batteryreport /xml /output "' + $xmlPath + '"') 20000
            if ($okRun -and (Test-Path -LiteralPath $xmlPath)) {
                [xml]$x = [IO.File]::ReadAllText($xmlPath)
                $bats = @($x.BatteryReport.Batteries.Battery | Where-Object { $_ })
                if ($bats.Count -gt 0) {
                    $design = 0.0; $full = 0.0; $cyc = $null; $names = @()
                    foreach ($b in $bats) {
                        $design += [double]$b.DesignCapacity
                        $full += [double]$b.FullChargeCapacity
                        if ("$($b.CycleCount)" -ne '') { $c = [int]$b.CycleCount; if ($null -eq $cyc -or $c -gt $cyc) { $cyc = $c } }
                        if ($b.Id) { $names += ([string]$b.Id).Trim() }
                    }
                    $r.present = $true; $r.source = 'powercfg'; $r.name = ($names -join ', ')
                    if ($design -gt 0) { $r.designMWh = $design }
                    if ($full -gt 0) { $r.fullMWh = $full }
                    $r.cycles = $cyc
                    try {
                        $rt = [string]$x.BatteryReport.RuntimeEstimates.FullChargeCapacity.ActiveRuntime
                        if ($rt) { $ts = [Xml.XmlConvert]::ToTimeSpan($rt); if ($ts.TotalMinutes -gt 0) { $r.runtimeMinutes = [int][math]::Round($ts.TotalMinutes) } }
                    } catch { }
                }
            }
        } catch {
            Write-WkLog ('battery powercfg: ' + $_.Exception.Message) 'WARN'
        } finally {
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        }

        # 2) WMI fallbacks for anything still missing
        try {
            if ($null -eq $r.fullMWh) {
                $f = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
                if ($f.Count -gt 0) { $r.fullMWh = [double](($f | Measure-Object FullChargedCapacity -Sum).Sum); $r.present = $true; if (-not $r.source) { $r.source = 'wmi' } }
            }
        } catch { }
        try {
            if ($null -eq $r.designMWh) {
                $s = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop)
                if ($s.Count -gt 0) { $r.designMWh = [double](($s | Measure-Object DesignedCapacity -Sum).Sum) }
            }
        } catch { }
        try {
            if ($null -eq $r.cycles) {
                $c = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop)
                if ($c.Count -gt 0) { $r.cycles = [int](($c | Measure-Object CycleCount -Maximum).Maximum) }
            }
        } catch { }
        $status = $null
        try { $status = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop) | Select-Object -First 1 } catch { }
        if ($status) {
            $r.onAc = [bool]$status.PowerOnline
            if ($null -eq $r.runtimeMinutes -and $status.Discharging -and [double]$status.DischargeRate -gt 0 -and $r.fullMWh) {
                $r.runtimeMinutes = [int][math]::Round($r.fullMWh / [double]$status.DischargeRate * 60)
            }
        }
        try {
            $wb = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
            if ($wb.Count -gt 0) {
                $r.present = $true
                $r.chargePercent = [int]$wb[0].EstimatedChargeRemaining
                if (-not $r.name) { $r.name = [string]$wb[0].Name }
            }
        } catch { }

        if ($r.designMWh -and $r.fullMWh) { $r.healthPercent = [math]::Round($r.fullMWh / $r.designMWh * 100, 1) }
        $r
    }
}
