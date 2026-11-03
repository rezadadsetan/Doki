# Common helpers: paths, logging, JSON, admin check, safe invoke.
# Keep this file ASCII-only (PowerShell 5.1 reads BOM-less files as ANSI). Persian text lives in app\i18n\*.json.

if (-not $global:WkApp) { $global:WkApp = Split-Path -Parent $PSScriptRoot }      # ...\app
if (-not $global:WkRoot) { $global:WkRoot = Split-Path -Parent $global:WkApp }     # portable folder
$global:WkVersion = '2.5.0'   # overridden by app\version.json (written by the CI build) at the end of this file
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
    if (-not $global:WkRules) { $global:WkRules = Read-WkJson (Join-Path $global:WkRoot 'config\rules.json') }
    return $global:WkRules
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
