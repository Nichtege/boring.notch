# A real player for the test: a quiet, endless tone that Windows knows as a playing song with a title.
# It writes down whether it plays, so a button in the notch can be seen arriving. Only for the test machine.
param([string]$Log)

$rate = 44100
$samples = $rate * 4
$file = Join-Path $env:TEMP "notch-probe-$PID.wav"
$stream = [IO.File]::Create($file)
$writer = New-Object IO.BinaryWriter($stream)
$writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
$writer.Write([int](36 + $samples * 2))
$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
$writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]1)
$writer.Write([int]$rate); $writer.Write([int]($rate * 2)); $writer.Write([int16]2); $writer.Write([int16]16)
$writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
$writer.Write([int]($samples * 2))
for ($i = 0; $i -lt $samples; $i++) {
    # Low and high together, so the graph has something at both ends
    $value = 2500 * [Math]::Sin(2 * [Math]::PI * 110 * $i / $rate) + 1500 * [Math]::Sin(2 * [Math]::PI * 6000 * $i / $rate)
    $writer.Write([int16]$value)
}
$writer.Close()

[void][Windows.Media.Playback.MediaPlayer, Windows.Media.Playback, ContentType = WindowsRuntime]
[void][Windows.Media.Core.MediaSource, Windows.Media.Core, ContentType = WindowsRuntime]
$player = New-Object Windows.Media.Playback.MediaPlayer
$player.Source = [Windows.Media.Core.MediaSource]::CreateFromUri([Uri]("file:///" + $file.Replace('\', '/')))
$player.IsLoopingEnabled = $true
$controls = $player.SystemMediaTransportControls
$controls.IsEnabled = $true
$display = $controls.DisplayUpdater
$display.Type = [Windows.Media.MediaPlaybackType, Windows.Media, ContentType = WindowsRuntime]::Music
$display.MusicProperties.Title = 'Probe Titel mit einem langen Namen damit er laeuft'
$display.MusicProperties.Artist = 'Probe Kuenstler'
$display.Update()
$player.Play()

for ($i = 0; $i -lt 1800; $i++) {
    Add-Content -Path $Log -Value ([string]$player.PlaybackSession.PlaybackState)
    Start-Sleep -Milliseconds 500
}
