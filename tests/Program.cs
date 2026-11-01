// What can be checked without Windows: the logic behind the notch. Run with `dotnet run --project tests`.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using BoringNotch.Core;

internal static class Tests
{
    private static int _passed;
    private static readonly List<string> Failed = new List<string>();

    private static void Check(string name, bool condition)
    {
        if (condition) _passed++;
        else Failed.Add(name);
    }

    private static void Same(string name, object expected, object actual)
    {
        Check(name + " (wanted " + expected + ", got " + actual + ")", Equals(expected, actual));
    }

    private static int Main()
    {
        SpringTests();
        HoverTests();
        ClockTests();
        ShelfTests();
        SearchTests();

        Console.WriteLine(_passed + " passed, " + Failed.Count + " failed");
        foreach (string failure in Failed) Console.WriteLine("FAILED: " + failure);
        return Failed.Count == 0 ? 0 : 1;
    }

    private static void SpringTests()
    {
        var open = new Spring(32);
        open.Configure(0.42, 0.8);
        open.SetTarget(190);
        double highest = 32;
        double seconds = 0;
        while (!open.IsSettled && seconds < 5)
        {
            open.Step(1.0 / 60);
            seconds += 1.0 / 60;
            highest = Math.Max(highest, open.Value);
        }
        Check("the open spring comes to rest", open.IsSettled);
        Same("the open spring ends on its target", 190.0, open.Value);
        Check("the open spring overshoots a little", highest > 190 && highest < 190 + 158 * 0.1);
        Check("the open spring rests within a second and a half, took " + seconds, seconds < 1.5);

        var close = new Spring(190);
        close.Configure(0.45, 1.0);
        close.SetTarget(32);
        double lowest = 190;
        for (int i = 0; i < 300 && !close.IsSettled; i++)
        {
            close.Step(1.0 / 60);
            lowest = Math.Min(lowest, close.Value);
        }
        Check("the close spring comes to rest", close.IsSettled);
        Check("the close spring doesn't overshoot", lowest >= 32 - 0.05);

        var slept = new Spring(0);
        slept.SetTarget(100);
        slept.Step(3600);
        Check("an hour-long frame doesn't blow the spring up", slept.Value >= 0 && slept.Value <= 100);

        var still = new Spring(5);
        still.Step(1);
        Same("a spring at rest stays", 5.0, still.Value);
    }

    private static void HoverTests()
    {
        var m = new HoverMachine();
        Same("not yet open at 0 s", HoverAction.None, m.Update(10, true, false, false, true));
        Same("not yet open at 0.29 s", HoverAction.None, m.Update(10.29, true, false, false, true));
        Same("open at 0.3 s", HoverAction.Open, m.Update(10.3, true, false, false, true));

        Same("stays open with the mouse on it", HoverAction.None, m.Update(11, true, true, false, true));
        Same("not closed right when leaving", HoverAction.None, m.Update(12, false, true, false, true));
        Same("not closed at 0.09 s", HoverAction.None, m.Update(12.09, false, true, false, true));
        Same("closed at 0.1 s", HoverAction.Close, m.Update(12.101, false, true, false, true));

        m = new HoverMachine();
        m.Update(0, true, false, false, true);
        m.Update(0.2, false, false, false, true);
        Same("passing over it doesn't count", HoverAction.None, m.Update(0.31, true, false, false, true));

        m = new HoverMachine();
        m.Update(0, false, true, true, true);
        Same("a held notch stays open", HoverAction.None, m.Update(5, false, true, true, true));
        Same("let go, the delay starts over", HoverAction.None, m.Update(5.05, false, true, false, true));
        Same("let go, it closes after the delay", HoverAction.Close, m.Update(5.15, false, true, false, true));

        m = new HoverMachine();
        m.MustLeaveFirst();
        Same("closed by the app, the mouse on it doesn't reopen it", HoverAction.None, m.Update(0, true, false, false, true));
        Same("still not after a while", HoverAction.None, m.Update(1, true, false, false, true));
        m.Update(1.1, false, false, false, true);
        m.Update(1.2, true, false, false, true);
        Same("once it left and came back it opens", HoverAction.Open, m.Update(1.5, true, false, false, true));

        m = new HoverMachine();
        Same("a hidden notch doesn't start", HoverAction.None, m.Update(0, true, false, false, false));
        Same("a hidden notch doesn't open", HoverAction.None, m.Update(1, true, false, false, false));
    }

