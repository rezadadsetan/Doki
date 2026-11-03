$ErrorActionPreference='Stop'
$global:WkRoot=Split-Path $PSScriptRoot -Parent
$global:WkApp=Join-Path $global:WkRoot 'app'
foreach($f in @('lib/Common.ps1','lib/I18n.ps1','lib/Offline.ps1','ui/Ui.ps1')){. (Join-Path $global:WkApp $f)}
Set-WkLanguage 'fa'
[xml]$xml=[IO.File]::ReadAllText((Join-Path $global:WkApp 'ui/MainWindow.xaml'))
$reader=New-Object Xml.XmlNodeReader $xml
$global:WkWindow=[Windows.Markup.XamlReader]::Load($reader)
foreach($n in $xml.SelectNodes('//*')){$name=$n.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($name){$global:WkUi[$name]=$global:WkWindow.FindName($name)}}
Build-WkLoginCards
if($global:WkUi.BtnStart.IsEnabled){throw 'Empty name accepted'}
$global:WkUi.TxtGuestName.Text='Test Operator';Update-WkHomeButtons
if($global:WkUi.BtnStart.IsEnabled){throw 'Empty asset accepted'}
$global:WkUi.TxtAsset.Text='1234';Update-WkHomeButtons
if(-not $global:WkUi.BtnStart.IsEnabled){throw 'Valid name/asset rejected'}
Update-WkDeployCard
if($global:WkUi.DeployCard.Visibility -ne 'Collapsed'){throw 'Deployment visible'}
if((Test-WkSupportConfig).enabled){throw 'API enabled'}
Write-Output 'PASS: WPF load, required name/asset, no API, hidden deployment.'
