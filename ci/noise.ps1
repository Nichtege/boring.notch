# Another app making sound beside the player and telling Windows nothing about it. The graph must not hear this.
# Only for the test machine.
Add-Type @'
using System; using System.IO;
public static class Noise {
    public static void Write(string file, int rate, int seconds) {
        int samples = rate * seconds;
        var random = new Random(1);
        using (var w = new BinaryWriter(File.Create(file))) {
            w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + samples * 2);
            w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16); w.Write((short)1); w.Write((short)1);
            w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
            w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(samples * 2);
            for (int i = 0; i < samples; i++) {
                double t = (double)i / rate;
                w.Write((short)(Math.Exp(-(t % 0.25) * 12) * random.Next(-9000, 9000)));
            }
        }
    }
}
'@
$file = Join-Path $env:TEMP "notch-noise-$PID.wav"
[Noise]::Write($file, 22050, 5)
$player = New-Object Media.SoundPlayer $file
$player.PlayLooping()
Start-Sleep -Seconds 900
