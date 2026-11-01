using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using BoringNotch.Core;
using Windows.Media.Control;
using Windows.Storage.Streams;
using Manager = Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager;
using Session = Windows.Media.Control.GlobalSystemMediaTransportControlsSession;

namespace BoringNotch
{
    /// <summary>What plays at this moment. A snapshot: a change makes a new one.</summary>
    internal sealed class NowPlaying
    {
        public string Title;
        public string Artist;
        public ImageSource Art;
        public Color Tint = Colors.White;
        public bool IsPlaying;
        public double Duration;
        public double Elapsed;
        public DateTime ElapsedAtUtc;
        public double Rate = 1;
        public bool CanPlayPause;
        public bool CanNext;
        public bool CanPrevious;
        public bool CanSeek;
        public string AppId;
    }

    /// <summary>
    /// What apps tell Windows they play, the same list as the media controls beside the volume flyout. An app that doesn't
    /// report just isn't here. Only for the UI thread, except that Windows' events arrive on others and are brought over.
    /// Titles and artists stay in memory and never go in the log.
    /// </summary>
    internal sealed class MediaSessions
    {
        private const int ArtPixels = 256;
        private static readonly Version InBoxBridge = new Version(4, 0, 0, 0);
        private static readonly TimeSpan IdleAfterPause = TimeSpan.FromSeconds(3);
        // A safety net: Windows' events have been known to stop for an app, and asking it costs next to nothing
        private static readonly TimeSpan LookAgain = TimeSpan.FromSeconds(2);
        // Right after a seek an app may still report where it was
        private static readonly TimeSpan TrustSeekFor = TimeSpan.FromSeconds(1);

        private readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
        private readonly DispatcherTimer _idle = new DispatcherTimer { Interval = IdleAfterPause };
        private readonly DispatcherTimer _poll = new DispatcherTimer { Interval = LookAgain };
        private readonly Dictionary<string, Watched> _watched = new Dictionary<string, Watched>();

        private bool _isStarted;
        private Manager _manager;
        private Session _shown;
        private string _shownId;
        private string _title;
        private string _artist;
        private ImageSource _art;
        private Color _tint = Colors.White;
        private int _mediaGeneration;
        private long _startTicks;
        private DateTime _seekedAtUtc;
        private double _seekedTo;
        private int _isRefreshScheduled;
        private string _lastProblem;

        static MediaSessions()
        {
            AppDomain.CurrentDomain.AssemblyResolve += FindWindowsRuntimeBridge;
        }

        /// <summary>
        /// Microsoft's package builds against a newer number of this bridge than the one Windows carries. Windows is meant
        /// to settle that by itself, and this only answers if it doesn't, as without it nothing here would load.
        /// </summary>
        private static Assembly FindWindowsRuntimeBridge(object sender, ResolveEventArgs e)
        {
            var name = new AssemblyName(e.Name);
            if (name.Name != "System.Runtime.WindowsRuntime" || name.Version == null || name.Version == InBoxBridge) return null;
            name.Version = InBoxBridge;
            try
            {
                return Assembly.Load(name);
            }
            catch (Exception failure) when (failure is FileNotFoundException || failure is FileLoadException || failure is BadImageFormatException)
            {
                return null;
            }
        }

        public MediaSessions()
        {
            _idle.Tick += (sender, e) =>
            {
                _idle.Stop();
                if (Current == null || Current.IsPlaying) return;
                IsIdle = true;
                Changed?.Invoke();
            };
            _poll.Tick += (sender, e) => Refresh();
        }

        /// <summary>Anything about what plays changed. Always on the UI thread.</summary>
        public event Action Changed;

        /// <summary>Null when nothing is there.</summary>
        public NowPlaying Current { get; private set; }

        /// <summary>As on the Mac: nothing's there, or it's been paused for 3 s.</summary>
        public bool IsIdle { get; private set; } = true;

        public void Start()
        {
            if (_isStarted) return;
            _isStarted = true;
            try
            {
                StartListening();
            }
            catch (Exception e)
            {
                // A Windows without this API fails right here, when the method above is first needed
                Report("Start", e);
            }
        }

