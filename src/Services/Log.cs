using System;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace BoringNotch
{
    /// <summary>
    /// What went wrong, for whoever looks into it later. It never throws, and what the user typed or which files
    /// they have stays out: messages lose anything quoted and anything that looks like a path.
    /// </summary>
    internal static class Log
    {
        private const long MaxSize = 1024 * 1024;

        private static readonly object Gate = new object();
        private static readonly Regex Private = new Regex(
            @"'[^']*'|""[^""]*""|[A-Za-z]:\\\S*|\\\\\S*|shell:\S*|file:\S*",
            RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        public static string Folder { get; } = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "BoringNotch");

        public static void Error(Exception e)
        {
            string description;
            try
            {
                description = Describe(e);
            }
            catch (Exception)
            {
                // A message or stack trace of a broken exception can throw as well
                description = e?.GetType().FullName ?? "unknown";
            }
            Write("FEHLER " + description);
        }

        /// <summary>Written as it is, so callers only pass fixed texts, types and numbers.</summary>
        public static void Note(string text)
        {
            Write(text);
        }

        private static string Describe(Exception e)
        {
            if (e == null) return "unknown";

            var result = new StringBuilder();
            for (Exception current = e; current != null; current = current.InnerException)
            {
                if (current != e)
                {
                    result.AppendLine().Append("  verursacht durch ");
                }
                result.Append(current.GetType().FullName)
                    .Append(" (0x").Append(current.HResult.ToString("X8", CultureInfo.InvariantCulture)).Append("): ")
                    .Append(Private.Replace(current.Message ?? "", "<privat>"));
                if (!string.IsNullOrEmpty(current.StackTrace))
                {
                    result.AppendLine().Append(current.StackTrace);
                }
            }
            return result.ToString();
        }

        private static void Write(string text)
        {
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(Folder);
                    string file = Path.Combine(Folder, "fehler.log");
                    var existing = new FileInfo(file);
                    if (existing.Exists && existing.Length > MaxSize)
                    {
                        existing.Delete();
                    }
                    string time = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
                    File.AppendAllText(file, time + " " + text + Environment.NewLine, new UTF8Encoding(false));
                }
            }
            catch (Exception)
            {
                // Nothing is left to tell about a log that can't be written, and the app has to go on without it
            }
        }
    }
}
