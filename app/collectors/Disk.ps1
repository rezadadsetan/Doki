# Get-WkDisks: one row per physical disk with an automatic health % (Phase 4, D-016), no third-party tools:
#   1. NVMe SMART/Health log via IOCTL (DiskNative.cs, works without admin)   -> healthSource 'nvme-log'
#   2. Windows reliability counter Wear (admin)                                -> 'windows-wear'
#   3. SATA SMART attributes from WMI MSStorageDriver_ATAPISmartData (admin)  -> 'smart-attr' (SSD wear) or 'smart-estimate' (HDD)

function Initialize-WkDiskNative {
    if (-not ('WonderKid.DiskNative' -as [type])) {
        if (-not (Import-WkNative)) { Add-Type -Path (Join-Path $global:WkApp 'collectors\DiskNative.cs') -ErrorAction Stop }
    }
}

# SMART "VendorSpecific" block (WMI): 2-byte revision, then 30 x 12-byte entries: id, flags(2), current, worst, raw(6), reserved.
function ConvertFrom-WkSmartAttributes([byte[]]$Data) {
    $list = @()
    if (-not $Data) { return $list }
    for ($i = 2; $i + 12 -le $Data.Length -and $i -lt 362; $i += 12) {
        $id = [int]$Data[$i]
        if ($id -eq 0) { continue }
        $raw = [long]0
        for ($k = 5; $k -ge 0; $k--) { $raw = ($raw * 256) + [int]$Data[$i + 5 + $k] }
        $list += @{ id = $id; current = [int]$Data[$i + 3]; worst = [int]$Data[$i + 4]; raw = $raw }
    }
    return $list
}

# Health % from SMART attributes. Pure (unit-tested).
# SSD wear indicators (normalized value = life left): 231 SSD Life Left, 233 Media Wearout, 177 Wear Leveling, 169 Remaining Life, 202 Percent Lifetime Remain.
# Otherwise an estimate from defects (HDD and SSDs without a wear attribute), like defect-based tools do: start at 100.
function Get-WkSmartHealth([object[]]$Attrs) {
    $byId = @{}
    foreach ($a in @($Attrs)) { if ($a) { $byId[[int]$a.id] = $a } }
    foreach ($id in @(231, 233, 177, 169, 202)) {
        if ($byId.ContainsKey($id)) {
            $v = [int]$byId[$id].current
            if ($v -ge 1 -and $v -le 100) { return @{ percent = $v; source = 'smart-attr'; attr = $id } }
        }
    }
    $realloc = 0; $pending = 0; $uncorr = 0
    if ($byId.ContainsKey(5)) { $realloc = [long]$byId[5].raw }
    if ($byId.ContainsKey(197)) { $pending = [long]$byId[197].raw }
    if ($byId.ContainsKey(198)) { $uncorr = [long]$byId[198].raw }
    if ($byId.Count -eq 0) { return @{ percent = $null; source = $null; attr = $null } }
    $p = 100 - [math]::Min(60, $realloc * 1) - [math]::Min(60, $pending * 3) - [math]::Min(60, $uncorr * 3)
    $p = [math]::Max(0, [math]::Min(100, $p))
    return @{ percent = $p; source = 'smart-estimate'; attr = $null; reallocated = $realloc; pending = $pending; uncorrectable = $uncorr }
}

function Get-WkSmartByIndex {
    # Map Win32_DiskDrive.Index (= PhysicalDisk DeviceId) -> attribute list. Needs admin; empty otherwise.
    $map = @{}
    try {
        $smart = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_ATAPISmartData -ErrorAction Stop)
        if ($smart.Count -eq 0) { return $map }
        foreach ($dd in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)) {
            $pnp = ([string]$dd.PNPDeviceID).ToUpperInvariant()
            foreach ($s in $smart) {
                if (([string]$s.InstanceName).ToUpperInvariant().StartsWith($pnp)) { $map[[string]$dd.Index] = ConvertFrom-WkSmartAttributes ([byte[]]$s.VendorSpecific) }
            }
        }
    } catch { }
    return $map
}

