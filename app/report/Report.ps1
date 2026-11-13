# New-WkReport: one self-contained HTML (+ JSON) in Reports\ beside the app (D-004); Desktop fallback when not writable.
# Uses the current UI language (T). Returns the HTML path.

function ConvertTo-WkHtml([object]$Text) {
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Get-WkStatusPill([string]$Status) {
    $key = @{ green = 'report.ok'; amber = 'report.check'; red = 'report.bad'; grey = 'common.na' }[$Status]
    return '<span class="pill st-' + $Status + '">' + (ConvertTo-WkHtml (T $key)) + '</span>'
}

function Format-WkReasonPlain($R) {
    $a = @()
    foreach ($x in @($R.args)) { if ($x -is [string] -and $global:WkStrings.ContainsKey($x)) { $a += (T $x) } else { $a += $x } }
    $t = T $R.key @a
    if ($R.subject) { $t = [string]$R.subject + ': ' + $t }
    return $t
}

function New-WkKvTable([object[]]$Pairs) {
    $h = '<table class="kv">'
    for ($i = 0; $i -lt $Pairs.Count; $i += 2) {
        $h += '<tr><td>' + (ConvertTo-WkHtml $Pairs[$i]) + '</td><td class="ltr">' + (ConvertTo-WkHtml $Pairs[$i + 1]) + '</td></tr>'
    }
    return $h + '</table>'
}

# ASCII, filesystem-safe slug for file names (Persian or other non-ASCII text becomes '-' and is collapsed).
function Get-WkSafeName([string]$S, [int]$Max = 30) {
    if (-not $S) { return 'NA' }
    $o = [regex]::Replace($S.Trim(), '[^A-Za-z0-9._-]+', '-').Trim('-', '.')
    if (-not $o) { return 'NA' }
    if ($o.Length -gt $Max) { $o = $o.Substring(0, $Max).TrimEnd('-', '.') }
    return $o
}

function Test-WkWritableDir([string]$Dir) {
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Dir ('.probe_' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# D-012: staff -> paths.staff_root\<yyyy-MM-dd>\ (fallbacks: Public Documents, then Reports\ beside the app);
# guest -> paths.guest_root (fallbacks: Documents, then Reports\). index.csv lives in the chosen root.
# Created lazily (only when a report is saved). Returns @{ root; dir; intended; fallback }.
function Get-WkReportTarget([string]$Role, [datetime]$Now) {
    $p = $null
    try { $p = (Get-WkRules).paths } catch { }
    $roots = @()
    if ($Role -eq 'guest') {
        if ($p -and $p.guest_root) { $roots += [string]$p.guest_root } else { $roots += '%USERPROFILE%\Desktop\Doki Reports' }
        if ($p) { $roots += @($p.guest_fallbacks | ForEach-Object { [string]$_ }) }
    } else {
        if ($p -and $p.staff_root) { $roots += [string]$p.staff_root } else { $roots += '%USERPROFILE%\Desktop\Doki Reports' }
        if ($p) { $roots += @($p.staff_fallbacks | ForEach-Object { [string]$_ }) }
    }
    $roots += (Join-Path $global:WkRoot 'Reports')
    $roots = @($roots | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
    $intended = $roots[0]
    foreach ($r in $roots) {
        $dir = $r
        if ($Role -ne 'guest') { $dir = Join-Path $r $Now.ToString('yyyy-MM-dd') }
        if (Test-WkWritableDir $dir) {
            if ($r -ne $intended) { Write-WkLog ('report root not writable: ' + $intended + ' -> using ' + $r) 'WARN' }
            return @{ root = $r; dir = $dir; intended = $intended; fallback = ($r -ne $intended) }
        }
    }
    # Last resort: TEMP (never fail a report because of folders).
    $t = Join-Path $env:TEMP 'Doki Reports'
    [void](Test-WkWritableDir $t)
    return @{ root = $t; dir = $t; intended = $intended; fallback = $true }
}

# All index.csv files this machine may have written (both roles, all fallbacks, Reports\ beside the app).
function Get-WkReportIndexFiles {
    $p = $null; try { $p = (Get-WkRules).paths } catch { }
    $roots = @()
    if ($p) {
        $roots += [string]$p.staff_root; $roots += @($p.staff_fallbacks | ForEach-Object { [string]$_ })
        $roots += [string]$p.guest_root; $roots += @($p.guest_fallbacks | ForEach-Object { [string]$_ })
    }
    $roots += (Join-Path $global:WkRoot 'Reports')
    $roots += (Join-Path $env:TEMP 'Doki Reports')
    $files = @()
    foreach ($r in $roots) {
        if (-not $r) { continue }
        $f = Join-Path ([Environment]::ExpandEnvironmentVariables($r)) 'index.csv'
        if ((Test-Path -LiteralPath $f) -and ($files -notcontains $f)) { $files += $f }
    }
    return $files
}

# Rows from all index files, newest first. Never throws (a broken file is skipped and logged).
function Get-WkReportIndexRows([string[]]$Files = $null) {
    if ($null -eq $Files) { $Files = Get-WkReportIndexFiles }
    $rows = @()
    foreach ($f in $Files) {
        try { $rows += @(Import-Csv -LiteralPath $f -Encoding UTF8) } catch { Write-WkLog ('index read failed: ' + $f + ': ' + $_.Exception.Message) 'WARN' }
    }
    return @($rows | Where-Object { $_ -and $_.date } | Sort-Object -Property date -Descending)
}

# Duplicate guard (warn only): a report for the same asset or serial on the same day. Pure.
function Find-WkSameDayReport([object[]]$Rows, [string]$Asset, [string]$Serial, [string]$Day) {
    foreach ($r in @($Rows)) {
        if (-not ([string]$r.date).StartsWith($Day)) { continue }
        if (($Asset -and [string]$r.asset -eq $Asset) -or ($Serial -and [string]$r.serial -eq $Serial)) { return $r }
    }
    return $null
}

function ConvertTo-WkCsvField($V) {
    if ($null -eq $V) { return '""' }
    $s = [string]$V
    # Security (Phase 10): a field starting with = + - @ (or tab/CR) would run as a formula when index.csv is opened in Excel.
    # Plain negative numbers stay as they are.
    if ($s -match '^[=+\-@\t\r]' -and $s -notmatch '^-\d+([.,]\d+)?$') { $s = "'" + $s }
    return '"' + $s.Replace('"', '""') + '"'
}

# A report path from index.csv may be opened only if it is a local, existing .html/.htm file (no exe, script, URL or UNC share). Pure apart from Test-Path.
function Test-WkReportPathSafe([string]$Path) {
    if (-not $Path) { return $false }
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[<>"|?*]' -or $Path.Contains('..')) { return $false }
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -notin @('.html', '.htm')) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

# Single-pass {{key}} filling: a value that itself contains "{{other}}" is never expanded (no template injection). Pure.
function Format-WkTemplate([string]$Template, [hashtable]$Values) {
    return [regex]::Replace($Template, '\{\{([A-Za-z0-9_]+)\}\}', {
        param($m)
        $k = $m.Groups[1].Value
        if ($Values.ContainsKey($k)) { return [string]$Values[$k] }
        return $m.Value
    })
}

# Physical condition as text: "Sticker residue, Scratches" / "Not checked". Old reports may hold "ok"/"fail".
function Get-WkPhysicalText($Value) {
    $list = @(ConvertTo-WkPhysicalList $Value)
    if ($list.Count -eq 0) { return (T 'manual.notChecked') }
    return ((@($list | ForEach-Object { T ('manual.phys.' + $_) })) -join ', ')
}

function Get-WkGradeSafe($Checks, $Stress, $Verdict) {
    if (-not (Get-Command Get-WkGrade -ErrorAction SilentlyContinue)) { return $null }
    try { return (Get-WkGrade $Checks $Stress $Verdict (Get-WkRules)) } catch { Write-WkLog ('grade failed: ' + $_.Exception.Message) 'WARN'; return $null }
}

# One line: "Grade A+ (86/100)" (+ provisional mark).
function Get-WkGradeLine($Grade) {
    if (-not $Grade) { return '' }
    $t = (T 'grade.tag' $Grade.grade) + ' - ' + (T ('grade.desc.' + (Get-WkGradeKeyId $Grade.grade))) + ' (' + (T 'grade.score' $Grade.score) + ')'
    if (-not $Grade.complete) { $t += ' ' + (T 'grade.provisional') }
    return $t
}

# The stamp: inline SVG, ink colour per grade. Text on the ring is fixed English (a stamp, not UI text).
function Get-WkStampSvg($Grade, [datetime]$When, [string]$Asset) {
    $ink = Get-WkGradeColor $Grade.grade
    $letter = ConvertTo-WkHtml $Grade.grade
    $fs = 74; if ($Grade.grade.Length -gt 1) { $fs = 60 }
    $a = ConvertTo-WkHtml $Asset; if (-not $Asset) { $a = '-' }
    if ($a.Length -gt 16) { $a = $a.Substring(0, 16) }
    return '<svg class="stamp" viewBox="0 0 200 200" width="170" height="170" role="img" aria-label="Doki QC grade ' + $letter + '">' +
        '<defs><path id="stRing" d="M100,100 m-74,0 a74,74 0 1,1 148,0 a74,74 0 1,1 -148,0"/>' +
        '<filter id="stRough"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="7"/><feDisplacementMap in="SourceGraphic" scale="2.2"/></filter></defs>' +
        '<g fill="none" stroke="' + $ink + '" filter="url(#stRough)"><circle cx="100" cy="100" r="94" stroke-width="5"/><circle cx="100" cy="100" r="86" stroke-width="1.6"/><circle cx="100" cy="100" r="58" stroke-width="1.6"/></g>' +
        '<g fill="' + $ink + '" filter="url(#stRough)" style="direction:ltr;unicode-bidi:isolate" font-family="Segoe UI, Arial, sans-serif" font-weight="700">' +
        '<text font-size="15"><textPath href="#stRing" startOffset="0" textLength="458" lengthAdjust="spacing">DOKI QC * QUALITY CHECKED * DOKI QC *</textPath></text>' +
        '<text x="100" y="' + (98 + [int]($fs / 3)) + '" font-size="' + $fs + '" text-anchor="middle">' + $letter + '</text>' +
        '<text x="100" y="62" font-size="11" text-anchor="middle" letter-spacing="2">GRADE</text>' +
        '<text x="100" y="136" font-size="11" text-anchor="middle">' + $When.ToString('yyyy-MM-dd') + '</text>' +
        '<text x="100" y="148" font-size="10" text-anchor="middle">' + $a + '</text></g></svg>'
}

# Keeps "A+" readable inside RTL text (the bidi algorithm would show "+A"). Input is already HTML-encoded.
function Protect-WkGradeBidi([string]$Html) { return $Html.Replace('A+', '<bdi dir="ltr">A+</bdi>') }

# "Grading" table for the end of the report.
function Get-WkGradeTableHtml($Grade) {
    if (-not $Grade) { return '' }
    $h = '<h2>' + (ConvertTo-WkHtml (T 'grade.tableTitle')) + ' <span class="gtag" style="background:' + (Get-WkGradeColor $Grade.grade) + '">' + (Protect-WkGradeBidi (ConvertTo-WkHtml $Grade.grade)) + '</span></h2>'
    $h += '<table class="grade"><tr><th>' + (ConvertTo-WkHtml (T 'grade.colCategory')) + '</th><th>' + (ConvertTo-WkHtml (T 'grade.colResult')) + '</th><th>' + (ConvertTo-WkHtml (T 'grade.colPoints')) + '</th><th>' + (ConvertTo-WkHtml (T 'grade.colMax')) + '</th></tr>'
    foreach ($r in @($Grade.rows)) {
        $p = [string]$r.points; $mx = [string]$r.max
        if (-not $r.applicable) { $p = '-'; $mx = '-' }
        $h += '<tr><td>' + (ConvertTo-WkHtml (T ('grade.cat.' + $r.id))) + '</td><td>' + (ConvertTo-WkHtml (Format-WkGradeNote $r)) + '</td><td class="num">' + $p + '</td><td class="num">' + $mx + '</td></tr>'
    }
    $h += '<tr class="total"><td>' + (ConvertTo-WkHtml (T 'grade.total')) + '</td><td>' + (Protect-WkGradeBidi (ConvertTo-WkHtml (Get-WkGradeLine $Grade))) + '</td><td class="num">' + $Grade.points + '</td><td class="num">' + $Grade.max + '</td></tr></table>'
    if (@($Grade.caps).Count -gt 0) {
        $h += '<p class="note">' + (ConvertTo-WkHtml (T 'grade.capsTitle')) + ': ' + ((@($Grade.caps) | ForEach-Object { Protect-WkGradeBidi (ConvertTo-WkHtml (T ('grade.cap.' + $_.id))) }) -join ' &middot; ') + '</p>'
    }
    $th = (Get-WkRules).grading.thresholds
    $legend = T 'grade.legend' $th.S $th.'A+' $th.A
    if ($null -ne $th.B -and $null -ne $th.C) { $legend = T 'grade.legend6' $th.S $th.'A+' $th.A $th.B $th.C }
    $h += '<p class="note">' + (Protect-WkGradeBidi (ConvertTo-WkHtml $legend)) + '</p>'
    return $h
}

# ---------------- warranty return (2.7.0, org feature "warranty") ----------------

function Get-WkWarrantySafe($Grade, $Checks = $null) {
    if (-not $Grade -or -not (Get-Command Test-WkFeature -ErrorAction SilentlyContinue) -or -not (Test-WkFeature 'warranty')) { return $null }
    $o = Get-WkOrg
    if (-not $o -or -not $o.warranty) { return $null }
    $dec = $null; if ($Checks) { $dec = [string]$Checks.cosmeticDecision }
    return (Get-WkWarrantyDecision $Grade $o.warranty $dec)
}

function Format-WkWarrantyReasons($W) {
    return ((@($W.reasons) | ForEach-Object { T ('warranty.reason.' + $_.id) $_.arg }) -join ', ')
}

# ---------------- contractor one-page summary (2.7.0, org feature "contractorLabel") ----------------
# One A4 page (2.8.0) to print and stick on / keep with the device: everything useful, nothing long.
function New-WkSummaryHtml($Checks, $Stress, $Verdict, $Grade, $Warranty, [string]$Technician, [string]$Asset, [datetime]$When, [string]$Notes = '') {
    $h = { param($t) ConvertTo-WkHtml $t }
    $dir = 'rtl'; if (-not (Test-WkRtl)) { $dir = 'ltr' }
    $sys = $null; if ($Checks.system -and $Checks.system.ok) { $sys = $Checks.system.data }
    $model = ''; $serial = ''; $cpu = ''; $ram = ''; $os = ''
    if ($sys) { $model = (([string]$sys.manufacturer + ' ' + [string]$sys.model).Trim()); $serial = [string]$sys.serial; $cpu = [string]$sys.cpu; $ram = [string]$sys.ramGB + ' GB'; $os = ([string]$sys.os + ' ' + [string]$sys.build).Trim() }
    $pill = { param($st, $txt) $c = @{ green = '#04A85A'; amber = '#E0560F'; red = '#E5484D' }[[string]$st]; if (-not $c) { $c = '#6B7080' }; '<span class="p" style="color:' + $c + ';border-color:' + $c + '">' + (& $h $txt) + '</span>' }

    # results: battery, disk, drivers, updates, each stress test
    $res = ''
    $bat = '-'
    if ($Checks.battery -and $Checks.battery.ok -and $Checks.battery.data.present) {
        $b = $Checks.battery.data; $parts = @()
        if ($null -ne $b.healthPercent) { $parts += ([string]$b.healthPercent + '%') }
        if ($null -ne $b.cycles) { $parts += ([string]$b.cycles + ' ' + (T 'battery.cycles')) }
        $bat = $parts -join ' · '
    } elseif ($Checks.battery -and $Checks.battery.ok) { $bat = T 'battery.none' }
    $res += '<tr><td>' + (& $h (T 'battery.title')) + '</td><td>' + (& $pill $Verdict.battery.status (Get-WkStatusWord $Verdict.battery.status)) + '</td><td class="ltr">' + (& $h $bat) + '</td></tr>'
    $disk = '-'
    if ($Checks.disks -and $Checks.disks.ok) {
        $dl = @($Checks.disks.data.disks | Where-Object { $_ }); $ef = @($Verdict.disks.effective); $parts = @()
        for ($i = 0; $i -lt $dl.Count; $i++) {
            $pct = '?'; if ($i -lt $ef.Count -and $ef[$i] -and $null -ne $ef[$i].percent) { $pct = [string]$ef[$i].percent + '%' }
            $parts += ([string]$dl[$i].busType + ' ' + [string]$dl[$i].sizeGB + ' GB ' + $pct)
        }
        $disk = $parts -join ' | '
    }
    $res += '<tr><td>' + (& $h (T 'disk.title')) + '</td><td>' + (& $pill $Verdict.disks.status (Get-WkStatusWord $Verdict.disks.status)) + '</td><td class="ltr">' + (& $h $disk) + '</td></tr>'
    $drvN = @($Verdict.drivers.alarm | Where-Object { $_ }).Count
    $res += '<tr><td>' + (& $h (T 'drivers.title')) + '</td><td>' + (& $pill $Verdict.drivers.status (Get-WkStatusWord $Verdict.drivers.status)) + '</td><td>' + $drvN + '</td></tr>'
    $upd = '-'; if ($Checks.updates -and $Checks.updates.ok -and $Checks.updates.data.checked) { $upd = T 'updates.pending' ([int]$Checks.updates.data.pendingCount) }
    $res += '<tr><td>' + (& $h (T 'updates.title')) + '</td><td>' + (& $pill $Verdict.updates.status (Get-WkStatusWord $Verdict.updates.status)) + '</td><td>' + (& $h $upd) + '</td></tr>'
    foreach ($k in @('cpu', 'ram', 'disk', 'gpu')) {
        $r = Get-WkStressResult $Stress $k
        $st = @{ completed = 'green'; errors = 'red'; crashed = 'red'; stopped = 'amber'; unavailable = 'amber' }[$r]
        $txt = switch ($r) { 'completed' { T 'stress.completed' } 'errors' { T 'stress.errors' $Stress.$k.errors } 'crashed' { T 'stress.crashed' } 'stopped' { T 'stress.stopped' } 'unavailable' { T 'stress.unavailable' '' } default { T 'stress.notRun' } }
        $res += '<tr><td>' + (& $h (T ('stress.' + $k))) + '</td><td colspan="2">' + (& $pill $st $txt) + '</td></tr>'
    }

    # checklist as a compact grid
    $cells = ''
    foreach ($it in @((Get-WkRules).manual_checks | ForEach-Object { [string]$_ })) {
        $val = $null; if ($Checks.manual) { $val = [string]$Checks.manual.$it }
        $name = (T ('manual.' + $it)).Split('(')[0].Trim()
        $st = 'grey'; $txt = T 'manual.notChecked'
        if ($it -eq 'physical') {
            $ps = Get-WkPhysicalStatus $val; $txt = Get-WkPhysicalText $val
            if ($ps -eq 'red') { $st = 'red' } elseif ($ps -and @(ConvertTo-WkPhysicalList $val) -notcontains 'ok') { $st = 'amber' } elseif ($ps) { $st = 'green' }
        } elseif ($val -eq 'ok') { $st = 'green'; $txt = T 'manual.ok' } elseif ($val -eq 'fail') { $st = 'red'; $txt = T 'manual.fail' }
        $cells += '<div class="ci"><span>' + (& $h $name) + '</span>' + (& $pill $st $txt) + '</div>'
    }

    $gradeHtml = ''; $gc = '#6B7080'
    if ($Grade) {
        $gc = Get-WkGradeColor $Grade.grade
        $gradeHtml = '<div class="g" style="background:' + $gc + '"><b>' + (& $h $Grade.grade) + '</b><span>' + (& $h (T ('grade.desc.' + (Get-WkGradeKeyId $Grade.grade)))) + '</span><span>' + (& $h (T 'grade.score' $Grade.score)) + '</span></div>'
    }
    $ov = [string]$Verdict.overall.status
    $verdictHtml = (& $h (T 'report.verdict')) + ': ' + (& $pill $ov (Get-WkStatusWord $ov))
    $war = ''
    if ($Warranty -and $Warranty.reject) { $war = '<div class="war">' + (& $h (T 'warranty.title')) + '<small>' + (& $h (T 'warranty.reasons' (Format-WkWarrantyReasons $Warranty))) + '</small></div>' }
    $dev = ''
    foreach ($kv in @(@((T 'report.asset'), $Asset), @((T 'report.model'), $model), @((T 'report.serial'), $serial), @((T 'report.cpu'), $cpu), @((T 'report.ram'), $ram), @((T 'report.os'), $os))) {
        $v = [string]$kv[1]; if (-not $v) { $v = '-' }
        $dev += '<div class="kv"><span>' + (& $h $kv[0]) + '</span><b class="ltr">' + (& $h $v) + '</b></div>'
    }
    $notesHtml = ''; if ($Notes) { $notesHtml = '<h2>' + (& $h (T 'summary.notes')) + '</h2><p class="notes">' + (& $h $Notes) + '</p>' }
    $css = '@page{size:A4 portrait;margin:12mm}*{box-sizing:border-box}body{margin:0;font-family:"Segoe UI",Tahoma,sans-serif;font-size:10.5pt;color:#252A3C}' +
        '.page{max-width:186mm;margin:0 auto}.top{display:flex;justify-content:space-between;align-items:center;border-bottom:3px solid ' + $gc + ';padding-bottom:3mm}' +
        '.brand{font-weight:700;font-size:18pt;direction:ltr}.muted{color:#6B7080}.g{color:#fff;border-radius:10px;padding:3mm 6mm;text-align:center;min-width:34mm}' +
        '.g b{display:block;font-size:30pt;line-height:1.05;direction:ltr}.g span{display:block;font-size:8.5pt}.v{font-size:13pt;font-weight:700;margin:3mm 0}' +
        '.war{background:#8B1E2D;color:#fff;border-radius:8px;padding:3mm 4mm;font-weight:700;font-size:13pt;margin:2mm 0}.war small{display:block;font-weight:400;font-size:10pt}' +
        '.dev{display:grid;grid-template-columns:1fr 1fr;gap:1mm 6mm;margin:2mm 0}.kv{display:flex;justify-content:space-between;gap:3mm;border-bottom:1px solid #EBECF2;padding:1mm 0}.kv span{color:#6B7080}' +
        'h2{font-size:11.5pt;margin:4mm 0 1.5mm}table{width:100%;border-collapse:collapse}td{padding:1.2mm 1mm;border-bottom:1px solid #EBECF2;vertical-align:middle}td:first-child{width:28%;color:#6B7080}' +
        '.p{display:inline-block;border:1.5px solid;border-radius:9px;padding:0 2.5mm;font-size:9pt;font-weight:600;white-space:nowrap}' +
        '.grid{display:grid;grid-template-columns:1fr 1fr;gap:1mm 6mm}.ci{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #EBECF2;padding:1mm 0;gap:2mm}' +
        '.ltr{direction:ltr;unicode-bidi:isolate}.notes{white-space:pre-wrap;border:1px solid #EBECF2;border-radius:6px;padding:2mm;margin:0}' +
        '.sign{display:flex;justify-content:space-between;margin-top:8mm;gap:10mm}.sign div{flex:1;border-top:1px solid #6B7080;padding-top:1.5mm;color:#6B7080}' +
        '.pb{position:fixed;bottom:10px;inset-inline-start:10px;padding:8px 22px;font-size:12pt}@media print{.pb{display:none}}' +
        '*{-webkit-print-color-adjust:exact;print-color-adjust:exact}'
    return '<!doctype html><html lang="' + $global:WkLang + '" dir="' + $dir + '"><head><meta charset="utf-8"><title>Doki ' + (& $h $Asset) + '</title><style>' + $css + '</style></head><body>' +
        '<button class="pb" onclick="window.print()">' + (& $h (T 'summary.print')) + '</button><div class="page">' +
        '<div class="top"><div><div class="brand">Doki QC</div><div class="muted">' + (& $h (T 'summary.title')) + ' · <span class="ltr">' + $When.ToString('yyyy-MM-dd HH:mm') + '</span></div></div>' + $gradeHtml + '</div>' +
        '<div class="v">' + $verdictHtml + '</div>' + $war + '<div class="dev">' + $dev + '</div>' +
        '<h2>' + (& $h (T 'summary.results')) + '</h2><table>' + $res + '</table>' +
        '<h2>' + (& $h (T 'summary.checklist')) + '</h2><div class="grid">' + $cells + '</div>' + $notesHtml +
        '<div class="sign"><div>' + (& $h (T 'report.technician')) + ': ' + (& $h $Technician) + '</div><div>' + (& $h (T 'summary.signature')) + '</div></div>' +
        '</div></body></html>'
}

# One line per saved report in <root>\index.csv (UTF-8 with BOM so Excel shows Persian). Never throws.
# Fields: date, role, staff, asset, model, serial, verdict, battery_percent, battery_cycles, disk_percent, report_path[, grade].
# 2.6.0: new files get a trailing "grade" column (old files keep their 11 columns: the grade is then left out).
# -ReplacePath: "Update report" rewrites the row of that report instead of adding a second one (#6).
$global:WkIndexHeader = 'date,role,staff,asset,model,serial,verdict,battery_percent,battery_cycles,disk_percent,report_path,grade'

function Add-WkReportIndex([string]$Root, [object[]]$Fields, [string]$ReplacePath = '') {
    try {
        $path = Join-Path $Root 'index.csv'
        $utf8Bom = New-Object Text.UTF8Encoding $true
        if (-not (Test-Path -LiteralPath $path)) {
            $f = @($Fields); while ($f.Count -lt 12) { $f += '' }
            [IO.File]::WriteAllText($path, $global:WkIndexHeader + "`r`n" + ((($f | ForEach-Object { ConvertTo-WkCsvField $_ }) -join ',') + "`r`n"), $utf8Bom)
            return $path
        }
        $lines = [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)
        $cols = 11; if ($lines.Count -gt 0 -and $lines[0] -match ',grade\s*$') { $cols = 12 }
        $f = @($Fields | Select-Object -First $cols); while ($f.Count -lt $cols) { $f += '' }
        $line = (($f | ForEach-Object { ConvertTo-WkCsvField $_ }) -join ',')
        if ($ReplacePath) {
            $needle = ',' + (ConvertTo-WkCsvField $ReplacePath)
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i].EndsWith($needle) -or $lines[$i].Contains($needle + ',')) {
                    $lines[$i] = $line
                    [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), $utf8Bom)
                    return $path
                }
            }
        }
        [IO.File]::AppendAllText($path, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
        return $path
    } catch {
        Write-WkLog ('index.csv write failed: ' + $_.Exception.Message) 'WARN'
        return $null
    }
}

# Plain-text summary for "Copy information" (HTML report, app report screen, Jira description). Pure apart from T().
function Get-WkStatusWord([string]$Status) {
    $k = @{ green = 'report.ok'; amber = 'report.check'; red = 'report.bad'; grey = 'common.na' }[$Status]
    if ($k) { return (T $k) }
    return $Status
}

function Get-WkReportText($Checks, $Stress, $Verdict, [string]$Technician, [string]$Asset, [string]$Role = 'staff', [string]$Notes = '', [string]$Path = '', [datetime]$When = (Get-Date)) {
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('Doki - ' + (T 'report.title'))
    $L.Add((T 'report.date') + ': ' + $When.ToString('yyyy-MM-dd HH:mm'))
    $who = T 'role.staff' $Technician
    if ($Role -eq 'guest') { $who = T 'role.guest'; if ($Technician -and $Technician -ne (T 'role.guest')) { $who += ' (' + $Technician + ')' } }
    $L.Add((T 'report.role') + ': ' + $who)
    $a = $Asset; if (-not $a) { $a = '-' }
    $L.Add((T 'report.asset') + ': ' + $a)
    if ($Checks.system -and $Checks.system.ok) {
        $s = $Checks.system.data
        $L.Add((T 'report.model') + ': ' + $s.manufacturer + ' ' + $s.model)
        $L.Add((T 'report.serial') + ': ' + $s.serial)
        $L.Add((T 'report.cpu') + ': ' + $s.cpu + ' | ' + (T 'report.ram') + ': ' + $s.ramGB + ' GB | ' + (T 'report.os') + ': ' + $s.os + ' ' + $s.build)
    }
    $L.Add('')
    $L.Add((T 'report.verdict') + ': ' + (Get-WkStatusWord $Verdict.overall.status))
    $grade = Get-WkGradeSafe $Checks $Stress $Verdict
    if ($grade) { $L.Add((T 'grade.title') + ': ' + (Get-WkGradeLine $grade)) }
    $war = Get-WkWarrantySafe $grade $Checks
    if ($war -and $war.reject) { $L.Add('*** ' + (T 'warranty.title') + ' - ' + (Format-WkWarrantyReasons $war) + ' ***') }
    foreach ($r in @($Verdict.overall.reasons)) { $L.Add(' - ' + (Format-WkReasonPlain $r)) }
    $L.Add('')
    $bl = (T 'battery.title') + ': ' + (Get-WkStatusWord $Verdict.battery.status)
    if ($Checks.battery -and $Checks.battery.ok -and $Checks.battery.data.present) {
        $b = $Checks.battery.data
        $bl += ' | ' + (T 'battery.health') + ' ' + $b.healthPercent + '% | ' + (T 'battery.cycles') + ' ' + $b.cycles
        if ($b.runtimeMinutes) { $bl += ' | ' + (T 'battery.runtimeValue' ([math]::Floor($b.runtimeMinutes / 60)) ($b.runtimeMinutes % 60)) }
    }
    $L.Add($bl)
    $L.Add((T 'disk.title') + ': ' + (Get-WkStatusWord $Verdict.disks.status))
    if ($Checks.disks -and $Checks.disks.ok) {
        $dl = @($Checks.disks.data.disks | Where-Object { $_ }); $ef = @($Verdict.disks.effective)
        for ($i = 0; $i -lt $dl.Count; $i++) {
            $pct = T 'common.notReported'
            if ($i -lt $ef.Count -and $ef[$i] -and $null -ne $ef[$i].percent) { $pct = [string]$ef[$i].percent + '%' }
            $L.Add(' - ' + $dl[$i].name + ' (' + $dl[$i].busType + ' ' + $dl[$i].mediaType + ', ' + $dl[$i].sizeGB + ' GB): ' + $pct + ', ' + $dl[$i].healthStatus)
        }
    }
    $L.Add((T 'drivers.title') + ': ' + (Get-WkStatusWord $Verdict.drivers.status))
    foreach ($d in @($Verdict.drivers.alarm | Where-Object { $_ })) { $L.Add(' - ' + $d.name + ' (code ' + $d.code + ')') }
    $ul = (T 'updates.title') + ': ' + (Get-WkStatusWord $Verdict.updates.status)
    if ($Checks.updates -and $Checks.updates.ok -and $Checks.updates.data.checked) { $ul += ' | ' + (T 'updates.pending' ([int]$Checks.updates.data.pendingCount)) }
    $L.Add($ul)
    $L.Add((T 'stress.title') + ': ' + (Get-WkStatusWord $Verdict.stress.status))
    foreach ($k in @('cpu', 'ram', 'disk', 'gpu')) {
        $res = 'notRun'; if ($Stress -and $Stress.$k -and $Stress.$k.result) { $res = [string]$Stress.$k.result }
        $txt = switch ($res) { 'completed' { T 'stress.completed' } 'errors' { T 'stress.errors' $Stress.$k.errors } 'crashed' { T 'stress.crashed' } 'stopped' { T 'stress.stopped' } 'unavailable' { T 'stress.unavailable' $Stress.$k.error } default { T 'stress.notRun' } }
        $L.Add(' - ' + (T ('stress.' + $k)) + ': ' + $txt)
    }
    if ($Verdict.manual) {
        $L.Add((T 'manual.title') + ': ' + (Get-WkStatusWord $Verdict.manual.status))
        foreach ($it in @((Get-WkRules).manual_checks)) {
            $val = $null; if ($Checks.manual) { $val = [string]$Checks.manual.([string]$it) }
            $vt = T 'manual.notChecked'; if ($val -eq 'ok') { $vt = T 'manual.ok' } elseif ($val -eq 'fail') { $vt = T 'manual.fail' }
            if ($it -eq 'physical') { $vt = Get-WkPhysicalText $val }
            $L.Add(' - ' + (T ('manual.' + $it)) + ': ' + $vt)
        }
    }
    if ($grade) {
        $L.Add((T 'grade.tableTitle') + ':')
        foreach ($r in @($grade.rows)) {
            $p = [string]$r.points + '/' + [string]$r.max; if (-not $r.applicable) { $p = '-' }
            $L.Add(' - ' + (T ('grade.cat.' + $r.id)) + ': ' + $p + ' (' + (Format-WkGradeNote $r) + ')')
        }
        foreach ($c in @($grade.caps)) { $L.Add(' * ' + (T ('grade.cap.' + $c.id))) }
    }
    if ($Checks.device -and $Checks.device.ok -and (Get-Command Get-WkDeviceRows -ErrorAction SilentlyContinue)) {
        $L.Add((T 'dev.title') + ':')
        foreach ($r in (Get-WkDeviceRows $Checks.device.data)) { $L.Add(' - ' + ([string]$r[0]).Trim() + ': ' + $r[1]) }
    }
    if ($Checks.deploy -and @($Checks.deploy.log).Count -gt 0) {
        $L.Add((T 'dep.title') + ':')
        foreach ($x in @($Checks.deploy.log)) { $L.Add(' - ' + $x) }
    }
    if ($Notes) { $L.Add(''); $L.Add((T 'report.notes') + ': ' + $Notes) }
    if ($Path) { $L.Add(''); $L.Add('Report: ' + $Path) }
    return ($L -join "`r`n")
}

# Role: 'staff' (StaffId from config\staff.json, Technician = display name) or 'guest' (Technician = optional guest name).
# Returns the HTML path; details of where it went are in $global:WkLastReport.
# -Existing @{ path; root }: "Update report" (2.6.0, #6) overwrites that HTML/JSON and its index.csv row instead of a new report.
function New-WkReport($Checks, $Stress, $Verdict, [string]$Technician, [string]$Asset, [string]$Notes, [switch]$Open,
                      [string]$Role = 'staff', [string]$StaffId = '', $Existing = $null, [switch]$Summary) {
    $now = Get-Date
    $isGuest = ($Role -eq 'guest')
    # Standalone edition (no staff login): every report is the operator's own, so no GUEST badge / GUEST__ prefix.
    $guestMarks = $isGuest
    if (Get-Command Get-WkEdition -ErrorAction SilentlyContinue) { if (-not (Get-WkEdition).features.staffLogin) { $guestMarks = $false } }
    if ($isGuest -and -not $Technician) { $Technician = T 'role.guest' }
    $sys = $null; if ($Checks.system -and $Checks.system.ok) { $sys = $Checks.system.data }
    $serial = ''; if ($sys) { $serial = [string]$sys.serial }
    $na = T 'common.na'
    $sections = ''

    # Device
    $gpuText = $na; $osText = $na
    if ($sys) {
        $gpuText = (@($sys.gpus) | ForEach-Object { $_.name }) -join ', '
        $osText = [string]$sys.os + ' (build ' + [string]$sys.build + ')'
        $sections += '<h2>' + (ConvertTo-WkHtml (T 'report.device')) + '</h2>' + (New-WkKvTable @(
            (T 'report.manufacturer'), $sys.manufacturer, (T 'report.model'), $sys.model, (T 'report.serial'), $sys.serial,
            (T 'report.cpu'), ('{0} ({1} cores / {2} threads)' -f $sys.cpu, $sys.cores, $sys.threads), (T 'report.ram'), ('{0} GB' -f $sys.ramGB),
            (T 'report.gpu'), $gpuText, (T 'report.os'), $osText, (T 'report.bios'), $sys.biosVersion))
    }

    # Device overview (Phase 6, info only)
    if ($Checks.device -and $Checks.device.ok -and (Get-Command Get-WkDeviceRows -ErrorAction SilentlyContinue)) {
        $sections += '<h2>' + (ConvertTo-WkHtml (T 'dev.title')) + '</h2><table class="kv">'
        foreach ($r in (Get-WkDeviceRows $Checks.device.data)) { $sections += '<tr><td>' + (ConvertTo-WkHtml $r[0]) + '</td><td>' + (ConvertTo-WkHtml $r[1]) + '</td></tr>' }
        $sections += '</table>'
    }

    # Battery
    $bv = $Verdict.battery
    $sections += '<h2>' + (ConvertTo-WkHtml (T 'battery.title')) + ' ' + (Get-WkStatusPill $bv.status) + '</h2>'
    $b = $null; if ($Checks.battery -and $Checks.battery.ok) { $b = $Checks.battery.data }
    if ($b -and $b.present) {
        $hp = $na; if ($null -ne $b.healthPercent) { $hp = ('{0}%' -f $b.healthPercent) }
        $cy = T 'common.notReported'; if ($null -ne $b.cycles) { $cy = [string]$b.cycles }
        $rt = T 'common.notReported'; if ($b.runtimeMinutes) { $rt = T 'battery.runtimeValue' ([math]::Floor($b.runtimeMinutes / 60)) ($b.runtimeMinutes % 60) }
        $cap = $na; if ($b.designMWh -and $b.fullMWh) { $cap = ('{0:N1} / {1:N1} Wh' -f ($b.designMWh / 1000), ($b.fullMWh / 1000)) }
        $sections += New-WkKvTable @((T 'battery.health'), $hp, (T 'battery.cycles'), $cy, (T 'battery.runtime'), $rt, ((T 'battery.design') + ' / ' + (T 'battery.full')), $cap)
    }
    $sections += '<p>' + ((@($bv.reasons) | ForEach-Object { ConvertTo-WkHtml (Format-WkReasonPlain $_) }) -join '<br>') + '</p>'

    # Disks
    $dv = $Verdict.disks
    $sections += '<h2>' + (ConvertTo-WkHtml (T 'disk.title')) + ' ' + (Get-WkStatusPill $dv.status) + '</h2>'
    if ($Checks.disks -and $Checks.disks.ok) {
        $sections += '<table><tr><th>' + (T 'disk.name') + '</th><th>' + (T 'disk.type') + '</th><th>' + (T 'disk.size') + '</th><th>' + (T 'disk.auto') + '</th><th>' + (T 'disk.manualShort') + '</th><th>' + (T 'disk.used') + '</th><th>' + (T 'disk.status') + '</th><th>' + (T 'disk.temp') + '</th></tr>'
        $dlist = @($Checks.disks.data.disks | Where-Object { $_ })
        $effs = @($dv.effective)
        for ($i = 0; $i -lt $dlist.Count; $i++) {
            $d = $dlist[$i]; $e = $null; if ($i -lt $effs.Count) { $e = $effs[$i] }
            $auto = T 'common.notReported'; if ($null -ne $d.healthPercent) { $auto = ('{0}%' -f $d.healthPercent) }
            $man = '-'; if ($e -and $null -ne $e.manual) { $man = ('{0}%' -f $e.manual); if ($e.source) { $man += ' (' + $e.source + ')' } }
            $used = '-'; if ($e -and $e.used -eq 'manual') { $used = T 'disk.manualShort' } elseif ($e -and $e.used -eq 'auto') { $used = T 'disk.auto'; if ($d.healthSource) { $used = T ('disk.src.' + $d.healthSource) } }
            $tp = '-'; if ($d.temperature) { $tp = ('{0} C' -f $d.temperature) }
            $sections += '<tr><td class="ltr">' + (ConvertTo-WkHtml $d.name) + '</td><td class="ltr">' + (ConvertTo-WkHtml ($d.busType + ' ' + $d.mediaType)) + '</td><td class="ltr">' + $d.sizeGB + ' GB</td><td class="ltr">' + (ConvertTo-WkHtml $auto) + '</td><td class="ltr">' + (ConvertTo-WkHtml $man) + '</td><td>' + (ConvertTo-WkHtml $used) + '</td><td class="ltr">' + (ConvertTo-WkHtml $d.healthStatus) + '</td><td class="ltr">' + $tp + '</td></tr>'
        }
        $sections += '</table>'
    }
    $sections += '<p>' + ((@($dv.reasons) | ForEach-Object { ConvertTo-WkHtml (Format-WkReasonPlain $_) }) -join '<br>') + '</p>'

    # Drivers
    $drv = $Verdict.drivers
    $sections += '<h2>' + (ConvertTo-WkHtml (T 'drivers.title')) + ' ' + (Get-WkStatusPill $drv.status) + '</h2>'
    $sections += '<p>' + ((@($drv.reasons) | ForEach-Object { ConvertTo-WkHtml (Format-WkReasonPlain $_) }) -join '<br>') + '</p>'
    $devs = @(@($drv.alarm) + @($drv.info) | Where-Object { $_ })
    if ($devs.Count -gt 0) {
        $sections += '<table><tr><th>' + (T 'drivers.device') + '</th><th>' + (T 'drivers.problem') + '</th><th>Class</th></tr>'
        foreach ($d in $devs) {
            $k = 'drivers.code' + $d.code; $meaning = T 'drivers.codeOther' $d.code
            if ($global:WkStrings.ContainsKey($k)) { $meaning = T $k }
            $sections += '<tr><td class="ltr">' + (ConvertTo-WkHtml $d.name) + '</td><td>' + (ConvertTo-WkHtml $meaning) + '</td><td class="ltr">' + (ConvertTo-WkHtml $d.pnpClass) + '</td></tr>'
        }
        $sections += '</table>'
    }

    # Windows Update
    $uv = $Verdict.updates
    $sections += '<h2>' + (ConvertTo-WkHtml (T 'updates.title')) + ' ' + (Get-WkStatusPill $uv.status) + '</h2>'
    $sections += '<p>' + ((@($uv.reasons) | ForEach-Object { ConvertTo-WkHtml (Format-WkReasonPlain $_) }) -join '<br>') + '</p>'
    if ($Checks.updates -and $Checks.updates.ok) {
        $u = $Checks.updates.data
        if (@($u.titles).Count -gt 0) { $sections += '<ul>' + ((@($u.titles) | ForEach-Object { '<li class="ltr">' + (ConvertTo-WkHtml $_) + '</li>' }) -join '') + '</ul>' }
        $ign = @($u.ignoredTitles | Where-Object { $_ })
        if ($ign.Count -gt 0) {
            $sections += '<p class="note">' + (ConvertTo-WkHtml (T 'updates.ignored' $ign.Count)) + '</p><ul class="note">' + (($ign | ForEach-Object { '<li class="ltr">' + (ConvertTo-WkHtml $_) + '</li>' }) -join '') + '</ul>'
        }
        if ($u.lastInstallDate) { $sections += '<p class="note">' + (ConvertTo-WkHtml (T 'updates.lastInstall' $u.lastInstallDate)) + '</p>' }
    }

    # Stress
    $sv = $Verdict.stress
    $sections += '<h2>' + (ConvertTo-WkHtml (T 'stress.title')) + ' ' + (Get-WkStatusPill $sv.status) + '</h2>'
    $sections += '<table><tr><th>' + (T 'report.test') + '</th><th>' + (T 'report.duration') + '</th><th>' + (T 'report.result') + '</th><th>' + (T 'report.details') + '</th></tr>'
    foreach ($k in @('cpu', 'ram', 'disk', 'gpu')) {
        $r = $null; if ($Stress) { $r = $Stress.$k }
        $res = 'notRun'; if ($r -and $r.result) { $res = [string]$r.result }
        $txt = switch ($res) {
            'completed' { T 'stress.completed' } 'errors' { T 'stress.errors' $r.errors } 'crashed' { T 'stress.crashed' }
            'stopped' { T 'stress.stopped' } 'unavailable' { T 'stress.unavailable' $r.error } default { T 'stress.notRun' }
        }
        $cls = @{ completed = 'green'; errors = 'red'; crashed = 'red'; stopped = 'amber' }[$res]; if (-not $cls) { $cls = 'grey' }
        $dur = '-'; if ($r -and $r.seconds) { $dur = T 'stress.minutes' ([math]::Round($r.seconds / 60, 1)) }
        $det = ''; if ($r) { $det = ((@([string]$r.detail, [string]$r.error) | Where-Object { $_ }) -join ' ') }
        $sections += '<tr><td>' + (ConvertTo-WkHtml (T ('stress.' + $k))) + '</td><td>' + (ConvertTo-WkHtml $dur) + '</td><td><span class="pill st-' + $cls + '">' + (ConvertTo-WkHtml $txt) + '</span></td><td class="ltr note">' + (ConvertTo-WkHtml $det) + '</td></tr>'
    }
    $sections += '</table>'

    # Manual checklist (Phase 3)
    if ($Verdict.manual) {
        $mv = $Verdict.manual
        $sections += '<h2>' + (ConvertTo-WkHtml (T 'manual.title')) + ' ' + (Get-WkStatusPill $mv.status) + '</h2><table>'
        foreach ($it in @((Get-WkRules).manual_checks)) {
            $val = $null; if ($Checks.manual) { $val = [string]$Checks.manual.([string]$it) }
            $cls = 'grey'; $txt = T 'manual.notChecked'
            if ($val -eq 'ok') { $cls = 'green'; $txt = T 'manual.ok' } elseif ($val -eq 'fail') { $cls = 'red'; $txt = T 'manual.fail' }
            if ($it -eq 'physical') {
                $txt = Get-WkPhysicalText $val
                $ps = Get-WkPhysicalStatus $val
                $cls = 'grey'; if ($ps -eq 'red') { $cls = 'red' } elseif ($ps -and @(ConvertTo-WkPhysicalList $val) -notcontains 'ok') { $cls = 'amber' } elseif ($ps) { $cls = 'green' }
            }
            $sections += '<tr><td>' + (ConvertTo-WkHtml (T ('manual.' + $it))) + '</td><td><span class="pill st-' + $cls + '">' + (ConvertTo-WkHtml $txt) + '</span></td></tr>'
        }
        $sections += '</table>'
    }

    # Device preparation log (rename / EDR / restart), when done before saving
    if ($Checks.deploy -and @($Checks.deploy.log).Count -gt 0) {
        $sections += '<h2>' + (ConvertTo-WkHtml (T 'dep.title')) + '</h2><ul>' + ((@($Checks.deploy.log) | ForEach-Object { '<li>' + (ConvertTo-WkHtml $_) + '</li>' }) -join '') + '</ul>'
    }

    # Overall
    $ov = $Verdict.overall
    $ovKey = @{ green = 'report.ok'; amber = 'report.check'; red = 'report.bad' }[$ov.status]
    $reasonsHtml = ''
    if (@($ov.reasons).Count -gt 0) { $reasonsHtml = '<ul>' + ((@($ov.reasons) | ForEach-Object { '<li>' + (ConvertTo-WkHtml (Format-WkReasonPlain $_)) + '</li>' }) -join '') + '</ul>' }

    $roleText = T 'role.staff' $Technician
    if ($isGuest) { $roleText = T 'role.guest'; if ($Technician -and $Technician -ne (T 'role.guest')) { $roleText += ' (' + $Technician + ')' } }
    $meta = (ConvertTo-WkHtml (T 'report.date')) + ': <span class="ltr">' + $now.ToString('yyyy-MM-dd HH:mm') + '</span><br>' +
        (ConvertTo-WkHtml (T 'report.role')) + ': ' + (ConvertTo-WkHtml $roleText) + '<br>' +
        (ConvertTo-WkHtml (T 'report.asset')) + ': <span class="ltr">' + (ConvertTo-WkHtml $Asset) + '</span><br>' +
        (ConvertTo-WkHtml (T 'report.serial')) + ': <span class="ltr">' + (ConvertTo-WkHtml $serial) + '</span>'
    $notesHtml = ConvertTo-WkHtml $Notes
    if (-not $Notes) { $notesHtml = ConvertTo-WkHtml (T 'report.notesNone') }
    $dir = 'rtl'; if (-not (Test-WkRtl)) { $dir = 'ltr' }

    # Phase 10: grade tag, stamp and score table (D-030)
    $grade = Get-WkGradeSafe $Checks $Stress $Verdict
    $gradeTag = ''; $stamp = ''; $gradeTable = ''; $gradeLine = ''; $warrantyHtml = ''
    $warranty = Get-WkWarrantySafe $grade $Checks
    if ($warranty -and $warranty.reject) { $warrantyHtml = '<div class="warranty">' + (ConvertTo-WkHtml (T 'warranty.title')) + '<small>' + (ConvertTo-WkHtml (T 'warranty.reasons' (Format-WkWarrantyReasons $warranty))) + '</small></div>' }
    if ($grade) {
        $gc = Get-WkGradeColor $grade.grade
        $gradeTag = '<span class="gtag" style="background:' + $gc + '">' + (Protect-WkGradeBidi (ConvertTo-WkHtml (T 'grade.tag' $grade.grade))) + '</span>'
        $gradeLine = '<div class="gline" style="color:' + $gc + '">' + (Protect-WkGradeBidi (ConvertTo-WkHtml (Get-WkGradeLine $grade))) + '</div>'
        $stamp = Get-WkStampSvg $grade $now $Asset
        $gradeTable = Get-WkGradeTableHtml $grade
    }

    $tpl = [IO.File]::ReadAllText((Join-Path $global:WkApp 'report\template.html'), [Text.Encoding]::UTF8)
    $vals = @{
        gradeTag = $gradeTag; gradeLine = $gradeLine; stamp = $stamp; gradeTable = $gradeTable; warranty = $warrantyHtml
        roleBadge = ''
        copyLabel = (ConvertTo-WkHtml (T 'report.copy')); copiedLabel = ((T 'report.copied') -replace "'", ' ')
        lang = $global:WkLang; dir = $dir; title = (ConvertTo-WkHtml (T 'report.title')); asset = (ConvertTo-WkHtml $Asset); meta = $meta
        overallStatus = $ov.status; overallText = ((ConvertTo-WkHtml (T 'report.verdict')) + ': ' + (ConvertTo-WkHtml (T $ovKey))); overallReasons = $reasonsHtml
        sections = $sections; notesTitle = (ConvertTo-WkHtml (T 'report.notes')); notes = $notesHtml
        technicianLabel = (ConvertTo-WkHtml (T 'report.technician')); technician = (ConvertTo-WkHtml $Technician)
        generated = (ConvertTo-WkHtml (T 'report.generated' $global:WkVersion)); timestamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
    }
    if ($guestMarks) { $vals.roleBadge = '<span class="badge-guest">' + (ConvertTo-WkHtml (T 'report.guestBadge')) + '</span>' }

    # File name carries the details (D-012): date__asset__model__serial__staff, guest files start with GUEST__
    $model = ''; if ($sys) { $model = [string]$sys.model }
    $updating = ($Existing -and $Existing.path -and (Test-Path -LiteralPath (Split-Path -Parent ([string]$Existing.path))))
    if ($updating) {
        $htmlPath = [string]$Existing.path
        $outDir = Split-Path -Parent $htmlPath
        $base = [IO.Path]::GetFileNameWithoutExtension($htmlPath)
        $target = @{ root = [string]$Existing.root; dir = $outDir; intended = [string]$Existing.root; fallback = $false }
        if (-not $target.root) { $target.root = $outDir }
    } else {
        $parts = @($now.ToString('yyyy-MM-dd_HHmm'), (Get-WkSafeName $Asset 25), (Get-WkSafeName $model 30), (Get-WkSafeName $serial 25))
        if ($guestMarks) { $base = 'GUEST__' + ($parts -join '__') } elseif ($isGuest) { $base = ($parts -join '__') } else { $base = ($parts -join '__') + '__' + (Get-WkSafeName $StaffId 20) }
        if ($base.Length -gt 120) { $base = $base.Substring(0, 120) }
        $target = Get-WkReportTarget $Role $now
        $outDir = $target.dir
        $htmlPath = Join-Path $outDir ($base + '.html')
        if (Test-Path -LiteralPath $htmlPath) { $base += '_' + $now.ToString('ss'); $htmlPath = Join-Path $outDir ($base + '.html') }
    }
    $copyText = Get-WkReportText $Checks $Stress $Verdict $Technician $Asset $Role $Notes $htmlPath $now
    $global:WkLastReportText = $copyText
    $vals.copyText = ConvertTo-WkHtml $copyText
    $tpl = Format-WkTemplate $tpl $vals
    [IO.File]::WriteAllText($htmlPath, $tpl, (New-Object Text.UTF8Encoding $true))
    try {
        Write-WkJson (Join-Path $outDir ($base + '.json')) ([ordered]@{
            version = $global:WkVersion; createdAt = $now.ToString('o'); role = $Role; staffId = $StaffId; technician = $Technician
            asset = $Asset; notes = $Notes; checks = $Checks; stress = $Stress; verdict = $Verdict; grade = $grade })
    } catch { Write-WkLog ('report json failed: ' + $_.Exception.Message) 'WARN' }

    # index.csv row
    $batPct = ''; $batCyc = ''
    if ($b -and $b.present) { if ($null -ne $b.healthPercent) { $batPct = $b.healthPercent }; if ($null -ne $b.cycles) { $batCyc = $b.cycles } }
    $diskPct = ''
    $pcts = @(@($dv.effective) | Where-Object { $_ -and $null -ne $_.percent } | ForEach-Object { [double]$_.percent })
    if ($pcts.Count -gt 0) { $diskPct = ($pcts | Measure-Object -Minimum).Minimum }
    $staffCol = $Technician; if ($guestMarks) { $staffCol = '' }
    $gradeCol = ''; if ($grade) { $gradeCol = [string]$grade.grade }
    $replace = ''; if ($updating) { $replace = $htmlPath }
    $index = Add-WkReportIndex $target.root @($now.ToString('yyyy-MM-dd HH:mm'), $Role, $staffCol, $Asset, $model, $serial, $ov.status, $batPct, $batCyc, $diskPct, $htmlPath, $gradeCol) $replace

    $summaryPath = ''
    if ($Summary) {
        try {
            $summaryPath = Join-Path $outDir ($base + '.summary.html')
            [IO.File]::WriteAllText($summaryPath, (New-WkSummaryHtml $Checks $Stress $Verdict $grade $warranty $Technician $Asset $now $Notes), (New-Object Text.UTF8Encoding $true))
        } catch { Write-WkLog ('summary page failed: ' + $_.Exception.Message) 'WARN'; $summaryPath = '' }
    }
    $global:WkLastReport = @{ path = $htmlPath; dir = $outDir; root = $target.root; intended = $target.intended; fallback = $target.fallback; index = $index; updated = [bool]$updating
                              summary = $summaryPath; rejected = [bool]($warranty -and $warranty.reject) }
    Write-WkLog ('report ' + $(if ($updating) { 'updated' } else { 'saved' }) + ': ' + $htmlPath + ' (fallback=' + $target.fallback + ')')
    $openPath = $htmlPath; if ($summaryPath) { $openPath = $summaryPath }   # the contractor prints the one-page summary
    if ($Open) { try { Start-Process -FilePath $openPath } catch { } }
    return $htmlPath
}
