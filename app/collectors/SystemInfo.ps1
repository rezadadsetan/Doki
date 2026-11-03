# Get-WkSystemInfo: device identity for the top bar and the report. Non-admin.

function Get-WkSystemInfo {
    Invoke-WkSafe 'system' {
        $ErrorActionPreference = 'Stop'
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = @(Get-CimInstance Win32_Processor)
        $serial = ''
        if ($bios.SerialNumber) { $serial = ([string]$bios.SerialNumber).Trim() }
        if (-not $serial -or $serial -match '^(To be filled|Default string|System Serial|0+)$') {
            try { $serial = ([string](Get-CimInstance Win32_ComputerSystemProduct).IdentifyingNumber).Trim() } catch { }
        }
        $gpus = @()
        foreach ($g in @(Get-CimInstance Win32_VideoController)) {
            $gpus += @{ name = [string]$g.Name; driverVersion = [string]$g.DriverVersion }
        }
        $isLaptop = $false
        try {
            $laptopTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
            foreach ($t in @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)) { if ($laptopTypes -contains [int]$t) { $isLaptop = $true } }
        } catch { }
        if (-not $isLaptop) { try { if (@(Get-CimInstance Win32_Battery).Count -gt 0) { $isLaptop = $true } } catch { } }
        @{
            manufacturer = ([string]$cs.Manufacturer).Trim()
            model        = ([string]$cs.Model).Trim()
            serial       = $serial
            biosVersion  = [string]$bios.SMBIOSBIOSVersion
            cpu          = ([string]$cpu[0].Name).Trim()
            cores        = [int](($cpu | Measure-Object -Property NumberOfCores -Sum).Sum)
            threads      = [int](($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
            ramGB        = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)
            gpus         = $gpus
            os           = ([string]$os.Caption).Trim()
            build        = [string]$os.BuildNumber
            isLaptop     = $isLaptop
        }
    }
}
