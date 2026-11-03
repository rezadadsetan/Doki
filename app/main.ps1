# Doki entry point. Windows PowerShell 5.1, ASCII-only source.
#   UI:          powershell -NoProfile -ExecutionPolicy Bypass -STA -File "app\main.ps1"
#   Self-test:   ... -File "app\main.ps1" -SelfTest [-SkipUpdates] [-ReportTest]
#   Stress test: ... -File "app\main.ps1" -StressSelfTest -Seconds 10
param(
    [switch]$SelfTest,
    [switch]$StressSelfTest,
    [int]$Seconds = 10,
    [switch]$SkipUpdates,
    [switch]$ReportTest,
    [switch]$NoElevate,          # accepted for symmetry with Start.bat; main.ps1 itself never elevates
    [ValidateSet('fa', 'en')][string]$Lang = 'fa'
)

$ErrorActionPreference = 'Continue'
$global:WkApp = $PSScriptRoot
$global:WkRoot = Split-Path -Parent $PSScriptRoot

# Module list is global so background runspaces can load the same files.
$global:WkModules = @(
    'lib\Common.ps1', 'lib\I18n.ps1', 'lib\Sound.ps1', 'lib\Offline.ps1',
    'collectors\SystemInfo.ps1', 'collectors\Battery.ps1', 'collectors\Disk.ps1',
    'collectors\Drivers.ps1', 'collectors\Updates.ps1', 'collectors\DeviceFacts.ps1', 'lib\Monitor.ps1',
    'rules\Evaluate.ps1', 'rules\Grade.ps1', 'stress\Stress.ps1', 'report\Report.ps1'
) | ForEach-Object { Join-Path $PSScriptRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
foreach ($m in $global:WkModules) { . $m }

Set-WkLanguage $Lang
Write-WkLog ('start v{0} admin={1} args: SelfTest={2} StressSelfTest={3} SkipUpdates={4}' -f $global:WkVersion, (Test-WkAdmin), $SelfTest, $StressSelfTest, $SkipUpdates)

function Get-WkAllChecks([switch]$SkipUpdates) {
    $rules = Get-WkRules
    $r = [ordered]@{}
    $r.system = Get-WkSystemInfo
    $r.battery = Get-WkBattery
    $r.disks = Get-WkDisks
    $r.drivers = Get-WkDriverProblems
    $r.device = Get-WkDeviceFacts
    $r.updates = Get-WkUpdates -TimeoutSec ([int]$rules.updates.search_timeout_seconds) -Skip:$SkipUpdates
    return $r
}

if ($SelfTest) {
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $all = Get-WkAllChecks -SkipUpdates:$SkipUpdates
    $all.admin = (Test-WkAdmin)
    if (Get-Command Get-WkVerdict -ErrorAction SilentlyContinue) {
        $all.verdict = Get-WkVerdict -Checks $all -Stress $null -Rules (Get-WkRules)
    }
    if ($ReportTest -and (Get-Command New-WkReport -ErrorAction SilentlyContinue)) {
        $all.reportPath = New-WkReport -Checks $all -Stress $null -Verdict $all.verdict -Technician 'Self Test' -Asset 'TEST-001' -Notes 'self-test' -Open:$false
    }
    ConvertTo-Json -InputObject $all -Depth 10
    exit 0
}

if ($StressSelfTest) {
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $res = Invoke-WkStressSelfTest -Seconds $Seconds
    ConvertTo-Json -InputObject $res -Depth 6
    exit 0
}

try {
    . (Join-Path $PSScriptRoot 'ui\Ui.ps1')
    Start-WkUi
} catch {
    Write-WkLog ('fatal: ' + $_.Exception.ToString()) 'ERROR'
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show('Doki failed to start: ' + $_.Exception.Message + "`r`nLog: " + $global:WkLogFile, 'Doki') | Out-Null
    } catch { }
    exit 1
}
