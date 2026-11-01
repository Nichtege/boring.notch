using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace BoringNotch
{
    internal sealed class MixerApp
    {
        public string Id;
        public string Name;
        public string IconPath;
        public double Volume;
    }

    /// <summary>
    /// The volume of the PC and of every app making sound. Windows keeps each app's volume itself, so nothing is stored
    /// here and no sound passes through this app. Only for the UI thread.
    ///
    /// Sessions don't get disposed on purpose: a session seen twice is one COM object behind two wrappers, and releasing
    /// one wrapper would kill the other. They're a few small objects while the tab is open, which the GC takes care of.
    /// Devices do, on this thread: left to their finalizer they unregister from Windows on another one, and an error
    /// there would end the whole app.
    /// </summary>
    internal sealed class AudioMixer
    {
        // A pause between two songs shouldn't make a row jump away
        private static readonly TimeSpan RowLinger = TimeSpan.FromSeconds(4);
        private static readonly uint OwnProcess = (uint)Process.GetCurrentProcess().Id;

        private readonly Dictionary<string, string> _names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, DateTime> _lastActive = new Dictionary<string, DateTime>();
        private Dictionary<string, List<AudioSessionControl>> _sessions = new Dictionary<string, List<AudioSessionControl>>();
        private MMDeviceEnumerator _enumerator;
        private MMDevice _device;
        private AudioEndpointVolume _deviceVolume;
        private AudioSessionManager _deviceSessions;
        private string _lastProblem;

        public bool HasMaster { get; private set; }

        public double MasterVolume { get; private set; }

        public IReadOnlyList<MixerApp> Apps { get; private set; } = new MixerApp[0];

        public void Refresh()
        {
            try
            {
                _enumerator = _enumerator ?? new MMDeviceEnumerator();
                if (!_enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
                {
                    Forget();
                    return;
                }

                // The same device keeps its objects, as each one of them registers with Windows for changes
                MMDevice current = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                if (_device != null && _device.ID == current.ID)
                {
                    Release(current, null, null);
                }
                else
                {
                    ReleaseDevice();
                    _device = current;
                    _deviceVolume = current.AudioEndpointVolume;
                    _deviceSessions = current.AudioSessionManager;
                }

                MasterVolume = _deviceVolume.MasterVolumeLevelScalar;
                HasMaster = true;
                ReadSessions(_deviceSessions);
            }
            catch (Exception e)
            {
                // No sound service, a device unplugged this moment: the tab then just has nothing to show
                Forget();
                Report(e);
            }
        }

        public void SetMasterVolume(double volume)
        {
            double clamped = Clamp(volume);
            try
            {
                if (_deviceVolume == null) return;
                _deviceVolume.MasterVolumeLevelScalar = (float)clamped;
                MasterVolume = clamped;
            }
            catch (Exception e)
            {
                Report(e);
            }
        }

        public void SetAppVolume(string id, double volume)
        {
            double clamped = Clamp(volume);
            if (id == null || !_sessions.TryGetValue(id, out List<AudioSessionControl> sessions)) return;

            foreach (AudioSessionControl session in sessions)
            {
                try
                {
                    SimpleAudioVolume control = session.SimpleAudioVolume;
                    if (control != null)
                    {
                        control.Volume = (float)clamped;
                    }
                }
                catch (Exception e)
                {
                    // An app that just quit takes its session along, and the others should still change
                    Report(e);
                }
            }

            MixerApp row = Apps.FirstOrDefault(app => app.Id == id);
            if (row != null)
            {
                row.Volume = clamped;
            }
        }

        /// <summary>Before quitting, as finalizers also run while the app ends.</summary>
        public void Close()
        {
            Forget();
        }

        private void ReadSessions(AudioSessionManager manager)
        {
            manager.RefreshSessions();
            SessionCollection found = manager.Sessions;

            DateTime now = DateTime.UtcNow;
            var sessions = new Dictionary<string, List<AudioSessionControl>>();
            var rows = new Dictionary<string, MixerApp>();
            var volumeRead = new HashSet<string>();
            var volumeFromActive = new HashSet<string>();

            int count = found == null ? 0 : found.Count;
            for (int index = 0; index < count; index++)
            {
                try
                {
                    AudioSessionControl session = found[index];
                    uint process = session.GetProcessID;
                    if (session.IsSystemSoundsSession || process == 0 || process == OwnProcess) continue;

                    string path = Native.ProcessPath(process);
                    string id = path != null
                        ? path.ToLowerInvariant()
                        : "pid:" + process.ToString(CultureInfo.InvariantCulture);

                    if (!sessions.TryGetValue(id, out List<AudioSessionControl> group))
                    {
                        group = new List<AudioSessionControl>();
                        sessions[id] = group;
                    }
                    group.Add(session);

                    bool isActive = session.State == AudioSessionState.AudioSessionStateActive;
                    if (isActive)
                    {
                        _lastActive[id] = now;
                    }

                    if (!rows.TryGetValue(id, out MixerApp row))
                    {
                        row = new MixerApp { Id = id, Name = NameOf(path, session, process), IconPath = path };
                        rows[id] = row;
                    }

                    // With several sessions, the first one playing is what the slider should say
                    SimpleAudioVolume control = session.SimpleAudioVolume;
                    if (control != null)
                    {
                        bool isFirstActive = isActive && volumeFromActive.Add(id);
                        if (volumeRead.Add(id) || isFirstActive)
                        {
                            row.Volume = Clamp(control.Volume);
                        }
                    }
                }
                catch (Exception e)
                {
                    // One session going away while it's read shouldn't cost the others
                    Report(e);
                }
            }

            foreach (string gone in _lastActive.Where(pair => now - pair.Value > RowLinger).Select(pair => pair.Key).ToList())
            {
                _lastActive.Remove(gone);
            }

            _sessions = sessions;
            Apps = rows.Values
                .Where(row => _lastActive.ContainsKey(row.Id))
                .OrderBy(row => row.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }

        private string NameOf(string path, AudioSessionControl session, uint process)
        {
            if (path == null)
            {
                string display = session.DisplayName;
                // Windows' own sessions name a resource like @%SystemRoot%\... instead of a text
                return !string.IsNullOrWhiteSpace(display) && !display.StartsWith("@", StringComparison.Ordinal)
                    ? display
                    : "App " + process.ToString(CultureInfo.InvariantCulture);
            }

            if (_names.TryGetValue(path, out string known)) return known;

            string name = null;
            try
            {
                name = FileVersionInfo.GetVersionInfo(path).FileDescription;
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException)
            {
                // Not everything lets itself be read, and the file name will do
            }
            name = string.IsNullOrWhiteSpace(name) ? Path.GetFileNameWithoutExtension(path) : name.Trim();
            _names[path] = name;
            return name;
        }

        private void ReleaseDevice()
        {
            Release(_device, _deviceVolume, _deviceSessions);
            _device = null;
            _deviceVolume = null;
            _deviceSessions = null;
        }

        private void Release(MMDevice device, AudioEndpointVolume volume, AudioSessionManager sessions)
        {
            if (device == null) return;
            try
            {
                device.Dispose();
            }
            catch (Exception e)
            {
                // It failed here where it does no harm, and it mustn't get a second try from a finalizer
                GC.SuppressFinalize(device);
                if (volume != null) GC.SuppressFinalize(volume);
                if (sessions != null) GC.SuppressFinalize(sessions);
                Report(e);
            }
        }

        private void Forget()
        {
            ReleaseDevice();
            HasMaster = false;
            MasterVolume = 0;
            Apps = new MixerApp[0];
            _sessions = new Dictionary<string, List<AudioSessionControl>>();
            _lastActive.Clear();
        }

        /// <summary>Asked for every second, so the same problem goes in the log only once in a row.</summary>
        private void Report(Exception e)
        {
            string problem = "Audio: " + e.GetType().Name + " 0x" + e.HResult.ToString("X8", CultureInfo.InvariantCulture);
            if (problem != _lastProblem)
            {
                _lastProblem = problem;
                Log.Note(problem);
            }
        }

        private static double Clamp(double volume)
        {
            return Math.Max(0, Math.Min(1, volume));
        }
    }
}