    private static void ClockTests()
    {
        var start = new DateTime(2026, 11, 1, 12, 0, 0, DateTimeKind.Utc);
        var c = new FocusClock();
        Check("idle at first", !c.IsRunning);
        Same("idle clock", "0:00", c.ClockText(start));
        Same("idle progress", 0.0, c.Progress(start));

        c.Start(start, 25 * 60);
        Check("running", c.IsRunning);
        Same("25 minutes", "25:00", c.ClockText(start));
        Same("25 minutes short", "25m", c.ShortText(start));
        Same("a second later", "24:59", c.ClockText(start.AddSeconds(1)));
        Same("half a second rounds up", "25:00", c.ClockText(start.AddSeconds(0.5)));
        Same("61 s left is 2m", "2m", c.ShortText(start.AddSeconds(25 * 60 - 61)));
        Same("60 s left is seconds", "60s", c.ShortText(start.AddSeconds(25 * 60 - 60)));
        Same("45 s left", "45s", c.ShortText(start.AddSeconds(25 * 60 - 45)));
        Same("halfway", 0.5, c.Progress(start.AddSeconds(12.5 * 60)));
        Check("not over before its time", !c.Tick(start.AddSeconds(25 * 60 - 1)));
        Check("over at its time", c.Tick(start.AddSeconds(25 * 60)));
        Check("over only once", !c.Tick(start.AddSeconds(25 * 60 + 1)));
        Check("not running after", !c.IsRunning);

        c.Start(start, 60);
        Check("a PC that slept through the end finishes on waking", c.Tick(start.AddHours(8)));

        c.Start(start, 60);
        c.Stop();
        Check("stopped never finishes", !c.Tick(start.AddHours(1)));
        Same("60 minutes", "60:00", new Func<string>(() => { var x = new FocusClock(); x.Start(start, 3600); return x.ClockText(start); })());
    }

    private static void ShelfTests()
    {
        string dir = Path.Combine(Path.GetTempPath(), "notch-tests-" + Guid.NewGuid().ToString("N"));
        string file = Path.Combine(dir, "unter", "ablage.txt");
        var gone = new HashSet<string>();
        Func<string, bool> exists = p => !gone.Contains(p);
        try
        {
            var s = new ShelfStore(file, exists);
            s.Load();
            Check("empty without a file", s.IsEmpty);
            Check("adds", s.Add(@"C:\Users\A\Übung ä.pdf"));
            Check("adds a second", s.Add(@"C:\Users\A\Ordner"));
            Check("the same again isn't added", !s.Add(@"c:\users\a\ÜBUNG Ä.PDF") || s.Paths.Count == 2);
            Check("nothing isn't added", !s.Add("  "));
            Same("two on it", 2, s.Paths.Count);

            var again = new ShelfStore(file, exists);
            again.Load();
            Same("kept over a restart", 2, again.Paths.Count);
            Same("in order, with umlauts", @"C:\Users\A\Übung ä.pdf", again.Paths[0]);
            Check("no temporary file left", !File.Exists(file + ".neu"));

            gone.Add(@"C:\Users\A\Ordner");
            Check("a file that's gone comes off", again.CleanupMissing());
            Same("one left", 1, again.Paths.Count);
            Check("nothing more to clean", !again.CleanupMissing());

            again.Remove(@"C:\USERS\A\Übung ä.pdf");
            Check("removes whatever the case", again.Paths.All(p => !p.StartsWith(@"C:\Users\A\Ü")) || again.IsEmpty);

            File.WriteAllText(file, "\n  \r\nC:\\a.txt\nC:\\a.txt\n\n");
            var messy = new ShelfStore(file, exists);
            messy.Load();
            Same("empty lines and doubles are ignored", 1, messy.Paths.Count);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }
    }

