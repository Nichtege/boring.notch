using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace BoringNotch.Core
{
    public enum ResultKind
    {
        App,
        Setting,
        File,
        ExplorerSearch,
        WebSearch,
    }

    public sealed class SearchResult
    {
        public ResultKind Kind;
        public string Title;
        public string Subtitle;
        /// <summary>What gets opened: a path, a settings page, a shell:AppsFolder entry or an address.</summary>
        public string Target;

        public string Key => Kind + "|" + Target;
    }

    public sealed class AppEntry
    {
        public string Name;
        public string Target;
    }

    public sealed class SettingEntry
    {
        public string Title;
        public string Uri;
        public string Keywords;

        public SettingEntry(string title, string uri, string keywords)
        {
            Title = title;
            Uri = uri;
            Keywords = keywords;
        }
    }

    public static class SearchRank
    {
        private const int WholeName = 100;
        private const int Start = 80;
        private const int WordStart = 60;
        private const int Inside = 40;

        public static string Normalize(string text)
        {
            var result = new StringBuilder(text.Length);
            foreach (char c in text.Normalize(NormalizationForm.FormD))
            {
                if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
                {
                    result.Append(char.ToLowerInvariant(c));
                }
            }
            return result.ToString();
        }

        public static string[] Tokens(string query)
        {
            return (query ?? "").Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        }

        /// <summary>How well a name fits, -1 if not every word of the query is in it.</summary>
        public static int Score(string name, string query)
        {
            string[] tokens = Tokens(query);
            if (tokens.Length == 0 || string.IsNullOrEmpty(name)) return -1;

            string normalized = Normalize(name);
            int score = int.MaxValue;
            foreach (string raw in tokens)
            {
                string token = Normalize(raw);
                int index = normalized.IndexOf(token, StringComparison.Ordinal);
                if (index < 0) return -1;

                int tokenScore;
                if (normalized == token) tokenScore = WholeName;
                else if (index == 0) tokenScore = Start;
                else if (HasWordStart(normalized, token)) tokenScore = WordStart;
                else tokenScore = Inside;
                score = Math.Min(score, tokenScore);
            }
            return score;
        }

        private static bool HasWordStart(string text, string token)
        {
            int index = text.IndexOf(token, StringComparison.Ordinal);
            while (index >= 0)
            {
                if (index == 0 || !char.IsLetterOrDigit(text[index - 1])) return true;
                index = text.IndexOf(token, index + 1, StringComparison.Ordinal);
            }
            return false;
        }

        public static List<AppEntry> Apps(IEnumerable<AppEntry> apps, string query, int limit)
        {
            return apps
                .Select(app => new { app, score = Score(app.Name, query) })
                .Where(x => x.score >= 0)
                .OrderByDescending(x => x.score)
                .ThenBy(x => x.app.Name.Length)
                .ThenBy(x => x.app.Name, StringComparer.OrdinalIgnoreCase)
                .Take(limit)
                .Select(x => x.app)
                .ToList();
        }

        public static List<SettingEntry> Settings(IEnumerable<SettingEntry> settings, string query, int limit)
        {
            return settings
                .Select(s => new { s, score = Math.Max(Score(s.Title, query), Score(s.Keywords, query) - 1) })
                .Where(x => x.score >= 0)
                .OrderByDescending(x => x.score)
                .ThenBy(x => x.s.Title.Length)
                .Take(limit)
                .Select(x => x.s)
                .ToList();
        }

        /// <summary>Entries of the Start menu nobody means to find.</summary>
        public static bool IsNoise(string appName)
        {
            string name = Normalize(appName ?? "");
            return name.Length == 0
                || name.Contains("uninstall")
                || name.Contains("deinstall")
                || name.Contains("readme")
                || name.Contains("liesmich");
        }
    }

    public static class FileQuery
    {
        /// <summary>
        /// The question for the Windows Search index. What was typed only ever goes in as text to compare with.
        /// Null if there's nothing to look for.
        /// </summary>
        public static string Build(string query, int top)
        {
            string[] tokens = SearchRank.Tokens(query).Select(Escape).Where(t => t.Length > 0).ToArray();
            if (tokens.Length == 0) return null;

            string names = string.Join(" AND ", tokens.Select(t => "System.FileName LIKE '%" + t + "%'"));
            return "SELECT TOP " + top + " System.ItemPathDisplay FROM SystemIndex "
                + "WHERE SCOPE='file:' AND " + names + " ORDER BY System.DateModified DESC";
        }

        private static string Escape(string token)
        {
            var result = new StringBuilder(token.Length);
            foreach (char c in token)
            {
                if (char.IsControl(c)) continue;
                switch (c)
                {
                    case '\'': result.Append("''"); break;
                    case '[': result.Append("[[]"); break;
                    case '%': result.Append("[%]"); break;
                    case '_': result.Append("[_]"); break;
                    default: result.Append(c); break;
                }
            }
            return result.ToString();
        }
    }

    public static class SearchResults
    {
        public const int MaxRows = 8;
        private const int MaxApps = 4;
        private const int MaxSettings = 2;
        private const int FallbackRows = 2;

        /// <summary>Apps first, then settings, then files, and the two ways to search on at the end.</summary>
        public static List<SearchResult> Combine(
            string query,
            IEnumerable<AppEntry> apps,
            IEnumerable<SettingEntry> settings,
            IEnumerable<string> files)
        {
            var rows = new List<SearchResult>();
            string trimmed = (query ?? "").Trim();
            if (trimmed.Length == 0) return rows;

            foreach (AppEntry app in SearchRank.Apps(apps, trimmed, MaxApps))
            {
                rows.Add(new SearchResult { Kind = ResultKind.App, Title = app.Name, Subtitle = "App", Target = app.Target });
            }
            foreach (SettingEntry setting in SearchRank.Settings(settings, trimmed, MaxSettings))
            {
                rows.Add(new SearchResult { Kind = ResultKind.Setting, Title = setting.Title, Subtitle = "Einstellungen", Target = setting.Uri });
            }

            int room = MaxRows - FallbackRows - rows.Count;
            foreach (string file in files.Take(Math.Max(0, room)))
            {
                rows.Add(new SearchResult
                {
                    Kind = ResultKind.File,
                    Title = System.IO.Path.GetFileName(file),
                    Subtitle = System.IO.Path.GetDirectoryName(file) ?? "",
                    Target = file,
                });
            }

            string encoded = Uri.EscapeDataString(trimmed);
            rows.Add(new SearchResult
            {
                Kind = ResultKind.ExplorerSearch,
                Title = "„" + trimmed + "“ im Explorer suchen",
                Subtitle = "Alle Dateien im Suchindex",
                Target = "search-ms:query=" + encoded,
            });
            rows.Add(new SearchResult
            {
                Kind = ResultKind.WebSearch,
                Title = "„" + trimmed + "“ im Web suchen",
                Subtitle = "Öffnet den Browser",
                Target = "https://www.google.com/search?q=" + encoded,
            });
            return rows;
        }
    }

    public static class SettingsCatalog
    {
        public static readonly IReadOnlyList<SettingEntry> All = new[]
        {
            new SettingEntry("Bluetooth und Geräte", "ms-settings:bluetooth", "bluetooth geräte kopfhörer airpods devices"),
            new SettingEntry("WLAN", "ms-settings:network-wifi", "wlan wifi internet netzwerk"),
            new SettingEntry("Netzwerk und Internet", "ms-settings:network-status", "netzwerk internet ethernet lan network"),
            new SettingEntry("VPN", "ms-settings:network-vpn", "vpn"),
            new SettingEntry("Sound", "ms-settings:sound", "sound ton audio lautstärke lautsprecher mikrofon volume"),
            new SettingEntry("Bildschirm", "ms-settings:display", "bildschirm display monitor auflösung helligkeit skalierung resolution"),
            new SettingEntry("Nachtmodus", "ms-settings:nightlight", "nachtmodus nachtlicht blaulicht night light"),
            new SettingEntry("Benachrichtigungen", "ms-settings:notifications", "benachrichtigungen mitteilungen notifications"),
            new SettingEntry("Nicht stören", "ms-settings:quiethours", "nicht stören fokus focus benachrichtigungen"),
            new SettingEntry("Strom und Akku", "ms-settings:powersleep", "strom akku energie energiesparen ruhezustand power battery sleep"),
            new SettingEntry("Speicher", "ms-settings:storagesense", "speicher festplatte speicherplatz storage disk"),
            new SettingEntry("Installierte Apps", "ms-settings:appsfeatures", "apps programme installiert deinstallieren entfernen uninstall"),
            new SettingEntry("Standard-Apps", "ms-settings:defaultapps", "standard apps browser default"),
            new SettingEntry("Autostart", "ms-settings:startupapps", "autostart start startup"),
            new SettingEntry("Windows Update", "ms-settings:windowsupdate", "update aktualisierung windows"),
            new SettingEntry("Hintergrund", "ms-settings:personalization-background", "hintergrund hintergrundbild wallpaper personalisierung"),
            new SettingEntry("Farben", "ms-settings:colors", "farben dunkel hell dark mode akzent theme"),
            new SettingEntry("Taskleiste", "ms-settings:taskbar", "taskleiste taskbar"),
            new SettingEntry("Maus", "ms-settings:mousetouchpad", "maus zeiger mouse"),
            new SettingEntry("Touchpad", "ms-settings:devices-touchpad", "touchpad trackpad gesten"),
            new SettingEntry("Drucker und Scanner", "ms-settings:printers", "drucker scanner printer"),
            new SettingEntry("Konto", "ms-settings:yourinfo", "konto account profil microsoft"),
            new SettingEntry("Anmeldeoptionen", "ms-settings:signinoptions", "anmeldung passwort pin hello sign in"),
            new SettingEntry("Datum und Uhrzeit", "ms-settings:dateandtime", "datum uhrzeit zeit time date"),
            new SettingEntry("Sprache und Region", "ms-settings:regionlanguage", "sprache region tastatur language"),
            new SettingEntry("Datenschutz", "ms-settings:privacy", "datenschutz privatsphäre kamera mikrofon privacy"),
            new SettingEntry("Info über diesen PC", "ms-settings:about", "info pc name version about system"),
        };
    }
}
