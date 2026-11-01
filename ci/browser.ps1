# Serves a page that plays a song in a real browser with a title, a cover and skip buttons, the way a music site does.
# Only for the test machine.
param([string]$Folder, [int]$Port = 8765)

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.IO;
public static class BrowserSong {
    public static byte[] Make(int rate, int seconds) {
        int samples = rate * seconds;
        var stream = new MemoryStream();
        var w = new BinaryWriter(stream);
        w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + samples * 2);
        w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)1);
        w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(samples * 2);
        for (int i = 0; i < samples; i++) {
            double t = (double)i / rate;
            double kick = Math.Exp(-(t % 0.5) * 9) * Math.Sin(2 * Math.PI * 90 * t);
            double mid = Math.Exp(-((t + 0.25) % 0.5) * 7) * Math.Sin(2 * Math.PI * 440 * t);
            w.Write((short)(5000 * kick + 3000 * mid));
        }
        w.Flush();
        return stream.ToArray();
    }
}
'@

$song = [BrowserSong]::Make(22050, 60)

$image = New-Object Drawing.Bitmap 512, 512
$graphics = [Drawing.Graphics]::FromImage($image)
$fill = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle 0, 0, 512, 512), [Drawing.Color]::DeepPink, [Drawing.Color]::DarkOrange, 45)
$graphics.FillRectangle($fill, 0, 0, 512, 512)
$graphics.Dispose()
$coverStream = New-Object IO.MemoryStream
$image.Save($coverStream, [Drawing.Imaging.ImageFormat]::Png)
$image.Dispose()
$cover = $coverStream.ToArray()

$page = @'
<!doctype html><meta charset="utf-8"><title>Probe</title>
<audio id="a" src="/song.wav" loop autoplay></audio><p id="s">wartet</p>
<script>
const a = document.getElementById('a');
navigator.mediaSession.metadata = new MediaMetadata({
  title: 'Titel aus dem Browser', artist: 'Kuenstler aus dem Browser', album: 'Probe',
  artwork: [{ src: '/cover.png', sizes: '512x512', type: 'image/png' }]
});
let skips = 0;
navigator.mediaSession.setActionHandler('nexttrack', () => { skips++; fetch('/skip?n=' + skips); });
navigator.mediaSession.setActionHandler('previoustrack', () => { skips++; fetch('/skip?n=' + skips); });
a.play().then(() => { document.getElementById('s').textContent = 'spielt'; }).catch(e => { document.getElementById('s').textContent = e; });
</script>
'@
$pageBytes = [Text.Encoding]::UTF8.GetBytes($page)

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
while ($listener.IsListening) {
    $context = $listener.GetContext()
    $path = $context.Request.Url.AbsolutePath
    $response = $context.Response
    try {
        if ($path -eq '/song.wav') { $body = $song; $response.ContentType = 'audio/wav' }
        elseif ($path -eq '/cover.png') { $body = $cover; $response.ContentType = 'image/png' }
        elseif ($path -eq '/skip') { Add-Content -Path (Join-Path $Folder 'browser-skips.log') -Value $context.Request.Url.Query; $body = [byte[]]@() }
        else { $body = $pageBytes; $response.ContentType = 'text/html; charset=utf-8' }
        $response.ContentLength64 = $body.Length
        if ($body.Length -gt 0) { $response.OutputStream.Write($body, 0, $body.Length) }
    } catch {
        # A browser that lets go of a song halfway isn't a problem here
    } finally {
        $response.Close()
    }
}
