using System;
using System.Globalization;
using System.Threading;
using System.Windows.Threading;
using BoringNotch.Core;

namespace BoringNotch
{
    /// <summary>
    /// Real levels of the app that plays, and of nothing else on the PC, for the bars beside the notch. Listens only between
    /// Start and Stop, and the sound is analyzed as it passes and never kept.
    ///
    /// Nothing to show means one LevelsChanged(null), and the bars fall back to animating. That's also what happens where
    /// Windows won't hand over one app's sound, as it never falls back to all the sound of the PC. A capture that couldn't
    /// start stays off for that process until the next Start, so it can never retry in a loop.
    /// </summary>
    internal sealed class AudioLevels
    {
        private static readonly TimeSpan SilenceBeforeGivingUp = TimeSpan.FromSeconds(1.5);

        private readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
        private readonly Func<int> _findProcess;
        private readonly DispatcherTimer _silence = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        // What plays can change, and a player can start its sound in another process
        private readonly DispatcherTimer _targetCheck = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };

        private AppAudioCapture _capture;
        private SpectrumBands _bands;
        private DateTime _lastLevels;
        private int _target;
        private int _failedTarget;
        private bool _saidNothing;
        private string _lastProblem;
        // Levels on their way to the UI thread: a busy thread gets the newest, not a queue of old ones
        private double[] _waiting;
        private int _isScheduled;

        /// <param name="findProcess">The process making the sound of what plays, 0 if that can't be told. On the UI thread.</param>
        public AudioLevels(Func<int> findProcess)
        {
            _findProcess = findProcess;
            _silence.Tick += (sender, e) => CheckSilence();
            _targetCheck.Tick += (sender, e) => CheckTarget();
        }

        /// <summary>One value per bar from 0 to 1, low notes first, on the UI thread. Null: nothing to show right now.</summary>
        public event Action<double[]> LevelsChanged;

        public bool IsRunning { get; private set; }

        public void Start()
        {
            if (IsRunning) return;
            IsRunning = true;
            _target = 0;
            _failedTarget = 0;
            _saidNothing = false;
            _lastLevels = DateTime.UtcNow;
            _silence.Start();
            _targetCheck.Start();
            CheckTarget();
        }

        public void Stop()
        {
            if (!IsRunning) return;
            IsRunning = false;
            _silence.Stop();
            _targetCheck.Stop();
            End();
        }

        private void CheckTarget()
        {
            if (!IsRunning) return;

            int process;
            try
            {
                process = _findProcess();
            }
            catch (Exception e)
            {
                Report(e);
                process = 0;
            }
            if (process == _target) return;

            End();
            _target = process;
            if (process == 0 || process == _failedTarget)
            {
                SayNothing();
                return;
            }

            _lastLevels = DateTime.UtcNow;
            _bands = new SpectrumBands(AppAudioCapture.SampleRate);
            _capture = new AppAudioCapture(process);
            _capture.DataAvailable += OnData;
            _capture.Failed += OnFailed;
            _capture.Start();
        }

        private void End()
        {
            AppAudioCapture capture = _capture;
            _capture = null;
            _bands = null;
            Interlocked.Exchange(ref _waiting, null);

            if (capture != null)
            {
                capture.DataAvailable -= OnData;
                capture.Failed -= OnFailed;
                capture.Stop();
            }
        }

        // On the capture's own thread
        private void OnData(byte[] buffer, int bytes)
        {
            SpectrumBands bands = _bands;
            if (bands == null) return;

            double[] levels = bands.Feed(buffer, bytes, AppAudioCapture.Channels);
            if (levels == null) return;

            Interlocked.Exchange(ref _waiting, levels);
            if (Interlocked.Exchange(ref _isScheduled, 1) == 0)
            {
                _ui.BeginInvoke(new Action(Deliver), DispatcherPriority.Background);
            }
        }

        private void Deliver()
        {
            Interlocked.Exchange(ref _isScheduled, 0);
            double[] levels = Interlocked.Exchange(ref _waiting, null);
            if (!IsRunning || levels == null) return;

            _lastLevels = DateTime.UtcNow;
            _saidNothing = false;
            LevelsChanged?.Invoke(levels);
        }

        // On the capture's own thread
        private void OnFailed(Exception e, bool hadData)
        {
            AppAudioCapture failed = _capture;
            _ui.BeginInvoke(new Action(() =>
            {
                if (!IsRunning || !ReferenceEquals(failed, _capture)) return;

                Report(e);
                // One that worked and ended has an app that quit or an output that changed, so the next check starts over.
                // One that never gave anything would only fail again.
                if (!hadData)
                {
                    _failedTarget = _target;
                }
                End();
                _target = 0;
                SayNothing();
            }));
        }

        private void CheckSilence()
        {
            if (!IsRunning) return;
            if (DateTime.UtcNow - _lastLevels > SilenceBeforeGivingUp)
            {
                SayNothing();
            }
        }

        private void SayNothing()
        {
            if (_saidNothing) return;
            _saidNothing = true;
            // Later, so a Start can't call back into whoever is still starting it
            _ui.BeginInvoke(new Action(() =>
            {
                if (IsRunning && _saidNothing) LevelsChanged?.Invoke(null);
            }));
        }

        private void Report(Exception e)
        {
            string problem = "Pegel: " + e.GetType().Name + " 0x" + e.HResult.ToString("X8", CultureInfo.InvariantCulture);
            if (problem != _lastProblem)
            {
                _lastProblem = problem;
                Log.Note(problem);
            }
        }
    }
}
