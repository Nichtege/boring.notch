# Runs the notch at 150 % scale, as many laptops have it, and checks that it stays centered and that the mouse still meets it.
# If this machine won't scale, that gets said and the step passes: then this case stays untested.
param([string]$Exe, [string]$Out)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Display {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, int param, IntPtr value, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(long point, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE mode, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string device, int index, ref DEVMODE mode);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    public static string SetResolution(int width, int height) {
        var mode = new DEVMODE();
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, -1, ref mode);
        mode.dmPelsWidth = width;
        mode.dmPelsHeight = height;
        mode.dmFields = 0x80000 | 0x100000;
        return ChangeDisplaySettings(ref mode, 1).ToString();
    }
    public static uint MainScreenDpi() {
        uint x, y;
        IntPtr monitor = MonitorFromPoint(0, 1);
        return GetDpiForMonitor(monitor, 0, out x, out y) == 0 ? x : 0;
    }
}
'@

# Real pixels from here on, or the screenshots would be of a pretend smaller screen
[void][Display]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

New-Item -ItemType Directory -Force $Out | Out-Null
$results = New-Object Collections.ArrayList
$failures = 0
function Note([string]$text) { [void]$results.Add($text); Write-Output $text }
function Check([string]$name, [bool]$ok) { if ($ok) { Note "ok    $name" } else { Note "FAIL  $name"; $script:failures++ } }
function Finish {
    Note $(if ($failures -eq 0) { 'ALL OK' } else { "$failures FAILED" })
    $results | Set-Content -Path (Join-Path $Out 'ergebnis.txt') -Encoding UTF8
    exit $(if ($failures -eq 0) { 0 } else { 1 })
}

Note ("Before: " + [Display]::GetSystemMetrics(0) + " x " + [Display]::GetSystemMetrics(1) + " at " + [Display]::MainScreenDpi() + " dpi")
Note ("Asking for 1920 x 1080, answer " + [Display]::SetResolution(1920, 1080))
Start-Sleep -Seconds 2
foreach ($step in 1, 2, 3, 4) {
    if ([Display]::MainScreenDpi() -ge 144) { break }
    [void][Display]::SystemParametersInfo(0x9F, $step, [IntPtr]::Zero, 1)
    Start-Sleep -Seconds 2
}
$dpi = [Display]::MainScreenDpi()
$width = [Display]::GetSystemMetrics(0)
$height = [Display]::GetSystemMetrics(1)
Note "Now: $width x $height at $dpi dpi"
if ($dpi -le 96) {
    Note 'This machine does not scale, so the case stays untested here.'
    Finish
}

$s = $dpi / 96.0
$cx = [int]($width / 2)
function Wait([int]$ms) { Start-Sleep -Milliseconds $ms }
function Move-Mouse([int]$x, [int]$y) { [void][Display]::SetCursorPos($x, $y); [Display]::mouse_event(1, 0, 0, 0, [UIntPtr]::Zero) }
function Click([int]$x, [int]$y) { Move-Mouse $x $y; Wait 120; [Display]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Wait 40; [Display]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero); Wait 150 }
function Picture {
    $bitmap = New-Object Drawing.Bitmap $width, $height
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen(0, 0, 0, 0, $bitmap.Size)
    $graphics.Dispose()
    return $bitmap
}
function Shot([string]$name) { $b = Picture; $b.Save((Join-Path $Out "$name.png"), [Drawing.Imaging.ImageFormat]::Png); $b.Dispose() }
function Is-Black([int]$x, [int]$y) { $b = Picture; $c = $b.GetPixel($x, $y); $b.Dispose(); return ($c.R -lt 25 -and $c.G -lt 25 -and $c.B -lt 25) }
function Is-Target([int]$x, [int]$y) { $b = Picture; $c = $b.GetPixel($x, $y); $b.Dispose(); return ($c.R -eq 70 -and $c.G -eq 130 -and $c.B -eq 180) }
function Edges([int]$y) {
    $b = Picture
    $left = -1; $right = -1
    for ($x = [int]($cx - 400 * $s); $x -lt [int]($cx + 400 * $s); $x++) {
        $c = $b.GetPixel($x, $y)
        if ($c.R -lt 25 -and $c.G -lt 25 -and $c.B -lt 25) { if ($left -lt 0) { $left = $x }; $right = $x }
    }
    $b.Dispose()
    return @($left, $right)
}

$targetLog = Join-Path $Out 'zielfenster.log'
$target = Start-Process powershell -ArgumentList @('-STA', '-File', (Join-Path $PSScriptRoot 'target.ps1'), '-Log', $targetLog) -PassThru
Wait 2500
Remove-Item -Recurse -Force (Join-Path $env:APPDATA 'BoringNotch') -ErrorAction SilentlyContinue
$app = Start-Process $Exe -PassThru
Wait 3000
Move-Mouse $cx ([int](420 * $s))
Wait 500
Shot 's1-gestartet'

$closed = Edges 8
Note "Closed notch from $($closed[0]) to $($closed[1]), the screen's middle is $cx"
Check 'the closed notch is centered' ([Math]::Abs(($closed[0] + $closed[1]) / 2 - $cx) -le 2)
Check 'the closed notch has its scaled width' ([Math]::Abs(($closed[1] - $closed[0]) - 193 * $s) -le (20 * $s))

Click ([int]($cx + 300 * $s)) ([int](10 * $s))
Wait 300
Check 'a click beside it reaches the window behind' ((Test-Path $targetLog) -and (@(Get-Content $targetLog).Count -ge 1))

Move-Mouse $cx ([int](10 * $s))
Wait 1000
Shot 's2-offen'
Check 'hovering opens it' (Is-Black $cx ([int](185 * $s)))
$open = Edges ([int](100 * $s))
Note "Open notch from $($open[0]) to $($open[1])"
Check 'the open notch is centered' ([Math]::Abs(($open[0] + $open[1]) / 2 - $cx) -le 2)
Check 'the open notch has its scaled width' ([Math]::Abs(($open[1] - $open[0]) - 602 * $s) -le (20 * $s))

$bodyLeft = $cx - 289 * $s
Click ([int]($bodyLeft + 171 * $s)) ([int](16 * $s))
Wait 500
Shot 's3-timer'
Click ([int]($cx + 26 * $s)) ([int](109 * $s))
Wait 800
Shot 's4-timer-laeuft'
Move-Mouse $cx ([int](420 * $s))
Wait 1000
Shot 's5-zu-mit-timer'
Check 'a tab and a button are hit at this scale, the timer runs' (Is-Black ([int]($cx + 120 * $s)) ([int](12 * $s)))
Check 'closing works at this scale' (Is-Target $cx ([int](185 * $s)))

[Display]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); [Display]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[Display]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero); [Display]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
[Display]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero); [Display]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
Wait 800
[Windows.Forms.SendKeys]::SendWait('note')
Wait 2500
Shot 's6-suche'
$line = Edges ([int](64 * $s))
Note "Search line from $($line[0]) to $($line[1])"
Check 'the search line comes up' (-not (Is-Target $cx ([int](64 * $s))))
[Windows.Forms.SendKeys]::SendWait('{ESC}')
Wait 500
Check 'and goes again' (Is-Target $cx ([int](64 * $s)))

Check 'the app survived' (-not $app.HasExited)
$errors = Join-Path $env:APPDATA 'BoringNotch\fehler.log'
if (Test-Path $errors) { Copy-Item $errors $Out; Get-Content $errors | ForEach-Object { Note $_ } }
Check 'nothing in the error log' (-not (Test-Path $errors))

if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
Finish