        public void Stop()
        {
            if (!_isStarted) return;
            _isStarted = false;
            _poll.Stop();
            _idle.Stop();
            _mediaGeneration++;
            try
            {
                StopListening();
            }
            catch (Exception e)
            {
                Report("Stop", e);
            }
            _shown = null;
            _shownId = null;
            _title = null;
            _artist = null;
            _art = null;
            _tint = Colors.White;
            Current = null;
            IsIdle = true;
        }

        public void TogglePlayPause() => Send(session => session.TryTogglePlayPauseAsync());

        public void Next() => Send(session => session.TrySkipNextAsync());

        public void Previous() => Send(session => session.TrySkipPreviousAsync());

        public void Seek(double seconds)
        {
            double position = Math.Max(0, seconds);
            long ticks = _startTicks + (long)(position * TimeSpan.TicksPerSecond);
            Send(session => session.TryChangePlaybackPositionAsync(ticks));

            _seekedAtUtc = DateTime.UtcNow;
            _seekedTo = position;
            Refresh();
        }

        // MARK: - Listening

        [MethodImpl(MethodImplOptions.NoInlining)]
        private async void StartListening()
        {
            try
            {
                Manager manager = await Manager.RequestAsync().AsTask().ConfigureAwait(true);
                if (!_isStarted || manager == null) return;

                _manager = manager;
                _manager.SessionsChanged += OnManagerChanged;
                _manager.CurrentSessionChanged += OnCurrentChanged;
                _poll.Start();
                Refresh();
            }
            catch (Exception e)
            {
                Report("Start", e);
            }
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private void StopListening()
        {
            foreach (string id in _watched.Keys.ToList())
            {
                Unwatch(id);
            }
            if (_manager != null)
            {
                _manager.SessionsChanged -= OnManagerChanged;
                _manager.CurrentSessionChanged -= OnCurrentChanged;
                _manager = null;
            }
        }

        private void OnManagerChanged(Manager sender, SessionsChangedEventArgs args) => ScheduleRefresh();

        private void OnCurrentChanged(Manager sender, CurrentSessionChangedEventArgs args) => ScheduleRefresh();

        /// <summary>Events come in bursts and on other threads, and one look afterwards answers them all.</summary>
        private void ScheduleRefresh()
        {
            if (Interlocked.Exchange(ref _isRefreshScheduled, 1) == 0)
            {
                _ui.BeginInvoke(new Action(() =>
                {
                    Interlocked.Exchange(ref _isRefreshScheduled, 0);
                    Refresh();
                }));
            }
        }

        private void MediaChanged(string appId)
        {
            _ui.BeginInvoke(new Action(() =>
            {
                if (appId == _shownId) LoadMedia();
            }));
        }

        // MARK: - What's shown

        private void Refresh()
        {
            if (!_isStarted || _manager == null) return;
            try
            {
                List<Session> sessions = _manager.GetSessions().ToList();
                WatchOnly(sessions);

                Session current = _manager.GetCurrentSession();
                string currentId = current == null ? null : current.SourceAppUserModelId;
                var choices = sessions
                    .Select(s => new KeyValuePair<string, bool>(s.SourceAppUserModelId, IsPlaying(s)))
                    .ToList();
                string pick = SessionChoice.Pick(_shownId, currentId, choices);
                Session picked = pick == null ? null : sessions.FirstOrDefault(s => s.SourceAppUserModelId == pick);

                bool isNew = pick != _shownId;
                _shown = picked;
                _shownId = pick;
                if (isNew)
                {
                    _mediaGeneration++;
                    _title = null;
                    _artist = null;
                    _art = null;
                    _tint = Colors.White;
                    _seekedAtUtc = default(DateTime);
                    if (picked != null) LoadMedia();
                }
                Publish();
            }
            catch (Exception e)
            {
                // An app quitting while it's read, for one
                Report("Refresh", e);
            }
        }

        private static bool IsPlaying(Session session)
        {
            GlobalSystemMediaTransportControlsSessionPlaybackInfo info = session.GetPlaybackInfo();
            return info != null && info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        }

        private void Publish()
        {
            NowPlaying next = _shown == null ? null : Read(_shown);
            bool changed = !Same(Current, next);
            Current = next;
            UpdateIdle();
            if (changed) Changed?.Invoke();
        }

        private NowPlaying Read(Session session)
        {
            GlobalSystemMediaTransportControlsSessionPlaybackInfo info = session.GetPlaybackInfo();
            GlobalSystemMediaTransportControlsSessionTimelineProperties timeline = session.GetTimelineProperties();
            GlobalSystemMediaTransportControlsSessionPlaybackControls controls = info?.Controls;

            bool isPlaying = info != null && info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
            double duration = 0;
            double elapsed = 0;
            DateTime elapsedAt = DateTime.UtcNow;
            if (timeline != null)
            {
                _startTicks = timeline.StartTime.Ticks;
                duration = Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds);
                elapsed = Math.Max(0, (timeline.Position - timeline.StartTime).TotalSeconds);
                // Never reported yet comes as a date centuries ago, which would run the estimate to the end
                if (timeline.LastUpdatedTime.Year > 2000)
                {
                    elapsedAt = timeline.LastUpdatedTime.UtcDateTime;
                }
            }
            if (DateTime.UtcNow - _seekedAtUtc < TrustSeekFor)
            {
                elapsed = _seekedTo;
                elapsedAt = _seekedAtUtc;
            }

            return new NowPlaying
            {
                Title = _title ?? "",
                Artist = _artist ?? "",
                Art = _art,
                Tint = _tint,
                IsPlaying = isPlaying,
                Duration = duration,
                Elapsed = elapsed,
                ElapsedAtUtc = elapsedAt,
                Rate = info?.PlaybackRate ?? 1,
                CanPlayPause = controls != null && (controls.IsPlayPauseToggleEnabled || controls.IsPlayEnabled || controls.IsPauseEnabled),
                CanNext = controls != null && controls.IsNextEnabled,
                CanPrevious = controls != null && controls.IsPreviousEnabled,
                CanSeek = controls != null && controls.IsPlaybackPositionEnabled && duration > 0,
                AppId = session.SourceAppUserModelId,
            };
        }

