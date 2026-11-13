# Pure UI decisions (2.6.0): no WPF here, so tests\Run-Tests.ps1 can check them. Dot-sourced by Ui.ps1. ASCII only.

# Checklist progress. $Manual = map item -> 'ok' | 'fail' | physical list | $null.
# Returns @{ done; total; failed; open = item ids not checked yet }.
function Get-WkManualProgress($Manual, $Rules) {
    $items = @($Rules.manual_checks | ForEach-Object { [string]$_ })
    $done = 0; $failed = 0; $open = @()
    foreach ($it in $items) {
        $v = $null
        if ($Manual -is [Collections.IDictionary]) { $v = $Manual[$it] } elseif ($Manual) { $v = $Manual.$it }
        if ($it -eq 'physical') {
            $ps = $null; if (Get-Command Get-WkPhysicalStatus -ErrorAction SilentlyContinue) { $ps = Get-WkPhysicalStatus $v $Rules }
            if ($ps) { $done++; if ($ps -eq 'red') { $failed++ } } else { $open += $it }
            continue
        }
        if ($v -eq 'ok') { $done++ } elseif ($v -eq 'fail') { $done++; $failed++ } else { $open += $it }
    }
    return @{ done = $done; total = $items.Count; failed = $failed; open = $open }
}

# The 5-step bar (#8). $In: checksStarted, checks (has battery/disks/drivers/updates), verdict, stress, manual, rules,
# reportSaved, dirty, reached (map screen -> $true). Returns ordered list of @{ id; screen; state; sub; reachable }.
# state: pending | busy | green | amber | red
function Get-WkStepStates($In) {
    $steps = New-Object System.Collections.Generic.List[object]
    $reached = $In.reached; if (-not $reached) { $reached = @{} }
    $steps.Add(@{ id = 'home'; screen = 'ScreenHome'; state = 'green'; sub = ''; reachable = $true })

    # automatic checks
    $st = 'pending'; $sub = ''
    if ($In.checksStarted) {
        $have = @(@('battery', 'disks', 'drivers', 'updates') | Where-Object { $In.checks -and $In.checks[$_] })
        if ($have.Count -lt 4) { $st = 'busy'; $sub = ('{0}/4' -f $have.Count) }
        else {
            $worst = 'green'
            foreach ($k in @('battery', 'disks', 'drivers', 'updates')) {
                $s = [string]$In.verdict.$k.status
                if ($s -eq 'red') { $worst = 'red' } elseif ($s -eq 'amber' -and $worst -ne 'red') { $worst = 'amber' }
            }
            $st = $worst
        }
    }
    $steps.Add(@{ id = 'checks'; screen = 'ScreenChecks'; state = $st; sub = $sub; reachable = [bool]($In.checksStarted -and $reached['ScreenChecks']) })

    # stress
    $kinds = @('cpu', 'ram', 'disk', 'gpu'); $res = @()
    foreach ($k in $kinds) { $r = 'notRun'; if ($In.stress -and $In.stress[$k] -and $In.stress[$k].result) { $r = [string]$In.stress[$k].result }; $res += $r }
    $completed = @($res | Where-Object { $_ -eq 'completed' }).Count
    $ran = @($res | Where-Object { $_ -ne 'notRun' }).Count
    $st = 'pending'; $sub = ''
    if ($res -contains 'running') { $st = 'busy' }
    elseif (@($res | Where-Object { $_ -eq 'errors' -or $_ -eq 'crashed' }).Count -gt 0) { $st = 'red' }
    elseif ($completed -eq 4) { $st = 'green' }
    elseif ($ran -gt 0) { $st = 'amber' }
    if ($ran -gt 0) { $sub = ('{0}/4' -f $completed) }
    $steps.Add(@{ id = 'stress'; screen = 'ScreenStress'; state = $st; sub = $sub; reachable = [bool]$reached['ScreenStress'] })

    # checklist
    $mp = Get-WkManualProgress $In.manual $In.rules
    $st = 'pending'
    if ($mp.failed -gt 0) { $st = 'red' } elseif ($mp.total -gt 0 -and $mp.done -eq $mp.total) { $st = 'green' } elseif ($mp.done -gt 0) { $st = 'amber' }
    $sub = ''; if ($mp.done -gt 0 -or $reached['ScreenManual']) { $sub = ('{0}/{1}' -f $mp.done, $mp.total) }
    $steps.Add(@{ id = 'manual'; screen = 'ScreenManual'; state = $st; sub = $sub; reachable = [bool]$reached['ScreenManual'] })

    # report
    $st = 'pending'; $sub = ''
    if ($In.reportSaved -and -not $In.dirty) { $st = 'green'; $sub = [string][char]0x2713 } elseif ($In.reportSaved) { $st = 'amber' }
    $steps.Add(@{ id = 'report'; screen = 'ScreenReport'; state = $st; sub = $sub; reachable = [bool]$reached['ScreenReport'] })
    return $steps
}

