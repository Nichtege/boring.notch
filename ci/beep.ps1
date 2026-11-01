# A quiet, endless tone, so a real app shows up in the Mixer. Only for the test machine.
$rate = 22050
$samples = $rate * 2
$file = Join-Path $env:TEMP 'notch-beep.wav'
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
    $writer.Write([int16](3000 * [Math]::Sin(2 * [Math]::PI * 440 * $i / $rate)))
}
$writer.Close()
$player = New-Object Media.SoundPlayer $file
$player.PlayLooping()
Start-Sleep -Seconds 900
