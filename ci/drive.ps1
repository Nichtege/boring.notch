# Uses the real exe with a real mouse and keyboard, and checks what's on screen and what reached other windows.
param([string]$Exe, [string]$Out)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Input {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@

New-Item -ItemType Directory -Force $Out | Out-Null
$results = New-Object Collections.ArrayList
$failures = 0
$screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$cx = [int]($screen.Width / 2)
$bodyLeft = $cx - 289
$targetLog = Join-Path $Out 'zielfenster.log'
$sampleFile = Join-Path $Out 'Beispiel.txt'
Set-Content -Path $sampleFile -Value 'Boring Notch'
$shelfFile = Join-Path $env:APPDATA 'BoringNotch\ablage.txt'
Remove-Item -Recurse -Force (Join-Path $env:APPDATA 'BoringNotch') -ErrorAction SilentlyContinue

function Note([string]$text) { [void]$results.Add($text); Write-Output $text }
function Check([string]$name, [bool]$ok) {
    if ($ok) { Note "ok    $name" } else { Note "FAIL  $name"; $script:failures++ }
}
function Wait([int]$ms) { Start-Sleep -Milliseconds $ms }
function Move-Mouse([int]$x, [int]$y) { [void][Input]::SetCursorPos($x, $y); [Input]::mouse_event(1, 0, 0, 0, [UIntPtr]::Zero) }
function Glide([int]$fromX, [int]$fromY, [int]$toX, [int]$toY) {
    for ($i = 1; $i -le 15; $i++) {
        Move-Mouse ($fromX + ($toX - $fromX) * $i / 15) ($fromY + ($toY - $fromY) * $i / 15)
        Wait 25
    }
}
function Press-Down { [Input]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero) }
function Press-Up { [Input]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero) }
function Click([int]$x, [int]$y) { Move-Mouse $x $y; Wait 120; Press-Down; Wait 40; Press-Up; Wait 150 }
function Picture {
    $bitmap = New-Object Drawing.Bitmap $screen.Width, $screen.Height
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($screen.X, $screen.Y, 0, 0, $bitmap.Size)
    $graphics.Dispose()
    return $bitmap
}
function Shot([string]$name) {
    $bitmap = Picture
    $bitmap.Save((Join-Path $Out "$name.png"), [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}
function Is-Black([int]$x, [int]$y) {
    $bitmap = Picture
    $c = $bitmap.GetPixel($x, $y)
    $bitmap.Dispose()
    return ($c.R -lt 25 -and $c.G -lt 25 -and $c.B -lt 25)
}
function Is-Target-Color([int]$x, [int]$y) {
    $bitmap = Picture
    $c = $bitmap.GetPixel($x, $y)
    $bitmap.Dispose()
    return ($c.R -eq 70 -and $c.G -eq 130 -and $c.B -eq 180)
}
function Target-Says { if (Test-Path $targetLog) { return @(Get-Content $targetLog) } return @() }
function Start-Target([switch]$Fullscreen) {
    $arguments = @('-STA', '-File', (Join-Path $PSScriptRoot 'target.ps1'), '-Log', $targetLog, '-File', $sampleFile)
    if ($Fullscreen) { $arguments += '-Fullscreen' }
    return Start-Process powershell -ArgumentList $arguments -PassThru
}
function Stage([string]$name, [scriptblock]$body) {
    Note "--- $name"
    try { & $body } catch { Note "FAIL  ${name}: $_"; $script:failures++ }
}

$target = Start-Target
Wait 2500
$app = Start-Process $Exe -PassThru
Wait 3000
Move-Mouse $cx 420
Wait 500
Shot 'a1-gestartet'

Stage 'starting' {
    Check 'the app is still running after 3 s' (-not $app.HasExited)
    Check 'the closed notch is black' (Is-Black $cx 10)
    Check 'there is nothing below the closed notch' (Is-Target-Color $cx 60)
    Check 'there is nothing beside the closed notch' (Is-Target-Color ($cx + 130) 10)
}

Stage 'clicks pass through beside the notch' {
    Click ($cx + 300) 10
    Wait 300
    Check 'a click beside the notch reaches the window behind it' ((Target-Says) -contains "down $($cx + 300) 10")
    Check 'that does not open the notch' (Is-Target-Color $cx 185)
}

Stage 'hover opens and closes' {
    Move-Mouse $cx 420
    Wait 300
    Move-Mouse $cx 10
    Wait 120
    Check 'not open yet at 0.1 s' (Is-Target-Color $cx 185)
    Wait 1000
    Shot 'b1-offen'
    Check 'open after a second' (Is-Black $cx 185)
    Check 'the open notch has its full width' (Is-Black ($cx + 295) 100)
    Check 'and no more than that' (Is-Target-Color ($cx + 330) 100)
    Move-Mouse $cx 420
    Wait 1000
    Shot 'b2-wieder-zu'
    Check 'closed after the mouse left' (Is-Target-Color $cx 185)
    Check 'the closed notch is back' (Is-Black $cx 10)
}

Stage 'a click on the notch does not reach the window behind' {
    $before = (Target-Says).Count
    Click $cx 10
    Wait 800
    Check 'the click stays on the notch' ((Target-Says).Count -eq $before)
    Check 'and opens it' (Is-Black $cx 185)
    Move-Mouse $cx 420
    Wait 900
}

Stage 'tabs' {
    Move-Mouse $cx 10
    Wait 900
    Click ($bodyLeft + 69) 16
    Wait 1600
    Shot 'c1-mixer'
    Click ($bodyLeft + 115) 16
    Wait 500
    Shot 'c2-timer'
    Click ($cx + 26) 109
    Wait 1300
    Shot 'c3-timer-laeuft'
    Move-Mouse $cx 420
    Wait 1000
    Shot 'c4-zu-mit-timer'
    Check 'the running timer widens the closed notch' (Is-Black ($cx + 120) 12)
    Check 'but not by more than that' (Is-Target-Color ($cx + 145) 12)

    Move-Mouse $cx 10
    Wait 900
    Click ($bodyLeft + 115) 16
    Wait 500
    Click ($cx + 108) 109
    Wait 500
    Shot 'c5-timer-gestoppt'
    Move-Mouse $cx 420
    Wait 1000
    Check 'a stopped timer gives the width back' (Is-Target-Color ($cx + 120) 12)
}

Stage 'search with the hot key' {
    Move-Mouse $cx 420
    [Input]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [Input]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [Input]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)
    [Input]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
    [Input]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [Input]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Wait 800
    Shot 'd1-suche'
    Check 'Ctrl+Alt+A brings up the line' (-not (Is-Target-Color $cx 64))
    [Windows.Forms.SendKeys]::SendWait('note')
    Wait 2500
    Shot 'd2-suche-tippt'
    Check 'typing grows it' (-not (Is-Target-Color $cx 130))
    [Windows.Forms.SendKeys]::SendWait('{DOWN}')
    Wait 300
    Shot 'd3-suche-pfeil'
    [Windows.Forms.SendKeys]::SendWait('{ESC}')
    Wait 500
    Shot 'd4-suche-esc'
    Check 'Esc takes it away' (Is-Target-Color $cx 64)
}

Stage 'search finds a real file' {
    Move-Mouse $cx 420
    [Input]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [Input]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [Input]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)
    [Input]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
    [Input]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [Input]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Wait 600
    [Windows.Forms.SendKeys]::SendWait('NotchSuchprobe')
    Wait 3000
    Shot 'd5-suche-datei'
    [Windows.Forms.SendKeys]::SendWait('{ESC}')
    Wait 500
    Check 'Esc takes it away again' (Is-Target-Color $cx 64)
}

