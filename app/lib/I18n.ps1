# Strings: app\i18n\<lang>.json, read as UTF-8. T 'key' arg0 arg1 ... formats {0} {1}.

function Set-WkLanguage([string]$Lang) {
    if ($Lang -ne 'en') { $Lang = 'fa' }
    $path = Join-Path $global:WkApp ('i18n\' + $Lang + '.json')
    $obj = Read-WkJson $path
    $map = @{}
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    # 2.6.0 (D-034): edition overlay i18n\<lang>.<edition>.json replaces/adds keys (organization wording lives only in *.org.json).
    try {
        $ed = 'standalone'; if (Get-Command Get-WkEdition -ErrorAction SilentlyContinue) { $ed = [string](Get-WkEdition).edition }
        $ov = Join-Path $global:WkApp ('i18n\' + $Lang + '.' + $ed + '.json')
        if (Test-Path -LiteralPath $ov) { foreach ($p in (Read-WkJson $ov).PSObject.Properties) { $map[$p.Name] = [string]$p.Value } }
    } catch { }
    $global:WkStrings = $map
    $global:WkLang = $Lang
}

function T([string]$Key) {
    if (-not $global:WkStrings) { Set-WkLanguage 'fa' }
    $s = $global:WkStrings[$Key]
    if ($null -eq $s) { return $Key }
    if ($args.Count -gt 0) {
        try { return [string]::Format($s, [object[]]$args) } catch { return $s }
    }
    return $s
}

function Test-WkRtl { return ($global:WkLang -ne 'en') }