        private static bool Same(NowPlaying a, NowPlaying b)
        {
            if (a == null || b == null) return a == b;
            return a.Title == b.Title && a.Artist == b.Artist && ReferenceEquals(a.Art, b.Art) && a.Tint == b.Tint
                && a.IsPlaying == b.IsPlaying && a.Duration == b.Duration && a.Elapsed == b.Elapsed
                && a.ElapsedAtUtc == b.ElapsedAtUtc && a.Rate == b.Rate && a.CanPlayPause == b.CanPlayPause
                && a.CanNext == b.CanNext && a.CanPrevious == b.CanPrevious && a.CanSeek == b.CanSeek && a.AppId == b.AppId;
        }

        private void UpdateIdle()
        {
            if (Current == null)
            {
                _idle.Stop();
                IsIdle = true;
            }
            else if (Current.IsPlaying)
            {
                _idle.Stop();
                IsIdle = false;
            }
            else if (!IsIdle && !_idle.IsEnabled)
            {
                // Only just paused. Something shown for the first time while paused stays idle, as nothing played
                _idle.Start();
            }
        }

        // MARK: - Title and cover

        private async void LoadMedia()
        {
            Session session = _shown;
            if (session == null) return;
            int generation = ++_mediaGeneration;

            try
            {
                GlobalSystemMediaTransportControlsSessionMediaProperties media =
                    await session.TryGetMediaPropertiesAsync().AsTask().ConfigureAwait(true);
                if (generation != _mediaGeneration || media == null) return;

                string title = media.Title;
                string artist = media.Artist;
                if (string.IsNullOrEmpty(artist)) artist = media.AlbumArtist;
                IRandomAccessStreamReference thumbnail = media.Thumbnail;

                // The text at once: a cover can take long, or never come at all
                _title = title;
                _artist = artist;
                if (thumbnail == null)
                {
                    _art = null;
                    _tint = Colors.White;
                }
                Publish();
                if (thumbnail == null) return;

                Art art = await Task.Run(() => ReadArt(thumbnail)).ConfigureAwait(true);
                if (generation != _mediaGeneration) return;

                _art = art.Image;
                _tint = art.Tint;
                Publish();
            }
            catch (Exception e)
            {
                Report("Medien", e);
            }
        }

