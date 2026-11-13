$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$work=Join-Path $root 'dist'
New-Item -ItemType Directory -Force $work | Out-Null
$stage=Join-Path $work ('stage-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $stage | Out-Null
foreach($name in 'app','assets','config'){Copy-Item (Join-Path $root $name) $stage -Recurse}
Copy-Item (Join-Path $root 'Start.bat') $stage
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$sma=Get-ChildItem 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation' -Recurse -Filter System.Management.Automation.dll | Select-Object -First 1 -ExpandProperty FullName
& $csc /nologo /target:winexe /reference:System.Windows.Forms.dll ('/reference:'+$sma) ('/win32manifest:'+(Join-Path $root 'launcher/app.manifest')) ('/out:'+(Join-Path $stage 'Doki.exe')) (Join-Path $root 'launcher/Launcher.cs')
if($LASTEXITCODE){throw 'Launcher build failed'}
$zip=Join-Path $work ('payload-'+[guid]::NewGuid().ToString('N')+'.zip')
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:winexe /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll ('/resource:'+$zip+',payload.zip') ('/win32icon:'+(Join-Path $root 'launcher/app.ico')) ('/win32manifest:'+(Join-Path $root 'launcher/app.manifest')) ('/out:'+(Join-Path $work 'Doki-2.9.0.exe')) (Join-Path $PSScriptRoot 'SingleFileWrapper.cs')
if($LASTEXITCODE){throw 'Build failed'}
