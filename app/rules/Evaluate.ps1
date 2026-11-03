# Get-WkVerdict: turns collector results (+ stress results) into card statuses and an overall verdict.
# Status values: green | amber | red | grey. Reasons are i18n keys + args (+ optional subject) so the UI and report translate them.
# Works with hashtables (live data) and PSCustomObjects (JSON fixtures) because it only uses dot access.

$global:WkRank = @{ grey = 0; green = 1; amber = 2; red = 3 }

function New-WkReason([string]$Key, [object[]]$ArgList = @(), [string]$Subject = $null) {
    return @{ key = $Key; args = @($ArgList); subject = $Subject }
}

function Get-WkWorst([string[]]$Statuses) {
    $w = 'grey'
    foreach ($s in $Statuses) { if ($global:WkRank[$s] -gt $global:WkRank[$w]) { $w = $s } }
    return $w
}

function Get-WkBatteryVerdict($Res, $Rules) {
    if (-not $Res -or -not $Res.ok) { return @{ status = 'amber'; reasons = @(New-WkReason 'common.couldNotCheck') } }
    $d = $Res.data
    if (-not $d.present) { return @{ status = 'grey'; reasons = @(New-WkReason 'battery.none') } }
    $minH = [double]$Rules.battery.min_health_percent
    $maxC = [int]$Rules.battery.max_cycles
    $reasons = @()
    if ($null -ne $d.healthPercent -and [double]$d.healthPercent -lt $minH) { $reasons += New-WkReason 'battery.reasonHealth' @($d.healthPercent, $minH) }
    if ($null -ne $d.cycles -and [int]$d.cycles -gt $maxC) { $reasons += New-WkReason 'battery.reasonCycles' @($d.cycles, $maxC) }
    if ($reasons.Count -gt 0) { return @{ status = 'red'; reasons = @(@(New-WkReason 'battery.replace') + $reasons) } }
    if ($null -eq $d.healthPercent) { return @{ status = 'amber'; reasons = @(New-WkReason 'battery.unmeasured') } }
    return @{ status = 'green'; reasons = @(New-WkReason 'battery.ok') }
}

# Manual disk % typed by the technician (from SSD Life / HDD Sentinel). Accepts Persian/Arabic digits, "%" and decimals.
# Returns a double 0..100, or $null when empty/invalid (invalid input is ignored, never an error).
function ConvertTo-WkPercent($Text) {
    if ($null -eq $Text) { return $null }
    $s = ([string]$Text).Trim()
    if (-not $s) { return $null }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0x06F0 -and $c -le 0x06F9) { [void]$sb.Append([char](48 + $c - 0x06F0)) }       # Persian digits
        elseif ($c -ge 0x0660 -and $c -le 0x0669) { [void]$sb.Append([char](48 + $c - 0x0660)) }   # Arabic-Indic digits
        elseif ($c -eq 0x066B -or $ch -eq ',' -or $ch -eq '/') { [void]$sb.Append('.') }           # decimal separators
        elseif ($ch -eq '%' -or $c -eq 0x066A -or $ch -eq ' ') { }                                 # percent signs, spaces
        else { [void]$sb.Append($ch) }
    }
    $v = 0.0
    if (-not [double]::TryParse($sb.ToString(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $null }
    if ($v -lt 0 -or $v -gt 100) { return $null }
    return [math]::Round($v, 1)
}

# $Manual: optional @{ percent = '96'; source = 'SSD Life' } for this disk. A valid manual % overrides the automatic one.
function Get-WkDiskRowStatus($Row, $Rules, $Manual = $null) {
    $minH = [double]$Rules.disk.min_health_percent
    $manualPct = $null; $source = $null
    if ($Manual) { $manualPct = ConvertTo-WkPercent $Manual.percent; $source = [string]$Manual.source }
    $used = $null; $pct = $null
    if ($null -ne $manualPct) { $pct = $manualPct; $used = 'manual' }
    elseif ($null -ne $Row.healthPercent) { $pct = [double]$Row.healthPercent; $used = 'auto' }
    $eff = @{ percent = $pct; used = $used; manual = $manualPct; auto = $Row.healthPercent; source = $source }
    $hs = [string]$Row.healthStatus
    if (($hs -and $hs -ne 'Healthy') -or ([long]$Row.readErrorsUncorrected -gt 0) -or ([long]$Row.writeErrorsUncorrected -gt 0) -or ([int]$Row.criticalWarning -gt 0)) {
        return @{ status = 'red'; reason = (New-WkReason 'disk.failing' @() $Row.name); effective = $eff }
    }
    if ($null -eq $pct) { return @{ status = 'amber'; reason = (New-WkReason 'disk.noPercent' @() $Row.name); effective = $eff } }
    if ([long]$Row.mediaErrors -gt 0) { return @{ status = 'amber'; reason = (New-WkReason 'disk.mediaErrors' @([long]$Row.mediaErrors) $Row.name); effective = $eff } }
    if ($pct -lt $minH) { return @{ status = 'amber'; reason = (New-WkReason 'disk.low' @($minH) $Row.name); effective = $eff } }
    return @{ status = 'green'; reason = (New-WkReason 'disk.ok' @() $Row.name); effective = $eff }
}

# $Manual: optional map disk index ("0","1",...) -> @{ percent; source } (hashtable or JSON object).
function Get-WkDisksVerdict($Res, $Rules, $Manual = $null) {
    if (-not $Res -or -not $Res.ok) { return @{ status = 'amber'; reasons = @(New-WkReason 'common.couldNotCheck'); rows = @(); effective = @() } }
    $disks = @($Res.data.disks | Where-Object { $_ })
    if ($disks.Count -eq 0) { return @{ status = 'amber'; reasons = @(New-WkReason 'disk.none'); rows = @(); effective = @() } }
    $rows = @(); $reasons = @(); $sts = @(); $effs = @()
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $m = $null
        if ($Manual) { $m = $Manual.([string]$i) }
        $rs = Get-WkDiskRowStatus $disks[$i] $Rules $m
        $rows += $rs.status; $sts += $rs.status; $reasons += $rs.reason; $effs += $rs.effective
    }
    return @{ status = (Get-WkWorst $sts); reasons = $reasons; rows = $rows; effective = $effs }
}