    private static void SearchTests()
    {
        Same("whole name", 100, SearchRank.Score("Chrome", "chrome"));
        Same("start", 80, SearchRank.Score("Google Chrome", "goo"));
        Same("word start", 60, SearchRank.Score("Google Chrome", "chr"));
        Same("inside", 40, SearchRank.Score("Google Chrome", "rom"));
        Same("no match", -1, SearchRank.Score("Google Chrome", "edge"));
        Same("every word has to be there", -1, SearchRank.Score("Google Chrome", "google edge"));
        Same("words in any order", 60, SearchRank.Score("Google Chrome", "chrome google"));
        Same("nothing typed", -1, SearchRank.Score("Chrome", "   "));
        Check("umlauts match without them", SearchRank.Score("Geräte-Manager", "gerate") >= 0);
        Check("and with them", SearchRank.Score("Geraete", "geraete") >= 0);
        Same("a word start later in the name still counts", 60, SearchRank.Score("Rom Chrome", "chr"));

        var apps = new[]
        {
            new AppEntry { Name = "Paint", Target = "p" },
            new AppEntry { Name = "Paint 3D", Target = "p3" },
            new AppEntry { Name = "Snipping Tool", Target = "s" },
            new AppEntry { Name = "MS Paint Helper", Target = "h" },
            new AppEntry { Name = "Repaint", Target = "r" },
        };
        var ranked = SearchRank.Apps(apps, "paint", 10);
        Same("the exact name first", "Paint", ranked[0].Name);
        Same("then what starts with it", "Paint 3D", ranked[1].Name);
        Same("then a word start", "MS Paint Helper", ranked[2].Name);
        Same("then inside a word", "Repaint", ranked[3].Name);
        Same("what doesn't fit is out", 4, ranked.Count);

        var settings = SearchRank.Settings(SettingsCatalog.All, "wlan", 2);
        Same("wlan finds its page", "ms-settings:network-wifi", settings[0].Uri);
        Same("a keyword finds a page", "ms-settings:sound", SearchRank.Settings(SettingsCatalog.All, "lautstärke", 2)[0].Uri);
        Same("english too", "ms-settings:bluetooth", SearchRank.Settings(SettingsCatalog.All, "airpods", 2)[0].Uri);
        Check("every page is a settings address", SettingsCatalog.All.All(s => s.Uri.StartsWith("ms-settings:")));
        Same("no address twice", SettingsCatalog.All.Count, SettingsCatalog.All.Select(s => s.Uri).Distinct().Count());

        Check("an uninstaller is noise", SearchRank.IsNoise("Uninstall Foo"));
        Check("in German too", SearchRank.IsNoise("Foo deinstallieren"));
        Check("a real app isn't", !SearchRank.IsNoise("Notepad++"));
        Check("no name is noise", SearchRank.IsNoise(""));

        Same("nothing to look for", null, FileQuery.Build("   ", 8));
        string simple = FileQuery.Build("bericht", 6);
        Check("asks for the name", simple.Contains("System.FileName LIKE '%bericht%'"));
        Check("only files", simple.Contains("SCOPE='file:'"));
        Check("asks for the real path, not the translated one", simple.Contains("System.ItemUrl") && !simple.Contains("ItemPathDisplay"));
        Same("a path from the index", @"C:\Users\A\Übung 100%.txt", FileQuery.PathFromUrl("file:C:/Users/A/Übung 100%.txt"));
        Same("with slashes after the scheme", @"C:\a.txt", FileQuery.PathFromUrl("file:///C:/a.txt"));
        Same("a # stays in the name", @"C:\a#1.txt", FileQuery.PathFromUrl("file:C:/a#1.txt"));
        Same("%41 isn't decoded", @"C:\%41.txt", FileQuery.PathFromUrl("file:C:/%41.txt"));
        Same("a network share", @"\\server\share\a.txt", FileQuery.PathFromUrl("file://server/share/a.txt"));
        Same("mail isn't a file", null, FileQuery.PathFromUrl("mapi15://x/y"));
        Same("nothing is nothing", null, FileQuery.PathFromUrl(null));
        Same("only the scheme", null, FileQuery.PathFromUrl("file:"));
        Check("the limit", simple.StartsWith("SELECT TOP 6 "));
        string two = FileQuery.Build("foo bar", 6);
        Check("both words", two.Contains("LIKE '%foo%' AND System.FileName LIKE '%bar%'"));

        string hostile = FileQuery.Build("x' OR 1=1 --", 6);
        int quotes = hostile.Count(c => c == '\'');
        Check("a quote stays text", hostile.Contains("x''"));
        Same("every quote is paired", 0, quotes % 2);
        Check("the OR stays inside a compared string", hostile.Contains("LIKE '%OR%'"));
        Check("wildcards stay text", FileQuery.Build("100%_a[b", 6).Contains("100[%][_]a[[]b"));
        Check("control characters go", !FileQuery.Build("a\u0001b", 6).Contains("\u0001"));

        var none = new string[0];
        Same("nothing typed, no rows", 0, SearchResults.Combine("  ", apps, SettingsCatalog.All, none).Count);

        var fallback = SearchResults.Combine("zzzz", apps, SettingsCatalog.All, none);
        Same("always two ways on", 2, fallback.Count);
        Same("Explorer first", ResultKind.ExplorerSearch, fallback[0].Kind);
        Same("the web last", ResultKind.WebSearch, fallback[1].Kind);

        var encoded = SearchResults.Combine("a b&c", apps, SettingsCatalog.All, none);
        Same("Explorer's query is encoded", "search-ms:query=a%20b%26c&", encoded[0].Target);
        Same("the web's too", "https://www.google.com/search?q=a%20b%26c", encoded[1].Target);

        var files = Enumerable.Range(0, 20).Select(i => @"C:\docs\paint" + i + ".txt").ToArray();
        var full = SearchResults.Combine("paint", apps, SettingsCatalog.All, files);
        Same("never more than fits", SearchResults.MaxRows, full.Count);
        Same("apps first", ResultKind.App, full[0].Kind);
        Same("the ways on last", ResultKind.WebSearch, full[full.Count - 1].Kind);
        Same("a key per row", full.Count, full.Select(r => r.Key).Distinct().Count());
    }
}