function Get-WkDisks {
    Invoke-WkSafe 'disks' {
        $ErrorActionPreference = 'Stop'
        $nativeOk = $true
        try { Initialize-WkDiskNative } catch { $nativeOk = $false; Write-WkLog ('DiskNative load failed: ' + $_.Exception.Message) 'WARN' }
        $smartMap = $null
        $rows = @()
        foreach ($d in @(Get-PhysicalDisk)) {
            $rc = $null
            try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
            $wear = $null; $temp = $null; $rErr = $null; $wErr = $null; $poh = $null
            if ($rc) {
                if ($null -ne $rc.Wear) { $wear = [int]$rc.Wear }
                if ($null -ne $rc.Temperature -and [int]$rc.Temperature -gt 0) { $temp = [int]$rc.Temperature }
                if ($null -ne $rc.ReadErrorsUncorrected) { $rErr = [long]$rc.ReadErrorsUncorrected }
                if ($null -ne $rc.WriteErrorsUncorrected) { $wErr = [long]$rc.WriteErrorsUncorrected }
                if ($null -ne $rc.PowerOnHours) { $poh = [long]$rc.PowerOnHours }
            }
            $hp = $null; $src = $null; $cw = $null; $media = $null; $spare = $null; $smartInfo = $null; $nvmeErr = $null
            $bus = [string]$d.BusType
            # 1) NVMe health log
            if ($nativeOk -and $bus -eq 'NVMe') {
                $n = [WonderKid.DiskNative]::ReadNvme([int]$d.DeviceId)
                if ($n.Ok) {
                    $hp = [math]::Max(0, 100 - [int]$n.PercentageUsed); $src = 'nvme-log'
                    $cw = [int]$n.CriticalWarning; $media = [long]$n.MediaErrors; $spare = [int]$n.AvailableSpare
                    if ($n.TemperatureC -gt 0) { $temp = [int]$n.TemperatureC }
                    $poh = [long]$n.PowerOnHours
                } else { $nvmeErr = $n.Error }
            }
            # 2) Windows Wear (admin)
            if ($null -eq $hp -and $null -ne $wear) { $hp = [math]::Max(0, 100 - $wear); $src = 'windows-wear' }
            # 3) SATA SMART (admin)
            if ($null -eq $hp) {
                if ($null -eq $smartMap) { $smartMap = Get-WkSmartByIndex }
                $attrs = $smartMap[[string]$d.DeviceId]
                if ($attrs) {
                    $sh = Get-WkSmartHealth $attrs
                    if ($null -ne $sh.percent) { $hp = [int]$sh.percent; $src = $sh.source; $smartInfo = $sh }
                    foreach ($a in $attrs) { if ($a.id -eq 194 -and -not $temp) { $t = [int]($a.raw % 256); if ($t -gt 0 -and $t -lt 100) { $temp = $t } }; if ($a.id -eq 9 -and -not $poh) { $poh = [long]($a.raw % 4294967296) } }
                }
            }
            $rows += @{
                name                   = ([string]$d.FriendlyName).Trim()
                mediaType              = [string]$d.MediaType
                busType                = $bus
                sizeGB                 = [math]::Round([double]$d.Size / 1GB, 0)
                healthStatus           = [string]$d.HealthStatus
                operationalStatus      = (@($d.OperationalStatus) -join ', ')
                wear                   = $wear
                healthPercent          = $hp
                healthSource           = $src
                criticalWarning        = $cw
                mediaErrors            = $media
                availableSpare         = $spare
                readErrorsUncorrected  = $rErr
                writeErrorsUncorrected = $wErr
                temperature            = $temp
                powerOnHours           = $poh
                smart                  = $smartInfo
                nvmeError              = $nvmeErr
            }
        }
        @{ disks = $rows }
    }
}
