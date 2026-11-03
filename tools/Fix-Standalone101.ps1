$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$xaml=Join-Path $root 'app/ui/MainWindow.xaml'
[xml]$x=[IO.File]::ReadAllText($xaml)
foreach($n in @($x.SelectNodes('//*[@Text]'))){
    # Standalone generator inserted this exact home-screen credit twice; About uses an i18n Tag instead.
    if([string]$n.Margin -eq '0,8,0,8' -and [string]$n.FontWeight -eq 'SemiBold'){
        [void]$n.ParentNode.RemoveChild($n)
    }
}
$settings=New-Object Xml.XmlWriterSettings
$settings.Encoding=New-Object Text.UTF8Encoding $true
$settings.Indent=$true
$writer=[Xml.XmlWriter]::Create($xaml,$settings)
try{$x.Save($writer)}finally{$writer.Dispose()}
