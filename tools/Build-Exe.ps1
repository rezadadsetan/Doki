# Builds the portable release (D-020): icon -> Doki.exe (built-in csc) -> dist\Doki-<ver>\ + zip + SHA256.
# Used locally and by .github\workflows\build.yml. ASCII only.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Exe.ps1 [-Scan]
param([switch]$Scan)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
Add-Type -AssemblyName System.Drawing

$ver = [string](Get-Content (Join-Path $root 'app\version.json') -Raw | ConvertFrom-Json).version
Write-Output "version $ver"

# 1) Icon: the Doki mascot icon from assets\doki\Doki.ico (made by tools\Prepare-DokiAssets.ps1, Phase 8).
#    Fallback only when it is missing: a generated 256x256 ember rounded square with "D".
$ico = Join-Path $root 'launcher\app.ico'
$dokiIco = Join-Path $root 'assets\doki\Doki.ico'
if (Test-Path $dokiIco) { Copy-Item $dokiIco $ico -Force; Write-Output "icon: assets\doki\Doki.ico" }
else {
    $bmp = New-Object System.Drawing.Bitmap 256, 256
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = 56
    $path.AddArc(0, 0, $r, $r, 180, 90); $path.AddArc(256 - $r, 0, $r, $r, 270, 90)
    $path.AddArc(256 - $r, 256 - $r, $r, $r, 0, 90); $path.AddArc(0, 256 - $r, $r, $r, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#E85D3F'))), $path)
    $font = New-Object System.Drawing.Font 'Segoe UI', 104, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString('D', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 8, 256, 256), $sf)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)                  # ICONDIR
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0)     # 256x256, no palette
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$png.Length); $w.Write([uint32]22)
    $w.Write($png); $w.Flush()
    [IO.File]::WriteAllBytes($ico, $out.ToArray())
    $g.Dispose(); $bmp.Dispose()
    Write-Output "icon created"
}
Copy-Item $ico (Join-Path $root 'app\ui\app.ico') -Force

# 2) Compile (version info from version.json)
$src = Get-Content (Join-Path $root 'launcher\Launcher.cs') -Raw
$v4 = $ver + '.0'
$src = $src.Replace('AssemblyVersion("0.0.0.0")', 'AssemblyVersion("' + $v4 + '")').Replace('AssemblyFileVersion("0.0.0.0")', 'AssemblyFileVersion("' + $v4 + '")').Replace('AssemblyInformationalVersion("0.0.0")', 'AssemblyInformationalVersion("' + $ver + '")')
$tmpSrc = Join-Path $env:TEMP 'Doki_Launcher.cs'
[IO.File]::WriteAllText($tmpSrc, $src, (New-Object Text.UTF8Encoding $false))
$sma = Get-ChildItem 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation' -Recurse -Filter System.Management.Automation.dll | Select-Object -First 1 -ExpandProperty FullName
if (-not $sma) { throw 'System.Management.Automation.dll not found in the GAC' }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exeTmp = Join-Path $env:TEMP 'Doki.exe'
& $csc /nologo /target:winexe /optimize+ /platform:anycpu ("/win32icon:" + $ico) ("/win32manifest:" + (Join-Path $root 'launcher\app.manifest')) ("/out:" + $exeTmp) /reference:System.Windows.Forms.dll ("/reference:" + $sma) $tmpSrc
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item $tmpSrc -Force

# 2b) Native helpers DLL (D-022): no runtime Add-Type/csc on the technician's laptop.
$dllTmp = Join-Path $env:TEMP 'WonderKid.Native.dll'
& $csc /nologo /target:library /optimize+ /platform:anycpu ("/out:" + $dllTmp) (Join-Path $root 'app\stress\StressNative.cs') (Join-Path $root 'app\collectors\DiskNative.cs') (Join-Path $root 'app\lib\MicNative.cs')
if ($LASTEXITCODE -ne 0) { throw "csc (native dll) failed ($LASTEXITCODE)" }

# 3) Stage dist\Doki-<ver>\ (no logs, reports, last.json, jira.json with a token)
$name = 'Doki-' + $ver
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $stage 'config') | Out-Null
Copy-Item $exeTmp (Join-Path $stage 'Doki.exe'); Remove-Item $exeTmp -Force
Copy-Item (Join-Path $root 'Start.bat'), (Join-Path $root 'README.md'), (Join-Path $root 'CHANGELOG.md') -Destination $stage
Copy-Item (Join-Path $root 'app') -Destination $stage -Recurse
New-Item -ItemType Directory -Force (Join-Path $stage 'assets') | Out-Null
Get-ChildItem (Join-Path $root 'assets') | Where-Object { $_.Name -ne 'installers' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage 'assets') -Recurse }
foreach ($c in 'rules.json') { Copy-Item (Join-Path $root ('config\' + $c)) (Join-Path $stage 'config') }
New-Item -ItemType Directory -Force (Join-Path $stage 'tools') | Out-Null
Get-ChildItem $stage -Recurse -Include '*.log', 'last.json' -File | Remove-Item -Force
foreach ($d in 'Logs', 'Reports') { $p = Join-Path $stage $d; if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
New-Item -ItemType Directory -Force (Join-Path $stage 'app\native') | Out-Null
Copy-Item $dllTmp (Join-Path $stage 'app\native\WonderKid.Native.dll'); Remove-Item $dllTmp -Force

# 4) Zip + SHA256
$zip = Join-Path $dist ($name + '.zip')
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText($zip + '.sha256', $hash + '  ' + ($name + '.zip') + "`r`n", (New-Object Text.ASCIIEncoding))
Write-Output ("exe:  " + (Join-Path $stage 'Doki.exe'))
Write-Output ("zip:  " + $zip + "  sha256 " + $hash)

# 5) Optional Defender scan of the exe and the zip
if ($Scan) {
    $mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    foreach ($f in @((Join-Path $stage 'Doki.exe'), $zip)) {
        $o = & $mp -Scan -ScanType 3 -File $f -DisableRemediation 2>&1 | Out-String
        Write-Output ("defender " + [IO.Path]::GetFileName($f) + ": exit " + $LASTEXITCODE + " | " + ($o -replace '\s+', ' ').Trim())
    }
}
