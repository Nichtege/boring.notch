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
        public static async Task<int> Run(string folder, NotchWindow notch, SearchWindow search, ShelfStore shelf, AudioMixer mixer)
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
