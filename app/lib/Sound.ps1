# Sounds (Phase 4, D-019). Optional user files in assets\sounds\ (names in rules.json "sounds.files"):
#   guest_welcome  - played when a guest presses Start (guest_welcome.mp3, Phase 12)
#   speaker_test   - played by the speaker test (left / right / both); fallback: a generated 440 Hz stereo tone
#   test_done      - a stress test finished OK
#   report_saved   - the report was saved
# Missing file = silent (except speaker_test, which always has the generated tone). Never throws.

$global:WkSoundNames = @('speaker_test', 'test_done', 'report_saved')

function Get-WkSoundDir { return (Join-Path $global:WkRoot 'assets\sounds') }

function Test-WkSoundsEnabled {
    try { $s = (Get-WkRules).sounds; if ($s -and $null -ne $s.enabled) { return [bool]$s.enabled } } catch { }
    return $true
}

function Get-WkSoundFile([string]$Name) {
    $file = $Name + '.wav'
    try { $f = (Get-WkRules).sounds.files.$Name; if ($f) { $file = [string]$f } } catch { }
    $p = Join-Path (Get-WkSoundDir) $file
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Invoke-WkSound([string]$Name) {
    if (-not (Test-WkSoundsEnabled)) { return }
    $f = Get-WkSoundFile $Name
    if (-not $f) { return }
    try {
        if ($f -like '*.wav') { $global:WkSoundPlayer = New-Object System.Media.SoundPlayer $f; $global:WkSoundPlayer.Play() }
        else { Start-WkMedia $f 0 }
    } catch { Write-WkLog ('sound ' + $Name + ' failed: ' + $_.Exception.Message) 'WARN' }
}

# 16-bit stereo PCM sine tone with short fades (used when assets\sounds\speaker_test.wav is missing).
function New-WkToneWav([string]$Path, [int]$Freq = 440, [double]$Seconds = 1.5) {
    $rate = 44100; $n = [int]($rate * $Seconds); $dataLen = $n * 4
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $dataLen)); $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]2); $w.Write([int]$rate); $w.Write([int]($rate * 4)); $w.Write([int16]4); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$dataLen)
    $fade = [int]($rate * 0.05)
    $k = 2.0 * [math]::PI * $Freq / $rate
    for ($i = 0; $i -lt $n; $i++) {
        $amp = 0.35
        if ($i -lt $fade) { $amp = $amp * $i / $fade } elseif ($i -gt $n - $fade) { $amp = $amp * ($n - $i) / $fade }
        $v = [int16]([math]::Sin($k * $i) * 32767 * $amp)
        $w.Write($v); $w.Write($v)
    }
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $w.Close()
}

function Start-WkMedia([string]$File, [double]$Balance) {
    if (-not $global:WkMedia) {
        $global:WkMedia = New-Object System.Windows.Media.MediaPlayer   # kept global, else it is collected mid-play
        # Phase 11: the UI sets $global:WkMediaEnded to learn that a speaker test sound played to its end.
        $global:WkMedia.Add_MediaEnded({ try { if ($global:WkMediaEnded) { & $global:WkMediaEnded } } catch { } })
    }
    $global:WkMediaPurpose = 'sound'
    $global:WkMedia.Stop()
    $global:WkMedia.Open([Uri]$File)
    $global:WkMedia.Balance = $Balance
    $global:WkMedia.Volume = 1.0
    $global:WkMedia.Play()
}

function Test-WkVideoFile([string]$Path) { return ($Path -match '\.(mp4|wmv|avi|mov|mkv)$') }

# Side: left | right | both. Uses the user's speaker_test file only when it is audio; a video gets its own window (Show-WkSpeakerVideo).
function Start-WkSpeakerTest([string]$Side) {
    $f = Get-WkSoundFile 'speaker_test'
    if ($f -and (Test-WkVideoFile $f)) { $f = $null }
    if (-not $f) {
        $f = Join-Path $env:TEMP 'wk_speaker_tone.wav'
        if (-not (Test-Path -LiteralPath $f)) { New-WkToneWav $f }
    }
    $bal = 0.0
    if ($Side -eq 'left') { $bal = -1.0 } elseif ($Side -eq 'right') { $bal = 1.0 }
    Start-WkMedia $f $bal
    $global:WkMediaPurpose = 'speaker'
    Write-WkLog ('speaker test ' + $Side + ': ' + $f)
}

# The user's speaker test video (it announces left/right itself), in a modal window with a Close button.
function Show-WkSpeakerVideo {
    $f = Get-WkSoundFile 'speaker_test'
    if (-not $f -or -not (Test-WkVideoFile $f)) { Start-WkSpeakerTest 'both'; return }
    if ($global:WkMedia) { $global:WkMedia.Stop() }
    $w = New-Object System.Windows.Window
    $w.Title = T 'stress.videoTitle'; $w.Width = 900; $w.Height = 600; $w.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#000000')
    $w.WindowStartupLocation = 'CenterOwner'
    if ($global:WkWindow) { $w.Owner = $global:WkWindow }
    $grid = New-Object System.Windows.Controls.Grid
    $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = '*'
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = 'Auto'
    $grid.RowDefinitions.Add($r0); $grid.RowDefinitions.Add($r1)
    $me = New-Object System.Windows.Controls.MediaElement
    $me.LoadedBehavior = 'Manual'; $me.UnloadedBehavior = 'Stop'; $me.Volume = 1.0
    $me.Source = [Uri]$f
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = T 'common.close'; $btn.Height = 44; $btn.FontSize = 16; $btn.Margin = '12'; $btn.Name = 'VideoClose'
    [System.Windows.Controls.Grid]::SetRow($btn, 1)
    [void]$grid.Children.Add($me); [void]$grid.Children.Add($btn)
    $w.Content = $grid
    $global:WkVideoWin = $w; $global:WkVideoMe = $me
    $btn.Add_Click({ try { $global:WkVideoWin.Close() } catch { } })
    $me.Add_MediaEnded({ try { $global:WkVideoEnded = $true; $global:WkVideoMe.Position = [TimeSpan]::Zero; $global:WkVideoMe.Pause() } catch { } })
    $w.Add_Closed({ try { $global:WkVideoMe.Stop(); $global:WkVideoMe.Close() } catch { } })
    $w.Add_Loaded({ try { $global:WkVideoMe.Play() } catch { } })
    Write-WkLog ('speaker video: ' + $f)
    [void]$w.ShowDialog()
}
