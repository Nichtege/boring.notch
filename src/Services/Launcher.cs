using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;

namespace BoringNotch
{
    /// <summary>Opens what was found, the way a double click in Explorer would.</summary>
    internal static class Launcher
    {
        private const string AppPrefix = "shell:AppsFolder\\";
        private const string Explorer = "explorer.exe";

        /// <summary>False if Windows couldn't open it.</summary>
        public static bool Open(string target)
        {
            if (string.IsNullOrWhiteSpace(target)) return false;

            return target.StartsWith(AppPrefix, StringComparison.OrdinalIgnoreCase)
                ? Start(Explorer, Quoted(target))
                : Start(target, null);
        }

        public static bool ShowInExplorer(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return false;

            return Start(Explorer, "/select," + Quoted(path));
        }

        // Windows paths can't hold a quote, so one here could only break out of the argument
        private static string Quoted(string text)
        {
            return "\"" + text.Replace("\"", "") + "\"";
        }

        private static bool Start(string file, string arguments)
        {
            try
            {
                var info = new ProcessStartInfo(file) { UseShellExecute = true };
                if (arguments != null)
                {
                    info.Arguments = arguments;
                }
                // As from a double click: a program looks for its own files beside it, not beside this app
                if (File.Exists(file))
                {
                    info.WorkingDirectory = Path.GetDirectoryName(file);
                }

                // Null for what an already running program took over, which counts as opened
                using (Process.Start(info))
                {
                }
                return true;
            }
            catch (Exception e) when (e is Win32Exception || e is InvalidOperationException || e is FileNotFoundException)
            {
                // Only the type and the code: the message can name the file
                Log.Note("Öffnen: " + e.GetType().Name + " 0x" + e.HResult.ToString("X8", CultureInfo.InvariantCulture));
                return false;
            }
        }
    }
}