        private sealed class Art
        {
            public ImageSource Image;
            public Color Tint;
        }

        /// <summary>Not on the UI thread, as a cover can take a moment to come from its app.</summary>
        private static async Task<Art> ReadArt(IRandomAccessStreamReference thumbnail)
        {
            IRandomAccessStreamWithContentType source = await thumbnail.OpenReadAsync().AsTask().ConfigureAwait(false);
            using (source)
            using (Stream stream = source.AsStreamForRead())
            using (var bytes = new MemoryStream())
            {
                await stream.CopyToAsync(bytes).ConfigureAwait(false);
                bytes.Position = 0;

                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = ArtPixels;
                image.StreamSource = bytes;
                image.EndInit();
                image.Freeze();
                return new Art { Image = image, Tint = TintOf(image) };
            }
        }

        private static Color TintOf(BitmapSource image)
        {
            var pixels = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
            int stride = pixels.PixelWidth * 4;
            var bytes = new byte[stride * pixels.PixelHeight];
            pixels.CopyPixels(bytes, stride, 0);
            Rgb average = ColorMath.Average(bytes);
            return Color.FromRgb(average.R, average.G, average.B);
        }

        // MARK: - Commands

        private async void Send(Func<Session, Windows.Foundation.IAsyncOperation<bool>> command)
        {
            Session session = _shown;
            if (session == null) return;
            try
            {
                await command(session).AsTask().ConfigureAwait(true);
            }
            catch (Exception e)
            {
                Report("Befehl", e);
            }
            ScheduleRefresh();
        }

        // MARK: - Watching each app

        /// <summary>All of them, not only what's shown, as another one starting to play has to be noticed.</summary>
        private void WatchOnly(List<Session> sessions)
        {
            var ids = new HashSet<string>(sessions.Select(s => s.SourceAppUserModelId));
            foreach (string id in _watched.Keys.Where(id => !ids.Contains(id)).ToList())
            {
                Unwatch(id);
            }
            foreach (Session session in sessions)
            {
                string id = session.SourceAppUserModelId;
                if (_watched.ContainsKey(id)) continue;
                _watched[id] = new Watched(session, this, id);
            }
        }

        private void Unwatch(string id)
        {
            if (_watched.TryGetValue(id, out Watched watched))
            {
                _watched.Remove(id);
                watched.Unsubscribe();
            }
        }

        /// <summary>Keeps the session from the garbage collector, as its events end with it.</summary>
        private sealed class Watched
        {
            private readonly Session _session;
            private readonly MediaSessions _owner;
            private readonly string _id;

            public Watched(Session session, MediaSessions owner, string id)
            {
                _session = session;
                _owner = owner;
                _id = id;
                _session.PlaybackInfoChanged += OnPlayback;
                _session.TimelinePropertiesChanged += OnTimeline;
                _session.MediaPropertiesChanged += OnMedia;
            }

            public void Unsubscribe()
            {
                try
                {
                    _session.PlaybackInfoChanged -= OnPlayback;
                    _session.TimelinePropertiesChanged -= OnTimeline;
                    _session.MediaPropertiesChanged -= OnMedia;
                }
                catch (Exception e)
                {
                    // A session that's gone can refuse this, and it won't be sending anything anyway
                    _owner.Report("Abmelden", e);
                }
            }

            private void OnPlayback(Session sender, PlaybackInfoChangedEventArgs args) => _owner.ScheduleRefresh();

            private void OnTimeline(Session sender, TimelinePropertiesChangedEventArgs args) => _owner.ScheduleRefresh();

            private void OnMedia(Session sender, MediaPropertiesChangedEventArgs args) => _owner.MediaChanged(_id);
        }

        /// <summary>Only the place and the code, and each one once in a row, as titles have no place in a log.</summary>
        private void Report(string where, Exception e)
        {
            string problem = "Musik " + where + ": " + e.GetType().Name + " 0x" + e.HResult.ToString("X8", CultureInfo.InvariantCulture);
            if (problem != _lastProblem)
            {
                _lastProblem = problem;
                Log.Note(problem);
            }
        }
    }
}
