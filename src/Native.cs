using System;
using System.Runtime.InteropServices;
using System.Text;

namespace BoringNotch
{
    /// <summary>The few calls into Windows itself that .NET has no wrapper for.</summary>
    internal static class Native
    {
        public const int WM_HOTKEY = 0x0312;
        public const uint MOD_ALT = 0x0001;
        public const uint MOD_CONTROL = 0x0002;
        public const uint MOD_NOREPEAT = 0x4000;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const int WS_EX_NOACTIVATE = 0x08000000;

        private const int GWL_EXSTYLE = -20;
        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint MONITOR_DEFAULTTOPRIMARY = 1;
        private const uint MONITORINFOF_PRIMARY = 1;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MONITORINFO
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
        }

        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);

        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UnregisterHotKey(IntPtr hwnd, int id);

        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hwnd);

        [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeleteObject(IntPtr handle);

        [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
        private static extern int GetWindowLong(IntPtr hwnd, int index);

        [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
        private static extern int SetWindowLong(IntPtr hwnd, int index, int value);

        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(POINT point, uint flags);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

        [DllImport("user32.dll")]
        private static extern uint GetDpiForWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsZoomed(IntPtr hwnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int capacity);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr processId);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AttachThreadInput(uint attach, uint attachTo, [MarshalAs(UnmanagedType.Bool)] bool doAttach);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);

        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public static void AddExStyle(IntPtr hwnd, int style)
        {
            SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | style);
        }

        public static double ScaleOf(IntPtr hwnd)
        {
            try
            {
                uint dpi = GetDpiForWindow(hwnd);
                return dpi > 0 ? dpi / 96.0 : 1;
            }
            catch (EntryPointNotFoundException)
            {
                return 1;
            }
        }

        /// <summary>Puts a window at the top of the main screen, in its middle and above other windows.</summary>
        public static void PlaceTopCenter(IntPtr hwnd, double widthInDips, double heightInDips)
        {
            IntPtr monitor = MonitorFromPoint(new POINT(), MONITOR_DEFAULTTOPRIMARY);
            var info = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
            if (!GetMonitorInfo(monitor, ref info)) return;

            double scale = ScaleOf(hwnd);
            int width = (int)Math.Ceiling(widthInDips * scale);
            int height = (int)Math.Ceiling(heightInDips * scale);
            int x = info.rcMonitor.Left + (info.rcMonitor.Right - info.rcMonitor.Left - width) / 2;
            SetWindowPos(hwnd, HWND_TOPMOST, x, info.rcMonitor.Top, width, height, SWP_NOACTIVATE);
        }

        /// <summary>
        /// Windows only lets the app the user is working with hand over the keyboard. A hot key or a click normally
        /// counts as that. If it doesn't, going in along with the app in front is the usual way that still works.
        /// </summary>
        public static void BringToFront(IntPtr hwnd)
        {
            if (SetForegroundWindow(hwnd)) return;

            IntPtr foreground = GetForegroundWindow();
            uint other = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, IntPtr.Zero);
            uint own = GetCurrentThreadId();
            if (other == 0 || other == own || !AttachThreadInput(own, other, true)) return;
            try
            {
                SetForegroundWindow(hwnd);
            }
            finally
            {
                AttachThreadInput(own, other, false);
            }
        }

        public static void KeepOnTop(IntPtr hwnd)
        {
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }

        /// <summary>A video or game fills the main screen. A maximized window doesn't count, nor does the desktop.</summary>
        public static bool ForegroundIsFullscreenOnMainScreen(params IntPtr[] ownWindows)
        {
            IntPtr foreground = GetForegroundWindow();
            if (foreground == IntPtr.Zero || Array.IndexOf(ownWindows, foreground) >= 0) return false;
            if (IsZoomed(foreground)) return false;

            var name = new StringBuilder(64);
            GetClassName(foreground, name, name.Capacity);
            switch (name.ToString())
            {
                case "Progman":
                case "WorkerW":
                case "Shell_TrayWnd":
                case "Shell_SecondaryTrayWnd":
                    return false;
            }

            IntPtr monitor = MonitorFromWindow(foreground, MONITOR_DEFAULTTOPRIMARY);
            var info = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
            if (!GetMonitorInfo(monitor, ref info) || (info.dwFlags & MONITORINFOF_PRIMARY) == 0) return false;
            if (!GetWindowRect(foreground, out RECT window)) return false;

            return window.Left <= info.rcMonitor.Left && window.Top <= info.rcMonitor.Top
                && window.Right >= info.rcMonitor.Right && window.Bottom >= info.rcMonitor.Bottom;
        }

        /// <summary>The exe behind a process, or null if Windows won't say.</summary>
        public static string ProcessPath(uint processId)
        {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero) return null;
            try
            {
                var name = new StringBuilder(1024);
                uint size = (uint)name.Capacity;
                return QueryFullProcessImageName(process, 0, name, ref size) ? name.ToString() : null;
            }
            finally
            {
                CloseHandle(process);
            }
        }
    }
}
