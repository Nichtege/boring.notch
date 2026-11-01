using System;
using System.Collections.Generic;
using System.Linq;

namespace BoringNotch.Core
{
    public static class PlaybackMath
    {
        /// <summary>1:05, or 1:02:03 from an hour on.</summary>
        public static string TimeText(double seconds)
        {
            int whole = double.IsNaN(seconds) || seconds < 0 ? 0 : (int)Math.Min(seconds, int.MaxValue);
            int totalMinutes = whole / 60;
            int remainingSeconds = whole % 60;
            int hours = totalMinutes / 60;
            int minutes = totalMinutes % 60;
            return hours > 0
                ? string.Format("{0}:{1:00}:{2:00}", hours, minutes, remainingSeconds)
                : string.Format("{0}:{1:00}", minutes, remainingSeconds);
        }

        /// <summary>Where a song is by now: apps say where it was and when, and some of them rarely.</summary>
        public static double Estimated(double elapsed, double duration, bool isPlaying, double rate, DateTime elapsedAtUtc, DateTime nowUtc)
        {
            if (!isPlaying) return Math.Min(elapsed, duration);

            double estimated = elapsed + (nowUtc - elapsedAtUtc).TotalSeconds * rate;
            return Math.Min(Math.Max(0, estimated), duration);
        }
    }

    public struct Rgb
    {
        public byte R;
        public byte G;
        public byte B;

        public Rgb(byte red, byte green, byte blue)
        {
            R = red;
            G = green;
            B = blue;
        }
    }

    public static partial class ColorMath
    {
        private const double MinimumBrightness = 0.5;
        private const double NearBlack = 0.03;

        /// <summary>
        /// The middle color of a picture in BGRA bytes, as the Mac's averageColor: a dark cover is brightened so tinted
        /// text stays readable, and a nearly black one becomes plain gray.
        /// </summary>
        public static Rgb Average(byte[] bgra)
        {
            if (bgra == null || bgra.Length < 4) return new Rgb(255, 255, 255);

            long pixels = bgra.Length / 4;
            long blue = 0, green = 0, red = 0;
            for (long i = 0; i < pixels; i++)
            {
                blue += bgra[i * 4];
                green += bgra[i * 4 + 1];
                red += bgra[i * 4 + 2];
            }
            double r = red / (double)pixels / 255;
            double g = green / (double)pixels / 255;
            double b = blue / (double)pixels / 255;

            if (r < NearBlack && g < NearBlack && b < NearBlack) return FromFractions(MinimumBrightness, MinimumBrightness, MinimumBrightness);

            // The same hue at the minimum brightness with less saturation, which comes down to lifting every channel alike
            double brightest = Math.Max(r, Math.Max(g, b));
            if (brightest < MinimumBrightness)
            {
                double lift = MinimumBrightness - brightest;
                r += lift;
                g += lift;
                b += lift;
            }
            return FromFractions(r, g, b);
        }

        /// <summary>
        /// The Mac's ensureMinimumBrightness: scales a color to this perceived brightness. As there, that also darkens a
        /// brighter one, and it's the same color at a level text can be read on black.
        /// </summary>
        public static Rgb EnsureMinimumBrightness(Rgb color, double factor)
        {
            if (factor < 0 || factor > 1) return color;

            double r = color.R / 255.0;
            double g = color.G / 255.0;
            double b = color.B / 255.0;
            double perceived = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            if (perceived <= 0) return FromFractions(factor, factor, factor);

            double scale = factor / perceived;
            return FromFractions(r * scale, g * scale, b * scale);
        }

        private static Rgb FromFractions(double r, double g, double b)
        {
            return new Rgb(ToByte(r), ToByte(g), ToByte(b));
        }

        private static byte ToByte(double fraction)
        {
            return (byte)Math.Round(Math.Max(0, Math.Min(1, fraction)) * 255);
        }
    }

    /// <summary>Which of the apps reporting to Windows the notch shows.</summary>
    public static class SessionChoice
    {
        /// <summary>
        /// What's shown stays while it plays or sits paused with nothing else playing. Something playing takes over from
        /// something that isn't. Null if there's nothing at all. Sessions are app id and whether it plays.
        /// </summary>
        public static string Pick(string shownId, string currentId, IReadOnlyList<KeyValuePair<string, bool>> sessions)
        {
            if (sessions == null || sessions.Count == 0) return null;

            bool shownExists = shownId != null && sessions.Any(s => s.Key == shownId);
            string shown = shownExists
                ? shownId
                : currentId != null && sessions.Any(s => s.Key == currentId) ? currentId : sessions[0].Key;

            if (sessions.Any(s => s.Key == shown && s.Value)) return shown;
            if (currentId != null && sessions.Any(s => s.Key == currentId && s.Value)) return currentId;

            foreach (KeyValuePair<string, bool> session in sessions)
            {
                if (session.Value) return session.Key;
            }
            return shown;
        }
    }

    /// <summary>Finds the app behind the id it gives Windows when it plays, among the exe paths of those making sound.</summary>
    public static class AppMatcher
    {
        /// <summary>The first exe that fits, or null. Examples of ids: Spotify.exe, Chrome, Microsoft.ZuneMusic_8wekyb3d8bbwe!App.</summary>
        public static string Find(string appModelId, IEnumerable<string> exePaths)
        {
            if (string.IsNullOrWhiteSpace(appModelId) || exePaths == null) return null;
            return exePaths.FirstOrDefault(path => Matches(appModelId, path));
        }

        public static bool Matches(string appModelId, string exePath)
        {
            if (string.IsNullOrWhiteSpace(appModelId) || string.IsNullOrWhiteSpace(exePath)) return false;

            string id = appModelId.Trim();
            string path = exePath.Replace('/', '\\');

            string package = PackageName(id);
            if (package != null)
            {
                // Packaged apps live in a folder named package_version_..., so the part with the underscore is what counts
                return path.IndexOf("\\" + package + "_", StringComparison.OrdinalIgnoreCase) >= 0;
            }

            string exe = StripExe(LastPart(path));
            string name = StripExe(LastPart(id));
            if (string.Equals(name, exe, StringComparison.OrdinalIgnoreCase)) return true;

            // Apps installed by Squirrel call themselves com.squirrel.TIDAL.TIDAL
            int dot = name.LastIndexOf('.');
            return dot >= 0 && string.Equals(name.Substring(dot + 1), exe, StringComparison.OrdinalIgnoreCase);
        }

        private static string PackageName(string id)
        {
            int bang = id.IndexOf('!');
            int underscore = id.IndexOf('_');
            if (bang <= 0 || underscore <= 0 || underscore > bang) return null;
            return id.Substring(0, underscore);
        }

        private static string LastPart(string text)
        {
            int slash = text.LastIndexOf('\\');
            return slash >= 0 ? text.Substring(slash + 1) : text;
        }

        private static string StripExe(string name)
        {
            return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name.Substring(0, name.Length - 4) : name;
        }
    }
}
