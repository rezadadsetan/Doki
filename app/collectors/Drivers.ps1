# Get-WkDriverProblems: devices whose ConfigManagerErrorCode is not 0.
# Returns raw codes only; alarm vs info is decided in rules\Evaluate.ps1 from config\rules.json (D-005).

function Get-WkDriverProblems {
    Invoke-WkSafe 'drivers' {
        $ErrorActionPreference = 'Stop'
        $list = @()
        foreach ($e in @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })) {
            $name = [string]$e.Name
            if (-not $name) { $name = [string]$e.Description }
            if (-not $name) { $name = [string]$e.DeviceID }
            $list += @{
                name     = $name.Trim()
                code     = [int]$e.ConfigManagerErrorCode
                pnpClass = [string]$e.PNPClass
                deviceId = [string]$e.DeviceID
            }
        }
        @{ devices = $list }
    }
}
