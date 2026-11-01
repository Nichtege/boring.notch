using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Windows;
using BoringNotch.Core;

namespace BoringNotch
{
    internal static class Program
    {
        private static readonly Dictionary<string, Assembly> Loaded = new Dictionary<string, Assembly>();

        [STAThread]
        private static int Main(string[] args)
        {
            // Before anything touches a library, as those travel inside the exe
            AppDomain.CurrentDomain.AssemblyResolve += LoadEmbedded;
            return Start(args);
        }

        private static Assembly LoadEmbedded(object sender, ResolveEventArgs e)
        {
            string name = new AssemblyName(e.Name).Name + ".dll";
            lock (Loaded)
            {
                if (Loaded.TryGetValue(name, out Assembly loaded)) return loaded;
                using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
                {
                    if (stream == null) return null;
                    var bytes = new byte[stream.Length];
                    int read = 0;
                    while (read < bytes.Length)
                    {
                        int count = stream.Read(bytes, read, bytes.Length - read);
                        if (count == 0) break;
                        read += count;
                    }
                    Assembly assembly = Assembly.Load(bytes);
                    Loaded[name] = assembly;
                    return assembly;
                }
            }
        }

        // Not inlined: this method's own references have to wait for the handler above
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Start(string[] args)
        {
            AppDomain.CurrentDomain.UnhandledException += (sender, e) =>
            {
                if (e.ExceptionObject is Exception exception) Log.Error(exception);
            };

            string testFolder = args.Length == 2 && args[0] == "--selftest" ? args[1] : null;

            // A second start does nothing, or two notches would sit on top of each other
            using (var single = new Mutex(true, @"Local\BoringNotch.Windows", out bool isFirst))
            {
                if (!isFirst && testFolder == null) return 0;

                var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                app.DispatcherUnhandledException += (sender, e) =>
                {
                    Log.Error(e.Exception);
                    e.Handled = testFolder == null;
                };

                string storeFolder = testFolder ?? Log.Folder;
                var shelf = new ShelfStore(Path.Combine(storeFolder, "ablage.txt"));
                shelf.Load();

                var mixer = new AudioMixer();
                var search = new SearchWindow();
                var notch = new NotchWindow(shelf, mixer, search);

                if (testFolder != null)
                {
                    int result = 1;
                    notch.Loaded += async (sender, e) =>
                    {
                        result = await SelfTest.Run(testFolder, notch, search, shelf, mixer);
                        app.Shutdown(result);
                    };
                    notch.Show();
                    app.Run();
                    return result;
                }

                Tray tray = null;
                Action quit = () =>
                {
                    notch.Close();
                    search.Close();
                    tray?.Dispose();
                    app.Shutdown();
                };
                tray = new Tray(quit);
                notch.Show();
                AppCatalog.RefreshIfStale();
                app.Run();
                GC.KeepAlive(single);
                return 0;
            }
        }
    }
}
