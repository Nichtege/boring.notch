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
        GraphTests();
        MusicTests();

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

            string real = Path.Combine(dir, "echt.txt");
            File.WriteAllText(real, "x");
            Check("a file that's there stays", ShelfStore.StillThereOrUnknown(real));
            Check("a folder that's there stays", ShelfStore.StillThereOrUnknown(dir));
            Check("a file deleted on a disk that's there goes", !ShelfStore.StillThereOrUnknown(Path.Combine(dir, "weg.txt")));
            if (Path.DirectorySeparatorChar == '\\')
            {
                // Only Windows has these. The workflow runs this there too.
                Check("a file on a drive that's unplugged stays", ShelfStore.StillThereOrUnknown(@"Q:\weg\datei.txt"));
                Check("a file on a share stays, unasked", ShelfStore.StillThereOrUnknown(@"\\gibtsnicht\freigabe\datei.txt"));
            }

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

    private static void MusicTests()
    {
        Same("under an hour", "1:05", PlaybackMath.TimeText(65.9));
        Same("zero", "0:00", PlaybackMath.TimeText(0));
        Same("from an hour on", "1:02:03", PlaybackMath.TimeText(3723));
        Same("negative isn't shown", "0:00", PlaybackMath.TimeText(-5));
        Same("not a number isn't shown", "0:00", PlaybackMath.TimeText(double.NaN));

        var at = new DateTime(2026, 11, 1, 12, 0, 0, DateTimeKind.Utc);
        Same("playing runs on", 15.0, PlaybackMath.Estimated(10, 100, true, 1, at, at.AddSeconds(5)));
        Same("at double speed", 20.0, PlaybackMath.Estimated(10, 100, true, 2, at, at.AddSeconds(5)));
        Same("paused stands still", 10.0, PlaybackMath.Estimated(10, 100, false, 1, at, at.AddSeconds(5)));
        Same("not past the end", 100.0, PlaybackMath.Estimated(90, 100, true, 1, at, at.AddHours(1)));
        Same("paused neither", 100.0, PlaybackMath.Estimated(120, 100, false, 1, at, at));
        Same("not before the start", 0.0, PlaybackMath.Estimated(0, 100, true, 1, at, at.AddSeconds(-5)));

        Rgb bright = ColorMath.Average(new byte[] { 200, 100, 50, 255, 100, 200, 150, 255 });
        Same("the middle of blue", 150, (int)bright.B);
        Same("of green", 150, (int)bright.G);
        Same("of red", 100, (int)bright.R);
        Rgb black = ColorMath.Average(new byte[] { 0, 0, 0, 255 });
        Same("near black becomes gray", 128, (int)black.R);
        Same("all the way", (int)black.R, (int)black.B);
        // 0.2, 0.1, 0.1 lifted to a brightness of 0.5: the hue stays and the color gets paler
        Rgb dark = ColorMath.Average(new byte[] { 26, 26, 51, 255 });
        Same("dark red is lifted to the minimum", 128, (int)dark.R);
        Check("and stays red, " + dark.R + " over " + dark.G, dark.R > dark.G && dark.G == dark.B);
        Same("no picture is white", 255, (int)ColorMath.Average(new byte[0]).R);

        Rgb scaled = ColorMath.EnsureMinimumBrightness(new Rgb(255, 255, 255), 0.6);
        Same("white comes down to the level asked for", 153, (int)scaled.G);
        Rgb none = ColorMath.EnsureMinimumBrightness(new Rgb(0, 0, 0), 0.6);
        Same("black can't divide by zero", 153, (int)none.R);
        Same("a factor out of bounds changes nothing", 10, (int)ColorMath.EnsureMinimumBrightness(new Rgb(10, 20, 30), 2).R);

        KeyValuePair<string, bool> S(string id, bool playing) => new KeyValuePair<string, bool>(id, playing);
        Same("nothing there", null, SessionChoice.Pick("a", "a", new KeyValuePair<string, bool>[0]));
        Same("first the current one", "b", SessionChoice.Pick(null, "b", new[] { S("a", false), S("b", false) }));
        Same("what's shown and plays stays", "a", SessionChoice.Pick("a", "b", new[] { S("a", true), S("b", true) }));
        Same("something playing takes over", "b", SessionChoice.Pick("a", "a", new[] { S("a", false), S("b", true) }));
        Same("paused with nothing else stays", "a", SessionChoice.Pick("a", "b", new[] { S("a", false), S("b", false) }));
        Same("gone falls to the current one", "b", SessionChoice.Pick("x", "b", new[] { S("a", false), S("b", false) }));
        Same("gone without a current one", "a", SessionChoice.Pick("x", null, new[] { S("a", false), S("b", false) }));
        Same("the current one first if several play", "c", SessionChoice.Pick("a", "c", new[] { S("a", false), S("b", true), S("c", true) }));

        var exes = new[]
        {
            @"c:\program files\google\chrome\application\chrome.exe",
            @"c:\users\a\appdata\roaming\spotify\spotify.exe",
            @"c:\program files\windowsapps\microsoft.zunemusic_11.2_x64__8wekyb3d8bbwe\microsoft.media.player.exe",
            @"c:\windows\system32\msedge.exe",
        };
        Same("an exe name", exes[1], AppMatcher.Find("Spotify.exe", exes));
        Same("a name alone", exes[0], AppMatcher.Find("Chrome", exes));
        Same("whatever the case", exes[3], AppMatcher.Find("MSEdge", exes));
        Same("a packaged app", exes[2], AppMatcher.Find("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic", exes));
        Same("a full path", exes[0], AppMatcher.Find(@"C:\Program Files\Google\Chrome\Application\chrome.exe", exes));
        Same("a hash fits nothing", null, AppMatcher.Find("308046B0AF4A39CB", exes));
        Same("a package that isn't there", null, AppMatcher.Find("SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify", exes));
        Same("nothing fits nothing", null, AppMatcher.Find("", exes));
        Check("a name inside a longer one is no match", !AppMatcher.Matches("Chrome", @"c:\x\chromedriver.exe"));

        SpectrumTests();
    }

    private static byte[] Bytes(float[] samples)
    {
        var bytes = new byte[samples.Length * sizeof(float)];
        Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    /// <summary>A steady noise with a tone pulsing on top of it, as each bar measures against its own recent range.</summary>
    private static double[] HighestLevels(double toneHertz, int channels)
    {
        const int rate = 48000;
        const int block = 480;
        var bands = new SpectrumBands(rate);
        var random = new Random(7);
        var highest = new double[SpectrumBands.BandCount];
        for (int b = 0; b < 400; b++)
        {
            bool isOn = b / 20 % 2 == 1;
            var samples = new float[block * channels];
            for (int i = 0; i < block; i++)
            {
                double time = (b * block + i) / (double)rate;
                double noise = (random.NextDouble() - 0.5) * 0.002;
                double tone = isOn ? 0.5 * Math.Sin(2 * Math.PI * toneHertz * time) : 0;
                for (int channel = 0; channel < channels; channel++)
                {
                    samples[i * channels + channel] = (float)(noise + tone);
                }
            }
            double[] levels = bands.Feed(Bytes(samples), samples.Length * sizeof(float), channels);
            if (levels == null) continue;
            for (int band = 0; band < levels.Length; band++)
            {
                Check("a level stays between 0 and 1, was " + levels[band], levels[band] >= 0 && levels[band] <= 1);
                highest[band] = Math.Max(highest[band], levels[band]);
            }
        }
        return highest;
    }

    private static void SpectrumTests()
    {
        double[] low = HighestLevels(120, 2);
        Same("four bars", 4, low.Length);
        Check("a low tone lifts the first bar most: " + string.Join(", ", low), low[0] > 0.5 && low[0] > low[2] && low[0] > low[3]);

        double[] high = HighestLevels(8000, 1);
        Check("a high tone lifts the last bar most: " + string.Join(", ", high), high[3] > 0.5 && high[3] > high[0] && high[3] > high[1]);

        double[] middle = HighestLevels(2000, 2);
        Check("a middle tone doesn't lift the first bar most: " + string.Join(", ", middle), middle[2] > middle[0]);

        var silent = new SpectrumBands(48000);
        double[] during = null;
        for (int b = 0; b < 100; b++)
        {
            during = silent.Feed(new byte[960 * sizeof(float)], 960 * sizeof(float), 2) ?? during;
        }
        Same("silence says nothing", null, during);
        Check("and the bars are at 0", silent.Levels.All(level => level == 0));

        var bad = new SpectrumBands(48000);
        var broken = new float[4800];
        for (int i = 0; i < broken.Length; i++) broken[i] = i % 2 == 0 ? float.NaN : float.PositiveInfinity;
        double[] fromBroken = null;
        for (int b = 0; b < 3; b++) fromBroken = bad.Feed(Bytes(broken), broken.Length * sizeof(float), 2) ?? fromBroken;
        Check("broken samples can't break the levels", fromBroken == null || fromBroken.All(level => level >= 0 && level <= 1));

        Same("no buffer", null, new SpectrumBands(48000).Feed(null, 0, 2));
        Same("no channels", null, new SpectrumBands(48000).Feed(new byte[8], 8, 0));
        Same("half a sample isn't read past the end", null, new SpectrumBands(48000).Feed(new byte[3], 3, 1));
    }

    /// <summary>Each bar measures against its own recent range, so a song moves them and a steady tone doesn't.</summary>
    private static void GraphTests()
    {
        const string tidal = @"C:\Users\A\AppData\Local\TIDAL\app-2.40.0\TIDAL.exe";
        const string storeTidal = @"C:\Program Files\WindowsApps\WiMPMusic.27241E05630EA_2.40.0.0_x64__kn85bz84x7te4\app\TIDAL.exe";
        Check("TIDAL by its exe", AppMatcher.Matches("TIDAL.exe", tidal));
        Check("TIDAL by its name", AppMatcher.Matches("TIDAL", tidal));
        Check("TIDAL as Squirrel installs it", AppMatcher.Matches("com.squirrel.TIDAL.TIDAL", tidal));
        Check("TIDAL from the Store", AppMatcher.Matches("WiMPMusic.27241E05630EA_kn85bz84x7te4!TIDAL", storeTidal));
        Check("another app isn't TIDAL", !AppMatcher.Matches("Spotify.exe", tidal));
        Check("nor is one from Squirrel", !AppMatcher.Matches("com.squirrel.Discord.Discord", tidal));
        Check("nor one from another package", !AppMatcher.Matches("SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify", storeTidal));
        Same("the right one of several", tidal, AppMatcher.Find("com.squirrel.TIDAL.TIDAL", new[] { @"C:\x\chrome.exe", tidal }));

        double Range(Func<int, double> signal)
        {
            const int rate = 48000;
            var bands = new SpectrumBands(rate);
            var buffer = new byte[480 * 4];
            double lowest = 1, highest = 0;
            for (int block = 0; block < 400; block++)
            {
                for (int i = 0; i < 480; i++)
                {
                    BitConverter.GetBytes((float)signal(block * 480 + i)).CopyTo(buffer, i * 4);
                }
                double[] levels = bands.Feed(buffer, buffer.Length, 1);
                if (levels != null && block > 100)
                {
                    lowest = Math.Min(lowest, levels[0]);
                    highest = Math.Max(highest, levels[0]);
                }
            }
            return highest - lowest;
        }

        double steady = Range(i => 0.3 * Math.Sin(2 * Math.PI * 110 * i / 48000));
        double beat = Range(i => 0.5 * Math.Exp(-(i % 24000) / 3000.0) * Math.Sin(2 * Math.PI * 110 * i / 48000));
        Check("a steady tone leaves the bar still, moved " + steady, steady < 0.05);
        Check("a beat moves the bar through most of its height, moved " + beat, beat > 0.6);
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
