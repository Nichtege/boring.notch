using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using BoringNotch.Core;

namespace BoringNotch
{
    /// <summary>
    /// The apps of the Start menu, packaged ones too. Reading them takes a moment, so it happens on the side and the
    /// search works with the last list until the new one is there.
    /// </summary>
    internal static class AppCatalog
    {
        private const string ShellPrefix = "shell:AppsFolder\\";
        private static readonly long MaxAgeTicks = TimeSpan.FromMinutes(5).Ticks;

        private static volatile IReadOnlyList<AppEntry> _apps = new AppEntry[0];
        private static long _loadedAtTicks;
        private static int _isLoading;

        public static IReadOnlyList<AppEntry> Apps => _apps;

        public static void RefreshIfStale()
        {
            if (DateTime.UtcNow.Ticks - Interlocked.Read(ref _loadedAtTicks) < MaxAgeTicks) return;
            if (Interlocked.CompareExchange(ref _isLoading, 1, 0) != 0) return;

            try
            {
                var thread = new Thread(Load) { IsBackground = true, Name = "AppCatalog" };
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
            }
            catch (Exception e)
            {
                Volatile.Write(ref _isLoading, 0);
                Log.Error(e);
            }
        }

        private static void Load()
        {
            try
            {
                List<AppEntry> found = FromAppsFolder();
                if (found.Count == 0)
                {
                    found = FromStartMenuFolders();
                }

                List<AppEntry> apps = found
                    .Where(app => !SearchRank.IsNoise(app.Name))
                    .GroupBy(app => app.Name, StringComparer.OrdinalIgnoreCase)
                    .Select(group => group.First())
                    .ToList();

                // Nothing found says nothing about the apps. The next search asks again
                if (apps.Count > 0)
                {
                    _apps = apps;
                    Interlocked.Exchange(ref _loadedAtTicks, DateTime.UtcNow.Ticks);
                }
            }
            catch (Exception e)
            {
                Log.Error(e);
            }
            finally
            {
                Volatile.Write(ref _isLoading, 0);
            }
        }

        /// <summary>The folder behind "All apps", the one place that has the packaged ones.</summary>
        private static List<AppEntry> FromAppsFolder()
        {
            var apps = new List<AppEntry>();
            object shell = null;
            try
            {
                Type type = Type.GetTypeFromProgID("Shell.Application");
                if (type == null) return apps;

                shell = Activator.CreateInstance(type);
                dynamic folder = ((dynamic)shell).NameSpace("shell:AppsFolder");
                if (folder == null) return apps;

                foreach (dynamic item in folder.Items())
                {
                    try
                    {
                        string name = item.Name;
                        string path = item.Path;
                        if (!string.IsNullOrWhiteSpace(name) && !string.IsNullOrWhiteSpace(path))
                        {
                            apps.Add(new AppEntry { Name = name.Trim(), Target = ShellPrefix + path });
                        }
                    }
                    catch (Exception e)
                    {
                        // One odd entry shouldn't cost the others
                        Log.Note("App-Eintrag: " + e.GetType().Name);
                    }
                }
            }
            catch (Exception e)
            {
                Log.Error(e);
            }
            finally
            {
                if (shell != null && Marshal.IsComObject(shell))
                {
                    Marshal.FinalReleaseComObject(shell);
                }
            }
            return apps;
        }

        private static List<AppEntry> FromStartMenuFolders()
        {
            var apps = new List<AppEntry>();
            CollectShortcuts(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), apps);
            CollectShortcuts(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), apps);
            return apps;
        }

        /// <summary>Folder by folder, as one that's closed to this user would end a single sweep over all of them.</summary>
        private static void CollectShortcuts(string folder, List<AppEntry> apps)
        {
            if (string.IsNullOrEmpty(folder)) return;
            try
            {
                foreach (string shortcut in Directory.GetFiles(folder, "*.lnk"))
                {
                    apps.Add(new AppEntry { Name = Path.GetFileNameWithoutExtension(shortcut), Target = shortcut });
                }
                foreach (string below in Directory.GetDirectories(folder))
                {
                    CollectShortcuts(below, apps);
                }
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                // Whatever can't be read just isn't in the list
            }
        }
    }
}
