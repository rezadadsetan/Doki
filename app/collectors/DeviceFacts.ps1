# Get-WkDeviceFacts (Phase 6, D-023): information only, never red.
# RAM slots used/total + modules, Windows install date (current + original), activation, BitLocker C:, Secure Boot, TPM, domain / Entra ID join.

# Pure: slots summary from Win32_PhysicalMemoryArray.MemoryDevices values and Win32_PhysicalMemory modules.
function Get-WkRamSlots([object[]]$ArrayDeviceCounts, [object[]]$Modules) {
    $mods = @($Modules | Where-Object { $_ })
    $total = 0
    foreach ($c in @($ArrayDeviceCounts)) { if ($c) { $total += [int]$c } }
    if ($total -lt $mods.Count) { $total = $mods.Count }   # some firmware reports 0 / too few slots
    $list = @(); $socketed = 0; $totalGB = 0.0
    foreach ($m in $mods) {
        $speed = [int]$m.ConfiguredClockSpeed; if ($speed -le 0) { $speed = [int]$m.Speed }
        $loc = [string]$m.DeviceLocator; if (-not $loc) { $loc = [string]$m.BankLabel }
        $ff = [int]$m.FormFactor   # 8 = DIMM, 12 = SODIMM; anything else (0 unknown, 11 row of chips...) = soldered on the board
        if ($ff -eq 8 -or $ff -eq 12) { $socketed++ }
        $gb = [math]::Round([double]$m.Capacity / 1GB, 1); $totalGB += $gb
        $list += @{ slot = $loc.Trim(); sizeGB = $gb; speedMHz = $speed; maker = ([string]$m.Manufacturer).Trim(); part = ([string]$m.PartNumber).Trim(); formFactor = $ff }
    }
    # Soldered LPDDR reports each memory channel as a "device": slots don't mean anything there, say "soldered" instead.
    $soldered = ($mods.Count -gt 0 -and $socketed -eq 0)
    return @{ used = $mods.Count; total = $total; modules = $list; soldered = $soldered; totalGB = [math]::Round($totalGB, 1) }
}

# Pure: "AzureAdJoined : YES" style lines from dsregcmd /status.
function ConvertFrom-WkDsreg([string]$Text) {
    $r = @{ entra = $null; domain = $null; domainName = $null; tenant = $null }
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -match '^\s*AzureAdJoined\s*:\s*(\w+)') { $r.entra = ($Matches[1] -eq 'YES') }
        elseif ($line -match '^\s*DomainJoined\s*:\s*(\w+)') { $r.domain = ($Matches[1] -eq 'YES') }
        elseif ($line -match '^\s*DomainName\s*:\s*(\S+)') { $r.domainName = $Matches[1] }
        elseif ($line -match '^\s*TenantName\s*:\s*(.+)$') { $r.tenant = $Matches[1].Trim() }
    }
    return $r
}

# Pure: BitLocker protection value of Shell property System.Volume.BitLockerProtection.
function ConvertFrom-WkBitLockerValue($V) {
    switch ([string]$V) { '1' { 'on' } '2' { 'off' } '3' { 'encrypting' } '4' { 'decrypting' } '5' { 'suspended' } '6' { 'locked' } default { 'unknown' } }
}

# Label/value rows for the UI card, the report table and the copy text (uses T for the current language).
function Get-WkDeviceRows($Facts) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $Facts) { return $rows }
    $nr = T 'common.notReported'
    $rows.Add(@((T 'dev.computerName'), [string]$Facts.computerName))
    if ($Facts.ram) {
        if ($Facts.ram.soldered) { $rows.Add(@((T 'dev.ram'), (T 'dev.ramSoldered' $Facts.ram.totalGB))) }
        else { $rows.Add(@((T 'dev.ram'), (T 'dev.ramSlots' $Facts.ram.used $Facts.ram.total $Facts.ram.totalGB))) }
        if (-not $Facts.ram.soldered) {
            foreach ($m in @($Facts.ram.modules)) { $rows.Add(@('  ', (T 'dev.module' $m.slot $m.sizeGB $m.speedMHz $m.maker))) }
        }
    } else { $rows.Add(@((T 'dev.ram'), $nr)) }
    $v = $nr; if ($Facts.installDate) { $v = [string]$Facts.installDate }; $rows.Add(@((T 'dev.installDate'), $v))
    if ($Facts.originalInstallDate -and $Facts.originalInstallDate -ne $Facts.installDate) { $rows.Add(@((T 'dev.originalInstall'), [string]$Facts.originalInstallDate)) }
    if ($Facts.lastBoot) { $rows.Add(@((T 'dev.lastBoot'), [string]$Facts.lastBoot)) }
    $v = $nr; if ($true -eq $Facts.activated) { $v = T 'dev.activated' } elseif ($false -eq $Facts.activated) { $v = T 'dev.notActivated' }; $rows.Add(@((T 'dev.activation'), $v))
    $rows.Add(@((T 'dev.bitlocker'), (T ('dev.bl.' + [string]$Facts.bitlocker))))
    $v = $nr; if ($true -eq $Facts.secureBoot) { $v = T 'dev.on' } elseif ($false -eq $Facts.secureBoot) { $v = T 'dev.off' }; $rows.Add(@((T 'dev.secureBoot'), $v))
    $v = $nr; if ($Facts.tpm) { if ($Facts.tpm.present) { $v = T 'dev.tpmPresent' $Facts.tpm.version } else { $v = T 'dev.tpmNone' } }; $rows.Add(@((T 'dev.tpm'), $v))
    $v = $nr
    if ($Facts.join) {
        $parts = @()
        if ($Facts.join.entra) { $t = ''; if ($Facts.join.tenant) { $t = ' - ' + $Facts.join.tenant }; $parts += (T 'dev.joinEntra' $t) }
        if ($Facts.join.domain) { $parts += (T 'dev.joinDomain' $Facts.join.domainName) }
        if ($parts.Count -gt 0) { $v = $parts -join ' + ' } else { $v = T 'dev.joinNone' }
    }
    $rows.Add(@((T 'dev.join'), $v))
    return $rows
}

