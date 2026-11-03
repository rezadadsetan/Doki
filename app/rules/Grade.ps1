# Phase 10 (D-030): physical condition (multi-select) and the S / A+ / A / B grade. Pure functions, numbers in rules.json grading.
# ASCII only. Works with hashtables (live) and PSCustomObjects (JSON) like Evaluate.ps1.

$global:WkGradeOrder = @('B', 'A', 'A+', 'S')   # weakest -> best

function Get-WkGradingRules($Rules) {
    if ($Rules -and $Rules.grading) { return $Rules.grading }
    return (Get-WkRules).grading
}

# "ok" | "sticker,scratch" | old "fail" -> ordered list of known ids. Unknown ids are dropped.
function ConvertTo-WkPhysicalList($Value, $Rules = $null) {
    $known = @('ok', 'sticker', 'scratch', 'broken')
    $g = $null; try { $g = Get-WkGradingRules $Rules } catch { }
    if ($g -and $g.physical) { $known = @($g.physical | ForEach-Object { [string]$_ }) }
    $s = [string]$Value
    if (-not $s.Trim()) { return @() }
    if ($s.Trim() -eq 'fail') { return @('broken') }
    $parts = @($s.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $out = @($known | Where-Object { $parts -contains $_ })
    if ($out -contains 'ok' -and $out.Count -gt 1) { $out = @($out | Where-Object { $_ -ne 'ok' }) }   # a defect wins over "healthy"
    return $out
}

# Toggle one option in the stored value: "ok" is exclusive, a selected option is cleared again. Returns the new string ('' = none).
function Switch-WkPhysicalOption($Value, [string]$Option, $Rules = $null) {
    $list = @(ConvertTo-WkPhysicalList $Value $Rules)
    if ($list -contains $Option) { $list = @($list | Where-Object { $_ -ne $Option }) }
    elseif ($Option -eq 'ok') { $list = @('ok') }
    else { $list = @(@($list | Where-Object { $_ -ne 'ok' }) + $Option) }
    return ((ConvertTo-WkPhysicalList ($list -join ',') $Rules) -join ',')
}

# $null = not checked, red = breakage, green = healthy or cosmetic only (cosmetic lowers the grade, not the verdict).
function Get-WkPhysicalStatus($Value, $Rules = $null) {
    $list = @(ConvertTo-WkPhysicalList $Value $Rules)
    if ($list.Count -eq 0) { return $null }
    if ($list -contains 'broken') { return 'red' }
    return 'green'
}

function Get-WkBandFactor([double]$Value, $Bands) {
    foreach ($b in @($Bands | Sort-Object { [double]$_.min } -Descending)) { if ($Value -ge [double]$b.min) { return [double]$b.factor } }
    return 0.0
}

function Get-WkStressResult($Stress, [string]$Kind) {
    if ($Stress -and $Stress.$Kind -and $Stress.$Kind.result) { return [string]$Stress.$Kind.result }
    return 'notRun'
}

# Returns @{ grade; score; complete; caps = @(@{ id; grade }); rows = @(@{ id; points; max; applicable; noteKey; noteArgs }) }.
function Get-WkGrade($Checks, $Stress, $Verdict, $Rules) {
    $g = Get-WkGradingRules $Rules
    $w = $g.weights
    $rows = New-Object System.Collections.ArrayList
    $caps = New-Object System.Collections.ArrayList
    $add = { param($id, $factor, $applicable, $noteKey, $noteArgs)
        $max = [double]$w.$id
        $f = [math]::Max(0.0, [math]::Min(1.0, [double]$factor))
        [void]$rows.Add(@{ id = $id; max = $max; points = [math]::Round($max * $f, 1); applicable = [bool]$applicable; noteKey = $noteKey; noteArgs = @($noteArgs) })
    }

    # Battery
    $bat = $Checks.battery
    if (-not $bat -or -not $bat.ok) { & $add 'battery' 0.5 $true 'grade.note.unknown' @() }
    elseif (-not $bat.data.present) { & $add 'battery' 0 $false 'grade.note.noBattery' @() }
    elseif ($null -eq $bat.data.healthPercent) { & $add 'battery' 0.5 $true 'grade.note.unknown' @() }
    else {
        $f = Get-WkBandFactor ([double]$bat.data.healthPercent) $g.battery_bands
        $cyc = $bat.data.cycles
        if ($null -ne $cyc -and [int]$cyc -gt [int]$Rules.battery.max_cycles) { $f -= [double]$g.battery_cycles_penalty }
        $cycText = '-'; if ($null -ne $cyc) { $cycText = [string]$cyc }
        & $add 'battery' $f $true 'grade.note.battery' @([string]$bat.data.healthPercent, $cycText)
    }
    if ($Verdict.battery -and $Verdict.battery.status -eq 'red') { [void]$caps.Add(@{ id = 'battery'; grade = 'A' }) }

    # Disk: lowest effective health %, a failing disk = 0
    $dv = $Verdict.disks
    $diskRed = @($dv.rows | Where-Object { $_ -eq 'red' }).Count -gt 0
    $pcts = @(@($dv.effective) | Where-Object { $_ -and $null -ne $_.percent } | ForEach-Object { [double]$_.percent })
    if ($diskRed) { & $add 'disk' 0 $true 'grade.note.diskFailing' @(); [void]$caps.Add(@{ id = 'disk'; grade = 'B' }) }
    elseif ($pcts.Count -eq 0) { & $add 'disk' 0.5 $true 'grade.note.unknown' @() }
    else { $min = ($pcts | Measure-Object -Minimum).Minimum; & $add 'disk' (Get-WkBandFactor $min $g.disk_bands) $true 'grade.note.disk' @([string]$min) }

    # Stress: a quarter per test
    $sum = 0.0; $done = 0; $ran = 0; $bad = $false
    foreach ($k in @('cpu', 'ram', 'disk', 'gpu')) {
        $r = Get-WkStressResult $Stress $k
        switch ($r) {
            'completed' { $sum += 1; $done++; $ran++ }
            'unavailable' { $sum += [double]$g.stress_partial.unavailable; $ran++ }
            'stopped' { $sum += [double]$g.stress_partial.stopped; $ran++ }
            { $_ -eq 'errors' -or $_ -eq 'crashed' } { $bad = $true; $ran++ }
        }
    }
    & $add 'stress' ($sum / 4) $true 'grade.note.stress' @($done)
    if ($bad) { [void]$caps.Add(@{ id = 'stress'; grade = 'B' }) }

    # Functional checklist (every manual item except "physical")
    $items = @($Rules.manual_checks | ForEach-Object { [string]$_ } | Where-Object { $_ -ne 'physical' })
    $m = $Checks.manual
    $okN = 0; $answered = 0; $failN = 0
    foreach ($it in $items) {
        $val = ''; if ($m) { $val = [string]$m.$it }
        if ($val -eq 'ok') { $okN++; $answered++ } elseif ($val -eq 'fail') { $failN++; $answered++ }
    }
    $ff = 0.0; if ($items.Count -gt 0) { $ff = $okN / $items.Count }
    & $add 'functional' $ff $true 'grade.note.functional' @($okN, $items.Count)
    if ($failN -gt 0) { [void]$caps.Add(@{ id = 'functional'; grade = 'B' }) }

    # Physical condition
    $physVal = ''; if ($m) { $physVal = [string]$m.physical }
    $phys = @(ConvertTo-WkPhysicalList $physVal $Rules)
    if ($phys.Count -eq 0) { & $add 'physical' 0 $true 'grade.note.notChecked' @() }
    elseif ($phys -contains 'broken') { & $add 'physical' 0 $true 'grade.note.physical' @(, $phys); [void]$caps.Add(@{ id = 'broken'; grade = 'B' }) }
    else {
        $f = 1.0
        foreach ($p in $phys) { if ($p -ne 'ok' -and $g.physical_penalty.$p) { $f -= [double]$g.physical_penalty.$p } }
        & $add 'physical' $f $true 'grade.note.physical' @(, $phys)
        if (@($phys | Where-Object { $_ -ne 'ok' }).Count -gt 0) { [void]$caps.Add(@{ id = 'cosmetic'; grade = 'A+' }) }
    }

    # Drivers
    $drv = $Checks.drivers
    if (-not $drv -or -not $drv.ok) { & $add 'drivers' 0.5 $true 'grade.note.unknown' @() }
    else { $n = @($Verdict.drivers.alarm | Where-Object { $_ }).Count; & $add 'drivers' (1 - $n * [double]$g.driver_penalty_each) $true 'grade.note.drivers' @($n) }

    # Windows Update
    $us = [string]$Verdict.updates.status
    $uf = @{ green = 1.0; amber = 0.5; red = 0.0 }[$us]; if ($null -eq $uf) { $uf = 0.5 }
    & $add 'updates' $uf $true ('grade.note.updates.' + $us) @()

    # Score normalised over the applicable categories
    $pts = 0.0; $max = 0.0
    foreach ($r in $rows) { if ($r.applicable) { $pts += $r.points; $max += $r.max } }
    $score = 0; if ($max -gt 0) { $score = [int][math]::Round($pts / $max * 100) }
    $grade = Get-WkGradeForScore $score $g.thresholds
    foreach ($c in $caps) { if ($global:WkGradeOrder.IndexOf([string]$c.grade) -lt $global:WkGradeOrder.IndexOf($grade)) { $grade = [string]$c.grade } }

    $answeredPhys = 0; if ($phys.Count -gt 0) { $answeredPhys = 1 }
    $complete = ($ran -eq 4) -and ($answered -eq $items.Count) -and ($answeredPhys -eq 1)
    return @{ grade = $grade; score = $score; points = [math]::Round($pts, 1); max = $max; complete = $complete; caps = @($caps); rows = @($rows) }
}

function Get-WkGradeForScore([int]$Score, $Thresholds) {
    if ($Score -ge [int]$Thresholds.S) { return 'S' }
    if ($Score -ge [int]$Thresholds.'A+') { return 'A+' }
    if ($Score -ge [int]$Thresholds.A) { return 'A' }
    return 'B'
}

# i18n key suffix for a grade (keys cannot rely on '+').
function Get-WkGradeKeyId([string]$Grade) { if ($Grade -eq 'A+') { return 'Aplus' }; return $Grade }

# Ink colours for the tag and stamp.
function Get-WkGradeColor([string]$Grade) {
    switch ($Grade) { 'S' { return '#7B3FE4' } 'A+' { return '#04A85A' } 'A' { return '#028EF9' } default { return '#E0560F' } }
}

# Localised note for a grade row (uses T).
function Format-WkGradeNote($Row) {
    if ($Row.noteKey -eq 'grade.note.physical') {
        $names = @($Row.noteArgs[0] | ForEach-Object { T ('manual.phys.' + $_) })
        return ($names -join ', ')
    }
    $a = @($Row.noteArgs)
    return (T $Row.noteKey @a)
}
