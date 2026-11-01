using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace BoringNotch
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct ShellImageSize
    {
        public int Width;
        public int Height;
    }

    [ComImport]
    [Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItemImageFactory
    {
        [PreserveSig]
        int GetImage(ShellImageSize size, int flags, out IntPtr bitmap);
    }

    /// <summary>
    /// What Windows itself shows for a file, folder or app: a thumbnail where there is one, its icon otherwise.
    /// A shell extension can take its time or misbehave, so they're made on a thread of their own, one at a time.
    /// </summary>
    internal static class ShellIcons
    {
        private const int ResizeToFit = 0;
        // A long-running app sees many search results, and each picture is kept in memory
        private const int MaxCached = 500;

        private static readonly BlockingCollection<Action> Queue = new BlockingCollection<Action>();
        private static readonly ConcurrentDictionary<string, ImageSource> Cache = new ConcurrentDictionary<string, ImageSource>();
        private static readonly object StartGate = new object();
        private static Thread _worker;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string path,
            IntPtr bindContext,
            [MarshalAs(UnmanagedType.LPStruct)] Guid interfaceId,
            [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

        /// <summary>Calls done on the UI thread, with null if there's no picture. A parsing name is a path or a shell:AppsFolder entry.</summary>
        public static void Load(string parsingName, int pixelSize, Action<ImageSource> done)
        {
            if (done == null) return;
            try
            {
                if (string.IsNullOrEmpty(parsingName) || pixelSize <= 0)
                {
                    Deliver(done, null);
                    return;
                }

                string key = pixelSize.ToString(CultureInfo.InvariantCulture) + "|" + parsingName;
                if (Cache.TryGetValue(key, out ImageSource cached))
                {
                    Deliver(done, cached);
                    return;
                }

                StartWorker();
                Queue.Add(() =>
                {
                    // Asked for twice before the first was done
                    if (!Cache.TryGetValue(key, out ImageSource image))
                    {
                        image = Create(parsingName, pixelSize);
                        if (image != null)
                        {
                            if (Cache.Count >= MaxCached)
                            {
                                Cache.Clear();
                            }
                            Cache[key] = image;
                        }
                    }
                    Deliver(done, image);
                });
            }
            catch (Exception e)
            {
                Log.Error(e);
                Deliver(done, null);
            }
        }

        private static void StartWorker()
        {
            lock (StartGate)
            {
                if (_worker != null) return;
                var thread = new Thread(Work) { IsBackground = true, Name = "ShellIcons" };
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
                _worker = thread;
            }
        }

        private static void Work()
        {
            foreach (Action work in Queue.GetConsumingEnumerable())
            {
                try
                {
                    work();
                }
                catch (Exception e)
                {
                    Log.Error(e);
                }
            }
        }

        private static ImageSource Create(string parsingName, int pixelSize)
        {
            IShellItemImageFactory factory = null;
            IntPtr bitmap = IntPtr.Zero;
            try
            {
                int result = SHCreateItemFromParsingName(parsingName, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out factory);
                if (result < 0 || factory == null) return null;

                var size = new ShellImageSize { Width = pixelSize, Height = pixelSize };
                result = factory.GetImage(size, ResizeToFit, out bitmap);
                if (result < 0 || bitmap == IntPtr.Zero) return null;

                BitmapSource source = Imaging.CreateBitmapSourceFromHBitmap(
                    bitmap,
                    IntPtr.Zero,
                    Int32Rect.Empty,
                    BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                return source;
            }
            catch (Exception e)
            {
                // A broken shell extension can surface as nearly anything. The name stays out of the log
                Log.Note("Symbol: " + e.GetType().Name + " 0x" + e.HResult.ToString("X8", CultureInfo.InvariantCulture));
                return null;
            }
            finally
            {
                if (bitmap != IntPtr.Zero)
                {
                    Native.DeleteObject(bitmap);
                }
                if (factory != null)
                {
                    Marshal.ReleaseComObject(factory);
                }
            }
        }

        private static void Deliver(Action<ImageSource> done, ImageSource image)
        {
            try
            {
                var dispatcher = Application.Current?.Dispatcher;
                if (dispatcher == null || dispatcher.HasShutdownStarted) return;
                dispatcher.BeginInvoke(new Action(() => done(image)));
            }
            catch (Exception e)
            {
                Log.Error(e);
            }
        }
    }
}
