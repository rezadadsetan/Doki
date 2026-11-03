# Get-WkUpdates: pending Windows updates (WUA COM search in a child job with a hard timeout) + pending reboot.
# Definition Updates (Defender "Security Intelligence" signatures, several per day) are listed as ignored, not pending
# (rules.json updates.ignore_definition_updates, decided by the user in Phase 3).

$global:WkDefinitionCategoryId = 'e0789628-ce08-4437-be74-2495b842f43b'   # WUA category "Definition Updates" (same id on every Windows language)

function Test-WkDefinitionUpdate($Item) {
    foreach ($id in @($Item.catIds)) { if ([string]$id -eq $global:WkDefinitionCategoryId) { return $true } }
    foreach ($n in @($Item.catNames)) { if ([string]$n -eq 'Definition Updates') { return $true } }
    if ([string]$Item.title -like 'Security Intelligence Update for Microsoft Defender*') { return $true }
    return $false
}

# Splits raw job items into pending vs ignored; pure, unit-tested.
function Split-WkUpdateItems([object[]]$Items, [bool]$IgnoreDefinitions) {
    $pending = @(); $ignored = @()
    foreach ($it in @($Items | Where-Object { $_ })) {
        if ($IgnoreDefinitions -and (Test-WkDefinitionUpdate $it)) { $ignored += $it } else { $pending += $it }
    }
    return @{ pending = $pending; ignored = $ignored }
}

function Get-WkUpdates([int]$TimeoutSec = 120, [switch]$Skip) {
    Invoke-WkSafe 'updates' {
        $r = @{ checked = $false; pendingCount = 0; titles = @(); kbs = @(); ignoredTitles = @(); rebootRequired = $false; lastInstallDate = $null; error = $null }
        $ignoreDefs = $true
        try { if ($null -ne (Get-WkRules).updates.ignore_definition_updates) { $ignoreDefs = [bool](Get-WkRules).updates.ignore_definition_updates } } catch { }
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )
        foreach ($k in $keys) { if (Test-Path -LiteralPath $k) { $r.rebootRequired = $true } }
        if ($Skip) { $r.error = 'skipped'; return $r }

        # Phase 6 (D-022): in-process runspace instead of Start-Job (no child powershell.exe for EDRs to flag).
        # On timeout the runspace is abandoned (BeginStop); the app keeps going.
        $wu = {
            $o = @{ ok = $false; items = @(); last = $null; error = $null }
            try {
                $session = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
                foreach ($u in $res.Updates) {
                    $it = @{ title = [string]$u.Title; kbs = @(); catIds = @(); catNames = @() }
                    foreach ($kb in $u.KBArticleIDs) { $it.kbs += ('KB' + $kb) }
                    foreach ($c in $u.Categories) { $it.catIds += [string]$c.CategoryID; $it.catNames += [string]$c.Name }
                    $o.items += $it
                }
                try {
                    $n = $searcher.GetTotalHistoryCount()
                    if ($n -gt 0) {
                        $best = $null
                        foreach ($h in $searcher.QueryHistory(0, [math]::Min(50, $n))) {
                            if ($h.ResultCode -eq 2 -and ($null -eq $best -or $h.Date -gt $best)) { $best = $h.Date }
                        }
                        if ($best) { $o.last = $best.ToString('yyyy-MM-dd') }
                    }
                } catch { }
                $o.ok = $true
            } catch { $o.error = $_.Exception.Message }
            $o
        }
        $ps = [powershell]::Create()
        [void]$ps.AddScript($wu.ToString())
        $h = $ps.BeginInvoke()
        $finished = $false
        try {
            if ($h.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
                $finished = $true
                $o = @($ps.EndInvoke($h)) | Select-Object -Last 1
                if ($o -and $o.ok) {
                    $split = Split-WkUpdateItems @($o.items) $ignoreDefs
                    $r.checked = $true
                    $r.titles = @($split.pending | ForEach-Object { [string]$_.title })
                    $r.kbs = @($split.pending | ForEach-Object { @($_.kbs) })
                    $r.ignoredTitles = @($split.ignored | ForEach-Object { [string]$_.title })
                    $r.pendingCount = @($split.pending).Count
                    $r.lastInstallDate = $o.last
                } elseif ($o) { $r.error = [string]$o.error } else { $r.error = 'no result' }
            } else {
                $r.error = 'timeout after ' + $TimeoutSec + ' s'
                try { [void]$ps.BeginStop($null, $null) } catch { }
            }
        } finally {
            if ($finished) { try { $ps.Dispose() } catch { } }
        }
        $r
    }
}