function Invoke-WkCapture([string]$File, [string]$Arguments, [int]$TimeoutMs = 10000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File; $psi.Arguments = $Arguments; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return $null }
    return $out.Result
}

function Get-WkDeviceFacts {
    Invoke-WkSafe 'devicefacts' {
        $f = [ordered]@{ computerName = $env:COMPUTERNAME }
        # RAM slots
        try {
            $arr = @(Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop | ForEach-Object { $_.MemoryDevices })
            $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
            $f.ram = Get-WkRamSlots $arr $mods
        } catch { $f.ram = $null }
        # Windows install dates: current install (reset by feature upgrades) + original (earliest "Source OS" entry)
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $f.installDate = $os.InstallDate.ToString('yyyy-MM-dd')
            $f.lastBoot = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
            $orig = $os.InstallDate
            foreach ($k in @(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Source OS*' })) {
                $v = (Get-ItemProperty -LiteralPath $k.PSPath -Name InstallDate -ErrorAction SilentlyContinue).InstallDate
                if ($v) { $d = [DateTimeOffset]::FromUnixTimeSeconds([long]$v).LocalDateTime; if ($d -lt $orig) { $orig = $d } }
            }
            $f.originalInstallDate = $orig.ToString('yyyy-MM-dd')
        } catch { }
        # Activation (Windows only)
        try {
            $lic = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)
            $f.activated = (@($lic | Where-Object { [int]$_.LicenseStatus -eq 1 }).Count -gt 0)
        } catch { $f.activated = $null }
        # BitLocker on C: (non-admin via the shell property; admin fallback)
        $f.bitlocker = 'unknown'
        try { $f.bitlocker = ConvertFrom-WkBitLockerValue ((New-Object -ComObject Shell.Application).NameSpace('C:').Self.ExtendedProperty('System.Volume.BitLockerProtection')) } catch { }
        if ($f.bitlocker -eq 'unknown') { try { $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop; if ($bl.ProtectionStatus -eq 'On') { $f.bitlocker = 'on' } else { $f.bitlocker = 'off' } } catch { } }
        # Secure Boot (registry, non-admin)
        try {
            $sb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled
            $f.secureBoot = ([int]$sb -eq 1)
        } catch { $f.secureBoot = $null }
        # TPM (admin class; non-admin: the PnP security device)
        $f.tpm = $null
        try {
            $t = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm -ErrorAction Stop
            if ($t) { $f.tpm = @{ present = $true; version = ([string]$t.SpecVersion).Split(',')[0].Trim() } }
        } catch { }
        if (-not $f.tpm) {
            try {
                $pd = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='SecurityDevices'" -ErrorAction Stop | Where-Object { $_.Name -match 'Trusted Platform' }) | Select-Object -First 1
                if ($pd) { $ver = ''; if ($pd.Name -match '(\d\.\d)') { $ver = $Matches[1] }; $f.tpm = @{ present = $true; version = $ver } } else { $f.tpm = @{ present = $false; version = '' } }
            } catch { }
        }
        # Join state
        try {
            $txt = Invoke-WkCapture (Join-Path $env:WINDIR 'System32\dsregcmd.exe') '/status' 10000
            if ($txt) { $f.join = ConvertFrom-WkDsreg $txt }
        } catch { }
        if (-not $f.join) {
            try { $cs = Get-CimInstance Win32_ComputerSystem; $f.join = @{ entra = $null; domain = [bool]$cs.PartOfDomain; domainName = [string]$cs.Domain; tenant = $null } } catch { }
        }
        $f
    }
}
