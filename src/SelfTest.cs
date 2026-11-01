using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using BoringNotch.Core;

namespace BoringNotch
{
    /// <summary>
    /// `BoringNotch.exe --selftest <folder>` goes through everything once on a real Windows and writes pictures and a
    /// report there. Nothing outside that folder is changed, and no app or file gets opened.
    /// </summary>
    internal static class SelfTest
    {
        public static async Task<int> Run(string folder, NotchWindow notch, SearchWindow search, ShelfStore shelf, AudioMixer mixer, MediaSessions media, AudioLevels levels)
        {
            var report = new StringBuilder();
            int failures = 0;
            Directory.CreateDirectory(folder);
            notch.IgnoresMouse = true;

            async Task Step(string name, Func<Task> action)
            {
                try
                {
                    await action();
                    report.AppendLine("ok    " + name);
                }
                catch (Exception e)
                {
                    failures++;
                    report.AppendLine("FAIL  " + name + ": " + e);
                }
            }

            async Task Picture(FrameworkElement element, string name)
            {
                await Settle();
                Save(element, Path.Combine(folder, name + ".png"));
            }

            await Step("closed", () => Picture(notch.Root, "1-geschlossen"));

            await Step("shelf empty", async () =>
            {
                notch.ShowTab(NotchTab.Shelf);
                notch.Open();
                notch.SettleForTest();
                await Picture(notch.Root, "2-ablage-leer");
            });

            await Step("shelf with files", async () =>
            {
                string a = Path.Combine(folder, "Beispiel Dokument mit langem Namen.txt");
                string b = Path.Combine(folder, "Übung.txt");
                File.WriteAllText(a, "Boring Notch");
                File.WriteAllText(b, "Boring Notch");
                shelf.Add(a);
                shelf.Add(b);
                shelf.Add(folder);
                notch.ShowTab(NotchTab.Shelf);
                await Task.Delay(1500);
                await Picture(notch.Root, "3-ablage");
            });

            await Step("mixer", async () =>
            {
                notch.ShowTab(NotchTab.Mixer);
                await Task.Delay(1500);
                await Picture(notch.Root, "4-mixer");
                report.AppendLine("      output device: " + mixer.HasMaster + ", apps: " + mixer.Apps.Count);
                foreach (MixerApp app in mixer.Apps)
                {
                    // Down a little and back: the only change this test makes outside its folder, and it undoes it
                    double before = app.Volume;
                    string id = app.Id;
                    double changed = before > 0.5 ? before - 0.1 : before + 0.1;
                    mixer.SetAppVolume(id, changed);
                    mixer.Refresh();
                    MixerApp after = mixer.Apps.FirstOrDefault(a => a.Id == id);
                    bool reached = after != null && Math.Abs(after.Volume - changed) < 0.01;
                    mixer.SetAppVolume(id, before);
                    report.AppendLine("      volume of an app can be set: " + reached);
                    if (!reached) throw new InvalidOperationException("An app's volume didn't change.");
                    break;
                }
            });

            await Step("timer idle", async () =>
            {
                notch.ShowTab(NotchTab.Timer);
                await Picture(notch.Root, "5-timer");
            });

            await Step("timer running", async () =>
            {
                notch.Clock.Start(DateTime.UtcNow, 25 * 60);
                notch.TimerChangedForTest();
                await Task.Delay(1200);
                await Picture(notch.Root, "6-timer-laeuft");
            });

            await Step("closed with timer", async () =>
            {
                notch.CloseNotch();
                notch.SettleForTest();
                await Picture(notch.Root, "7-geschlossen-timer");
            });

            await Step("banner", async () =>
            {
                notch.Clock.Stop();
                notch.TimerChangedForTest();
                notch.ShowBannerForTest();
                notch.SettleForTest();
                await Picture(notch.Root, "8-banner");
            });

            await Step("search empty", async () =>
            {
                search.Open();
                search.SettleForTest();
                await Picture(search.Root, "9-suche-leer");
            });

            await Step("search apps", async () =>
            {
                AppCatalog.RefreshIfStale();
                for (int i = 0; i < 100 && AppCatalog.Apps.Count == 0; i++)
                {
                    await Task.Delay(100);
                }
                report.AppendLine("      apps found: " + AppCatalog.Apps.Count);

                search.TypeForTest("note");
                await Task.Delay(2500);
                search.SettleForTest();
                await Picture(search.Root, "10-suche-ergebnisse");
                report.AppendLine("      rows: " + search.ResultCount + ", file search failed: " + search.FileSearchFailed);
            });

            // On the test machine something really plays, so there nothing here may be missing
            bool mediaExpected = Environment.GetEnvironmentVariable("NOTCH_TEST_MEDIA") == "1";

            await Step("music", async () =>
            {
                search.HideLine();
                for (int i = 0; i < 100 && media.Current == null; i++)
                {
                    await Task.Delay(100);
                }
                NowPlaying now = media.Current;
                report.AppendLine("      session: " + (now != null) + (now == null ? "" : ", playing: " + now.IsPlaying + ", can skip: " + now.CanNext + ", app: " + now.AppId));
                if (mediaExpected)
                {
                    if (now == null) throw new InvalidOperationException("Nothing shows as playing.");
                    report.AppendLine("      title: " + now.Title + ", artist: " + now.Artist + ", cover: " + (now.Art != null));
                }
                if (Environment.GetEnvironmentVariable("NOTCH_TEST_COVER") == "1")
                {
                    // A cover comes after the title, and it may take its app a moment
                    for (int i = 0; i < 80 && (media.Current == null || media.Current.Art == null); i++)
                    {
                        await Task.Delay(100);
                    }
                    now = media.Current;
                    bool hasCover = now != null && now.Art != null;
                    report.AppendLine("      cover after waiting: " + hasCover + ", tint: " + (now == null ? "" : now.Tint.ToString()));
                    report.AppendLine("      the app has a volume of its own: " + (now != null && mixer.FindApp(now.AppId) != null));
                    if (!hasCover) throw new InvalidOperationException("The cover never came.");
                    media.Next();
                    await Task.Delay(1500);
                }

                notch.ShowTab(NotchTab.Home);
                notch.Open();
                notch.SettleForTest();
                await Task.Delay(800);
                await Picture(notch.Root, "11-musik");
                notch.CloseNotch();
                notch.SettleForTest();
                await Task.Delay(800);
                await Picture(notch.Root, "12-geschlossen-musik");
            });

            await Step("pause and play from here", async () =>
            {
                if (media.Current == null) return;
                bool before = media.Current.IsPlaying;
                media.TogglePlayPause();
                for (int i = 0; i < 50 && media.Current != null && media.Current.IsPlaying == before; i++)
                {
                    await Task.Delay(100);
                }
                bool changed = media.Current != null && media.Current.IsPlaying != before;
                report.AppendLine("      the button reached the player: " + changed);
                media.TogglePlayPause();
                await Task.Delay(1000);
                if (mediaExpected && !changed) throw new InvalidOperationException("Play and pause didn't reach the player.");
            });

            await Step("the graph's levels", async () =>
            {
                double loudest = 0;
                int calls = 0;
                Action<double[]> listen = values =>
                {
                    calls++;
                    if (values != null) loudest = Math.Max(loudest, values.Max());
                };
                levels.LevelsChanged += listen;
                bool wasRunning = levels.IsRunning;
                if (!wasRunning) levels.Start();
                await Task.Delay(2500);
                if (!wasRunning) levels.Stop();
                levels.LevelsChanged -= listen;
                report.AppendLine("      updates: " + calls + ", loudest: " + loudest.ToString("0.00"));
                if (mediaExpected && loudest <= 0) throw new InvalidOperationException("The graph heard nothing.");

                // On the test machine another app stays loud beside the player, and that's not what the graph is for
                if (Environment.GetEnvironmentVariable("NOTCH_TEST_ONLY_APP") == "1" && media.Current != null)
                {
                    media.TogglePlayPause();
                    await Task.Delay(2000);
                    int heard = 0;
                    Action<double[]> count = values =>
                    {
                        if (values != null) heard++;
                    };
                    levels.LevelsChanged += count;
                    levels.Start();
                    await Task.Delay(3000);
                    levels.Stop();
                    levels.LevelsChanged -= count;
                    media.TogglePlayPause();
                    await Task.Delay(1000);
                    report.AppendLine("      player paused, another app loud, updates heard: " + heard);
                    if (heard > 3) throw new InvalidOperationException("The graph heard another app.");
                }
            });

            await Step("outputs", () =>
            {
                var outputs = OutputDevices.List();
                report.AppendLine("      outputs: " + outputs.Count + ", current: " + outputs.Count(o => o.IsCurrent));
                if (mediaExpected)
                {
                    OutputDevice current = outputs.FirstOrDefault(o => o.IsCurrent);
                    if (current == null) throw new InvalidOperationException("No current output.");
                    // The current one again: this only proves Windows takes the call, it doesn't change anything
                    bool taken = OutputDevices.Select(current.Id);
                    report.AppendLine("      picking an output is taken: " + taken);
                    if (!taken) throw new InvalidOperationException("Picking an output failed.");
                }
                return Task.CompletedTask;
            });

            await Step("hot key", () =>
            {
                report.AppendLine("      Ctrl+Alt+A registered: " + notch.HotKeyRegistered);
                return Task.CompletedTask;
            });

            search.HideLine();
            report.AppendLine(failures == 0 ? "ALL OK" : failures + " FAILED");
            File.WriteAllText(Path.Combine(folder, "bericht.txt"), report.ToString(), new UTF8Encoding(false));
            return failures == 0 ? 0 : 1;
        }

        private static async Task Settle()
        {
            await Task.Delay(300);
            await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        }

        private static void Save(FrameworkElement element, string file)
        {
            int scale = 2;
            int width = (int)Math.Ceiling(element.ActualWidth * scale);
            int height = (int)Math.Ceiling(element.ActualHeight * scale);
            if (width == 0 || height == 0) throw new InvalidOperationException("The element has no size: " + file);

            // On dark gray, so the shape's edge and shadow can be seen in the picture
            var visual = new DrawingVisual();
            using (DrawingContext context = visual.RenderOpen())
            {
                context.DrawRectangle(Theme.Solid(0xFF, 0x3A, 0x3A, 0x40), null, new Rect(0, 0, element.ActualWidth, element.ActualHeight));
                var brush = new VisualBrush(element)
                {
                    ViewboxUnits = BrushMappingMode.Absolute,
                    Viewbox = new Rect(0, 0, element.ActualWidth, element.ActualHeight),
                    Stretch = Stretch.Fill,
                };
                context.DrawRectangle(brush, null, new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            }

            var bitmap = new RenderTargetBitmap(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var stream = File.Create(file))
            {
                encoder.Save(stream);
            }
        }
    }
}
