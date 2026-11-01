# A real player for the test: a song-like loop that Windows knows as a playing song with a title and a cover.
# It writes down where it is, so a button in the notch can be seen arriving. Only for the test machine.
param([string]$Log)

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.IO;
public static class Song {
    public static void Write(string file, int rate, int seconds) {
        int samples = rate * seconds;
        using (var w = new BinaryWriter(File.Create(file))) {
            w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + samples * 2);
            w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)1);
            w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
            w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(samples * 2);
            for (int i = 0; i < samples; i++) {
                double t = (double)i / rate;
                double kick = Math.Exp(-(t % 0.5) * 9) * Math.Sin(2 * Math.PI * 90 * t);
                double mid = Math.Exp(-((t + 0.25) % 0.5) * 7) * Math.Sin(2 * Math.PI * 440 * t);
                double air = Math.Exp(-(t % 0.125) * 30) * Math.Sin(2 * Math.PI * 6500 * t);
                w.Write((short)(5000 * kick + 3000 * mid + 1500 * air));
            }
        }
    }
}
'@
$file = Join-Path $env:TEMP "notch-probe-$PID.wav"
[Song]::Write($file, 44100, 60)

$coverFile = Join-Path $env:TEMP "notch-probe-$PID.png"
$cover = New-Object Drawing.Bitmap 256, 256
$graphics = [Drawing.Graphics]::FromImage($cover)
$brush = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle 0, 0, 256, 256), [Drawing.Color]::DeepPink, [Drawing.Color]::DarkOrange, 45)
$graphics.FillRectangle($brush, 0, 0, 256, 256)
$graphics.Dispose()
$cover.Save($coverFile, [Drawing.Imaging.ImageFormat]::Png)
$cover.Dispose()

[void][Windows.Media.Playback.MediaPlayer, Windows.Media.Playback, ContentType = WindowsRuntime]
[void][Windows.Media.Playback.MediaPlaybackItem, Windows.Media.Playback, ContentType = WindowsRuntime]
[void][Windows.Media.Core.MediaSource, Windows.Media.Core, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.RandomAccessStreamReference, Windows.Storage.Streams, ContentType = WindowsRuntime]

$source = [Windows.Media.Core.MediaSource]::CreateFromUri([Uri]("file:///" + $file.Replace('\', '/')))
$item = New-Object Windows.Media.Playback.MediaPlaybackItem($source)
$properties = $item.GetDisplayProperties()
$properties.Type = [Windows.Media.MediaPlaybackType, Windows.Media, ContentType = WindowsRuntime]::Music
$properties.MusicProperties.Title = 'Probe Titel mit einem langen Namen, damit er durchlaeuft und man es sieht'
$properties.MusicProperties.Artist = 'Probe Kuenstler'
$properties.Thumbnail = [Windows.Storage.Streams.RandomAccessStreamReference]::CreateFromUri([Uri]("file:///" + $coverFile.Replace('\', '/')))
$item.ApplyDisplayProperties($properties)

$player = New-Object Windows.Media.Playback.MediaPlayer
$player.IsLoopingEnabled = $true
$player.Source = $item
$player.Play()

for ($i = 0; $i -lt 3000; $i++) {
    $session = $player.PlaybackSession
    Add-Content -Path $Log -Value ("{0} {1}" -f $session.PlaybackState, [int]$session.Position.TotalSeconds)
    Start-Sleep -Milliseconds 300
}