function Get-WkDriversVerdict($Res, $Rules) {
    if (-not $Res -or -not $Res.ok) { return @{ status = 'amber'; reasons = @(New-WkReason 'common.couldNotCheck'); alarm = @(); info = @() } }
    $infoCodes = @($Rules.drivers.info_codes | ForEach-Object { [int]$_ })
    $alarm = @(); $info = @()
    foreach ($d in @($Res.data.devices | Where-Object { $_ })) {
        if ($infoCodes -contains [int]$d.code) { $info += $d } else { $alarm += $d }
    }
    if ($alarm.Count -gt 0) { return @{ status = 'red'; reasons = @(New-WkReason 'drivers.missing' @($alarm.Count)); alarm = $alarm; info = $info } }
    return @{ status = 'green'; reasons = @(New-WkReason 'drivers.ok'); alarm = $alarm; info = $info }
}

function Get-WkUpdatesVerdict($Res, $Rules) {
    if (-not $Res -or -not $Res.ok) { return @{ status = 'amber'; reasons = @(New-WkReason 'updates.unknown') } }
    $d = $Res.data
    $sts = @(); $reasons = @()
    if ($d.rebootRequired) { $sts += [string]$Rules.updates.pending_reboot_status; $reasons += New-WkReason 'updates.reboot' }
    if (-not $d.checked) { $sts += 'amber'; $reasons += New-WkReason 'updates.unknown' }
    elseif ([int]$d.pendingCount -gt 0) { $sts += [string]$Rules.updates.pending_updates_status; $reasons += New-WkReason 'updates.pending' @([int]$d.pendingCount) }
    if ($sts.Count -eq 0) { return @{ status = 'green'; reasons = @(New-WkReason 'updates.ok') } }
    return @{ status = (Get-WkWorst $sts); reasons = $reasons }
}

# Stress: hashtable kind -> @{ result = completed|errors|crashed|stopped|unavailable|notRun|running; ... } or $null.
$global:WkStressKinds = @('cpu', 'ram', 'disk', 'gpu')