Stage 'search from the notch' {
    Move-Mouse $cx 10
    Wait 900
    Click ($bodyLeft + 161) 16
    Wait 900
    Shot 'e1-suche-aus-notch'
    Check 'the notch closes' (Is-Target-Color ($cx + 295) 100)
    Check 'and the line comes down' (-not (Is-Target-Color $cx 64))
    Click ($cx + 400) 420
    Wait 500
    Shot 'e2-weggeklickt'
    Check 'a click elsewhere takes it away' (Is-Target-Color $cx 64)
}

Stage 'a file dragged onto the notch' {
    Move-Mouse ($cx - 300) 400
    Wait 200
    Press-Down
    Wait 200
    Glide ($cx - 300) 400 $cx 12
    Wait 900
    Shot 'f1-ziehen-ueber-notch'
    Check 'dragging onto the closed notch opens it' (Is-Black $cx 185)
    Glide $cx 12 $cx 100
    Wait 300
    Press-Up
    Wait 1200
    Shot 'f2-abgelegt'
    Check 'the file is on the shelf' ((Test-Path $shelfFile) -and ((Get-Content $shelfFile) -contains $sampleFile))
}

Stage 'a file dragged out of the notch' {
    Move-Mouse ($bodyLeft + 65) 110
    Wait 900
    Shot 'g1-kachel'
    Press-Down
    Wait 200
    Glide ($bodyLeft + 65) 110 ($cx - 300) 400
    Wait 400
    Press-Up
    Wait 800
    Shot 'g2-rausgezogen'
    Check 'the other window got the file' ((Target-Says) -contains "dropped $sampleFile")
    Check 'the shelf still has it' ((Get-Content $shelfFile) -contains $sampleFile)
}

Stage 'the shelf over a restart' {
    Stop-Process -Id $app.Id -Force
    Wait 800
    $script:app = Start-Process $Exe -PassThru
    Wait 2500
    Move-Mouse $cx 10
    Wait 1000
    Shot 'h1-neustart'
    Check 'it opens again after a restart' (Is-Black $cx 185)
    Check 'the file is still listed' ((Get-Content $shelfFile) -contains $sampleFile)
    Move-Mouse $cx 420
    Wait 800
}

Stage 'only one at a time' {
    $second = Start-Process $Exe -PassThru
    Wait 2500
    Check 'a second start ends by itself' ($second.HasExited)
}

Stage 'full screen' {
    Stop-Process -Id $target.Id -Force
    Wait 500
    $script:target = Start-Target -Fullscreen
    Wait 3500
    Shot 'i1-vollbild'
    Check 'the notch hides over a full-screen window' (Is-Target-Color $cx 10)
    Move-Mouse $cx 10
    Wait 900
    Check 'and does not open there' (Is-Target-Color $cx 185)
    Move-Mouse $cx 420
    Stop-Process -Id $target.Id -Force
    Wait 2500
    Shot 'i2-nach-vollbild'
    Check 'it comes back afterwards' (Is-Black $cx 10)
}

Stage 'at the end' {
    Check 'the app survived all of this' (-not $app.HasExited)
    $errors = Join-Path $env:APPDATA 'BoringNotch\fehler.log'
    if (Test-Path $errors) {
        Copy-Item $errors $Out
        Note '--- fehler.log'
        Get-Content $errors | ForEach-Object { Note $_ }
    }
    Check 'nothing was written to the error log' (-not (Test-Path $errors))
}

if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
Note $(if ($failures -eq 0) { 'ALL OK' } else { "$failures FAILED" })
$results | Set-Content -Path (Join-Path $Out 'ergebnis.txt') -Encoding UTF8
exit $(if ($failures -eq 0) { 0 } else { 1 })
