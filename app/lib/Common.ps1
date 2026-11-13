# Common helpers: paths, logging, JSON, admin check, safe invoke.
# Keep this file ASCII-only (PowerShell 5.1 reads BOM-less files as ANSI). Persian text lives in app\i18n\*.json.

if (-not $global:WkApp) { $global:WkApp = Split-Path -Parent $PSScriptRoot }      # ...\app
if (-not $global:WkRoot) { $global:WkRoot = Split-Path -Parent $global:WkApp }     # portable folder
$global:WkVersion = '0.0.0-dev'   # overridden by app\version.json (stamped by tools\Build-Exe.ps1) at the end of this file
$global:WkBuild = @{ version = $global:WkVersion; buildDate = ''; commit = ''; channel = 'dev' }

function Get-WkWritableDir([string]$Name) {
    # Prefer a folder beside the app; fall back to %TEMP% when the app runs from read-only media.
    $dir = Join-Path $global:WkRoot $Name
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $dir ('.probe_' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $dir
    } catch {
        $fb = Join-Path $env:TEMP ('Doki\' + $Name)
        if (-not (Test-Path -LiteralPath $fb)) { New-Item -ItemType Directory -Path $fb -Force | Out-Null }
        return $fb
    }
}

function Write-WkLog([string]$Message, [string]$Level = 'INFO') {
    try {
        if (-not $global:WkLogFile) {
            $global:WkLogFile = Join-Path (Get-WkWritableDir 'Logs') ('wk-' + (Get-Date -Format 'yyyyMMdd') + '.log')
        }
        $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($global:WkLogFile, $line, [Text.Encoding]::UTF8)
    } catch { }   # logging must never break the app (runspaces may write at the same time)
}

function Read-WkJson([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Write-WkJson([string]$Path, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 10
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-WkRules {
    if (-not $global:WkRules) {
        $r = Read-WkJson (Join-Path $global:WkRoot 'config\rules.json')
        # 2.6.0 (D-034): organization values live in config\org.json (org edition only) and override the generic rules.
        $o = Get-WkOrg
        if ($o) {
            try { if ($o.paths) { $r.paths = $o.paths } } catch { }
            try { if ($o.followupUrl -and $r.followup) { $r.followup.url = [string]$o.followupUrl } } catch { }
            # 2.7.0/2.8.0: org rule overrides (grades C/D, stress-optional grading, cycle alarm) merged key by key.
            foreach ($sec in @('grading', 'battery', 'disk')) { try { if ($o.$sec) { Merge-WkObject $r.$sec $o.$sec } } catch { } }
        }
        # 2.8.0: local settings from the Settings screen (org flag "settings"), applied last.
        if ((Get-WkEdition).features.settings -and -not $global:WkSkipSettings) {
            $st = Get-WkSettings
            if ($st) {
                if ($null -ne $st.batteryMinHealth) { Merge-WkObject $r.battery ([pscustomobject]@{ min_health_percent = [double]$st.batteryMinHealth }) }
                if ($null -ne $st.cycleAlarm) { Merge-WkObject $r.battery ([pscustomobject]@{ cycle_alarm = [int]$st.cycleAlarm }) }
                if ($null -ne $st.diskMinHealth) { Merge-WkObject $r.disk ([pscustomobject]@{ min_health_percent = [double]$st.diskMinHealth }) }
            }
        }
        $global:WkRules = $r
    }
    return $global:WkRules
}

# Copies the properties of $Source into $Target (PSCustomObjects from JSON); nested objects are merged, everything else replaced.
function Merge-WkObject($Target, $Source) {
    if (-not $Target -or -not $Source) { return }
    foreach ($p in @($Source.PSObject.Properties)) {
        if ($p.Name -like '_*') { continue }
        $cur = $Target.PSObject.Properties[$p.Name]
        if ($cur -and $cur.Value -is [pscustomobject] -and $p.Value -is [pscustomobject]) { Merge-WkObject $cur.Value $p.Value }
        elseif ($cur) { $cur.Value = $p.Value }
        else { $Target | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }
}

# 2.8.0: config\settings.json { batteryMinHealth; diskMinHealth; cycleAlarm } written by the Settings screen. $null when absent.
function Get-WkSettingsPath { return (Join-Path $global:WkRoot 'config\settings.json') }
function Get-WkSettings {
    try { $p = Get-WkSettingsPath; if (Test-Path -LiteralPath $p) { return (Read-WkJson $p) } } catch { }
    return $null
}

# ---------------- editions (2.6.0, D-034) ----------------
# config\edition.json: { edition: org|standalone, features: {...} }. Missing file = standalone (no organization features).
$global:WkFeatureNames = @('staffLogin', 'corporateEmail', 'jira', 'deploy', 'updater', 'followup', 'contacts', 'github', 'footerCredit', 'warranty', 'contractorLabel', 'settings', 'finishWindow')

function ConvertTo-WkEdition($Raw) {
    $f = @{}
    foreach ($n in $global:WkFeatureNames) { $f[$n] = $false }
    $f.footerCredit = $true
    $name = 'standalone'
    if ($Raw) {
        if ($Raw.edition) { $name = [string]$Raw.edition }
        if ($Raw.features) { foreach ($p in $Raw.features.PSObject.Properties) { $f[$p.Name] = [bool]$p.Value } }
    }
    return @{ edition = $name; features = $f }
}

function Get-WkEdition {
    if (-not $global:WkEditionCache) {
        $raw = $null
        try { $p = Join-Path $global:WkRoot 'config\edition.json'; if (Test-Path -LiteralPath $p) { $raw = Read-WkJson $p } } catch { }
        $global:WkEditionCache = ConvertTo-WkEdition $raw
    }
    return $global:WkEditionCache
}

# A feature is on when the edition enables it AND the module behind it is loaded (the standalone build does not ship them).
function Test-WkFeature([string]$Name) {
    if (-not (Get-WkEdition).features[$Name]) { return $false }
    $need = @{ jira = 'Send-WkSupportTicket'; deploy = 'Invoke-WkRename'; updater = 'Get-DokiLatestRelease'; corporateEmail = 'Test-WkCorporateEmail' }
    if ($need.ContainsKey($Name) -and -not (Get-Command $need[$Name] -ErrorAction SilentlyContinue)) { return $false }
    return $true
}

# config\org.json (org edition only): paths, follow-up URL, GitHub URL, contacts, staff e-mails. $null when absent.
function Get-WkOrg {
    if ($null -eq $global:WkOrgCache) {
        $global:WkOrgCache = $false
        try { $p = Join-Path $global:WkRoot 'config\org.json'; if (Test-Path -LiteralPath $p) { $global:WkOrgCache = Read-WkJson $p } } catch { }
    }
    if ($global:WkOrgCache) { return $global:WkOrgCache }
    return $null
}

function Test-WkAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Collector contract (D-003): @{ ok; data; error } and never throws.
function Invoke-WkSafe([string]$Name, [scriptblock]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $data = & $Body
        Write-WkLog ('{0} ok in {1} ms' -f $Name, $sw.ElapsedMilliseconds)
        return @{ ok = $true; data = $data; error = $null }
    } catch {
        Write-WkLog ('{0} failed: {1}' -f $Name, $_.Exception.Message) 'ERROR'
        return @{ ok = $false; data = $null; error = $_.Exception.Message }
    }
}

# Version info (Phase 4, D-017): app\version.json {version, buildDate, commit, channel}. CI writes buildDate/commit; local = "dev".
try {
    $vp = Join-Path $global:WkApp 'version.json'
    if (Test-Path -LiteralPath $vp) {
        $vj = Read-WkJson $vp
        if ($vj.version) { $global:WkVersion = [string]$vj.version }
        $global:WkBuild = @{ version = $global:WkVersion; buildDate = [string]$vj.buildDate; commit = [string]$vj.commit; channel = [string]$vj.channel }
    }
} catch { }

# Phase 6 (D-022): native helpers are precompiled at build time into app\native\WonderKid.Native.dll, so the technician's
# laptop never spawns csc.exe (Add-Type) - EDR products score runtime compilation as suspicious. Dev tree: falls back to the .cs files.
function Import-WkNative {
    if ('WonderKid.DiskNative' -as [type]) { return $true }
    $dll = Join-Path $global:WkApp 'native\WonderKid.Native.dll'
    if (Test-Path -LiteralPath $dll) {
        try { [void][Reflection.Assembly]::LoadFrom($dll); return $true } catch { Write-WkLog ('native dll load failed: ' + $_.Exception.Message) 'WARN' }
    }
    return $false
}

# Runs an external exe hidden with a timeout; returns $true if it exited in time.
function Invoke-WkProcess([string]$File, [string]$Arguments, [int]$TimeoutMs = 20000) {
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        Write-WkLog ('{0} timed out after {1} ms' -f $File, $TimeoutMs) 'WARN'
        return $false
    }
    return $true
}