function Get-WkStressVerdict($Stress) {
    $sts = @(); $reasons = @()
    foreach ($k in $global:WkStressKinds) {
        $res = 'notRun'
        if ($Stress -and $Stress.$k -and $Stress.$k.result) { $res = [string]$Stress.$k.result }
        switch ($res) {
            'completed' { $sts += 'green' }
            { $_ -eq 'errors' -or $_ -eq 'crashed' } { $sts += 'red'; $reasons += New-WkReason 'stress.reasonBad' @(('stress.' + $k), ('stress.' + $res)) }
            default { $sts += 'amber'; $reasons += New-WkReason 'stress.reasonNotDone' @(('stress.' + $k)) }
        }
    }
    return @{ status = (Get-WkWorst $sts); reasons = $reasons }
}

# Manual checklist (Phase 3, P1): $Manual = map item -> 'ok' | 'fail' | $null. Only evaluated when the UI supplies it
# ($Checks.manual present), so self-test / old reports are unaffected. fail -> red, not checked -> amber.
function Get-WkManualVerdict($Manual, $Rules) {
    if ($null -eq $Manual) { return $null }
    $items = @($Rules.manual_checks)
    $reasons = @(); $sts = @(); $notChecked = 0
    foreach ($it in $items) {
        $val = [string]$Manual.([string]$it)
        if ($it -eq 'physical') {
            # Phase 10: multi-select condition (Grade.ps1). Breakage = red, cosmetic only = green, nothing = not checked.
            $ps = Get-WkPhysicalStatus $val $Rules
            if ($ps -eq 'red') { $sts += 'red'; $reasons += New-WkReason 'manual.reasonFail' @(('manual.' + $it)) }
            elseif ($ps) { $sts += $ps } else { $sts += 'amber'; $notChecked++ }
            continue
        }
        if ($val -eq 'ok') { $sts += 'green' }
        elseif ($val -eq 'fail') { $sts += 'red'; $reasons += New-WkReason 'manual.reasonFail' @(('manual.' + $it)) }
        else { $sts += 'amber'; $notChecked++ }
    }
    if ($notChecked -gt 0) { $reasons += New-WkReason 'manual.reasonNotChecked' @($notChecked) }
    if ($sts.Count -eq 0) { return @{ status = 'grey'; reasons = @() } }
    return @{ status = (Get-WkWorst $sts); reasons = $reasons }
}

# Phase 11: may the technician press OK / Problem yet? $Progress = map item -> 'started' | 'done' (helper tests).
# Gate "full": Problem after the test was started, OK only after it ran to the end. "open": both once started. No gate: both. Pure.
function Get-WkManualGate([string]$Item, $Progress, $Rules) {
    $mode = ''
    if ($Rules -and $Rules.manual_gates) { $mode = [string]$Rules.manual_gates.$Item }
    $p = ''; if ($Progress) { $p = [string]$Progress.$Item }
    $started = ($p -eq 'started' -or $p -eq 'done')
    switch ($mode) {
        'full' { return @{ ok = ($p -eq 'done'); fail = $started; locked = ($p -ne 'done') } }
        'open' { return @{ ok = $started; fail = $started; locked = -not $started } }
        default { return @{ ok = $true; fail = $true; locked = $false } }
    }
}

function Get-WkVerdict($Checks, $Stress, $Rules) {
    $v = [ordered]@{}
    $v.battery = Get-WkBatteryVerdict $Checks.battery $Rules
    $v.disks = Get-WkDisksVerdict $Checks.disks $Rules $Checks.diskManual
    $v.drivers = Get-WkDriversVerdict $Checks.drivers $Rules
    $v.updates = Get-WkUpdatesVerdict $Checks.updates $Rules
    $v.stress = Get-WkStressVerdict $Stress
    $cards = @('battery', 'disks', 'drivers', 'updates', 'stress')
    $mv = Get-WkManualVerdict $Checks.manual $Rules
    if ($mv) { $v.manual = $mv; $cards += 'manual' }
    $worst = Get-WkWorst @($cards | ForEach-Object { $v[$_].status })
    $overall = 'green'
    if ($worst -eq 'red') { $overall = 'red' } elseif ($worst -eq 'amber') { $overall = 'amber' }
    $reasons = @()
    foreach ($card in $cards) {
        if ($v[$card].status -eq 'red' -or $v[$card].status -eq 'amber') {
            foreach ($r in $v[$card].reasons) {
                if ($r.key -notmatch '\.(ok)$') { $reasons += @{ key = $r.key; args = $r.args; subject = $r.subject; card = $card; status = $v[$card].status } }
            }
        }
    }
    $v.overall = @{ status = $overall; reasons = $reasons }
    return $v
}