# Save button (#6): not saved -> "Save" (primary); saved + unchanged -> "Saved" (disabled); saved + changed -> "Update report".
function Get-WkSaveButtonState([bool]$Saved, [bool]$Dirty, [bool]$Saving) {
    if ($Saving) { return @{ key = 'report.saving'; enabled = $false; primary = (-not $Saved); showNew = $Saved } }
    if (-not $Saved) { return @{ key = 'report.save'; enabled = $true; primary = $true; showNew = $false } }
    if ($Dirty) { return @{ key = 'report.update'; enabled = $true; primary = $false; showNew = $true } }
    return @{ key = 'report.savedState'; enabled = $false; primary = $false; showNew = $true }
}

# History filter + sort (#11). $Rows: index.csv rows. $Verdict: '' | green | amber | red. $Range: all | today | week.
function Select-WkHistoryRows([object[]]$Rows, [string]$Query, [string]$Verdict, [string]$Range, [datetime]$Now, [string]$SortKey = 'date', [bool]$Desc = $true) {
    $q = ([string]$Query).Trim()
    $today = $Now.ToString('yyyy-MM-dd')
    $from = $Now.Date.AddDays(-6).ToString('yyyy-MM-dd')
    $out = @(foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $d = [string]$r.date
        if ($Range -eq 'today' -and -not $d.StartsWith($today)) { continue }
        if ($Range -eq 'week' -and $d.Substring(0, [math]::Min(10, $d.Length)) -lt $from) { continue }
        if ($Verdict -and [string]$r.verdict -ne $Verdict) { continue }
        if ($q) {
            $hit = $false
            foreach ($f in @('asset', 'serial', 'model', 'staff')) { if (([string]$r.$f).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true } }
            if (-not $hit) { continue }
        }
        $r
    })
    if (-not $SortKey) { $SortKey = 'date' }
    return @($out | Sort-Object -Property @{ Expression = { [string]$_.$SortKey } } -Descending:$Desc)
}

# Settings screen (2.8.0): text values -> @{ ok; values; bad } (battery/disk 1..100, cycles 1..5000; Persian digits accepted).
function ConvertTo-WkSettings([string]$Battery, [string]$Disk, [string]$Cycles) {
    $bad = @(); $v = @{}
    $b = ConvertTo-WkPercent $Battery; if ($null -eq $b -or $b -lt 1) { $bad += 'battery' } else { $v.batteryMinHealth = [int][math]::Round($b) }
    $dk = ConvertTo-WkPercent $Disk; if ($null -eq $dk -or $dk -lt 1) { $bad += 'disk' } else { $v.diskMinHealth = [int][math]::Round($dk) }
    $c = 0; $ct = ([string]$Cycles).Trim()
    foreach ($i in 0..9) { $ct = $ct.Replace([string][char](0x06F0 + $i), [string]$i).Replace([string][char](0x0660 + $i), [string]$i) }
    if (-not [int]::TryParse($ct, [ref]$c) -or $c -lt 1 -or $c -gt 5000) { $bad += 'cycles' } else { $v.cycleAlarm = $c }
    return @{ ok = ($bad.Count -eq 0); values = $v; bad = $bad }
}

# Window size that fits the screen work area (#7). DIPs in, DIPs out.
function Get-WkWindowSize([double]$WorkWidth, [double]$WorkHeight) {
    $w = [math]::Floor([math]::Min(1100, $WorkWidth * 0.96))
    $h = [math]::Floor([math]::Min(740, $WorkHeight * 0.96))
    return @{ width = [math]::Max(640, $w); height = [math]::Max(480, $h) }
}

# Compact layout flags (#7): short = little height (hide Doki side column, tighter cards); narrow = little width.
function Get-WkCompactMode([double]$Width, [double]$Height) {
    return @{ short = ($Height -gt 0 -and $Height -lt 700); narrow = ($Width -gt 0 -and $Width -lt 1000) }
}
