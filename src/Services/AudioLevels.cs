using System;
using System.Globalization;
using System.Threading;
using System.Windows.Threading;
using BoringNotch.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace BoringNotch
{
    /// <summary>
    /// Real levels of what the PC plays, for the bars beside the notch. Listens only between Start and Stop, and the
    /// sound is analyzed as it passes and never kept. Windows hands over everything going to the output as one, so these
    /// are the levels of all sound on the PC, not of one app.
    ///
    /// Nothing to show means one LevelsChanged(null), and the bars fall back to animating. A failed capture stays failed
    /// until the next Start. Only a change of the output device starts it over, so it can never retry in a loop.
    /// </summary>
    internal sealed class AudioLevels
    {
        private static readonly TimeSpan SilenceBeforeGivingUp = TimeSpan.FromSeconds(1.5);

        private readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
        private readonly DispatcherTimer _silence = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };

        private WasapiLoopbackCapture _capture;
        private MMDevice _device;
        private SpectrumBands _bands;
        private DateTime _lastLevels;
        private bool _saidNothing;
        private bool _hasFailed;
        private string _deviceId;
        private string _lastProblem;
        // Levels on their way to the UI thread: a busy thread gets the newest, not a queue of old ones
        private double[] _waiting;
        private int _isScheduled;

        public AudioLevels()
        {
            _silence.Tick += (sender, e) => CheckSilence();
        }

        /// <summary>One value per bar from 0 to 1, low notes first, on the UI thread. Null: nothing to show right now.</summary>
        public event Action<double[]> LevelsChanged;

        public bool IsRunning { get; private set; }

        public void Start()
        {
            if (IsRunning) return;
            IsRunning = true;
            _hasFailed = false;
            _saidNothing = false;
            _lastLevels = DateTime.UtcNow;
            _silence.Start();
            Begin();
        }

        public void Stop()
        {
            if (!IsRunning) return;
            IsRunning = false;
            _silence.Stop();
            End();
        }

        private void Begin()
        {
            try
            {
                using (var enumerator = new MMDeviceEnumerator())
                {
                    if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
                    {
                        Fail(null);
                        return;
                    }
                    _device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                }
                _deviceId = _device.ID;

                _capture = new WasapiLoopbackCapture(_device);
                if (_capture.WaveFormat.Encoding != WaveFormatEncoding.IeeeFloat || _capture.WaveFormat.BitsPerSample != 32)
                {
                    Fail(null);
                    return;
                }

                _bands = new SpectrumBands(_capture.WaveFormat.SampleRate);
                _capture.DataAvailable += OnData;
                _capture.RecordingStopped += OnStopped;
                _capture.StartRecording();
            }
            catch (Exception e)
            {
                Fail(e);
            }
        }

        private void End()
        {
            WasapiLoopbackCapture capture = _capture;
            MMDevice device = _device;
            _capture = null;
            _device = null;
            _bands = null;
            Interlocked.Exchange(ref _waiting, null);

            if (capture != null)
            {
                capture.DataAvailable -= OnData;
                capture.RecordingStopped -= OnStopped;
                try
                {
                    // Waits for its thread, which ends within a few hundredths of a second
                    capture.Dispose();
                }
                catch (Exception e)
                {
                    Report(e);
                }
            }
            if (device != null)
            {
                try
                {
                    // A capture only took an audio client from it, so there's nothing a finalizer could trip over
                    device.Dispose();
                }
                catch (Exception e)
                {
                    GC.SuppressFinalize(device);
                    Report(e);
                }
            }
        }

        private void Fail(Exception e)
        {
            _hasFailed = true;
            if (e != null) Report(e);
            End();
            SayNothing();
        }

        // On the capture's own thread
        private void OnData(object sender, WaveInEventArgs e)
        {
            WasapiLoopbackCapture capture = sender as WasapiLoopbackCapture;
            SpectrumBands bands = _bands;
            if (capture == null || bands == null || e.BytesRecorded <= 0) return;

            double[] levels = bands.Feed(e.Buffer, e.BytesRecorded, capture.WaveFormat.Channels);
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

        private void OnStopped(object sender, StoppedEventArgs e)
        {
            // WasapiCapture posts this where it was made, but a dispatcher in between costs nothing if not
            _ui.BeginInvoke(new Action(() =>
            {
                if (!IsRunning || !ReferenceEquals(sender, _capture)) return;
                if (!RestartIfOutputChanged())
                {
                    Fail(e.Exception);
                }
            }));
        }

        private void CheckSilence()
        {
            if (!IsRunning || _hasFailed) return;
            if (DateTime.UtcNow - _lastLevels <= SilenceBeforeGivingUp) return;

            // Sound moved to another output leaves this one silent, and the capture has to follow it there
            SayNothing();
            RestartIfOutputChanged();
        }

        /// <summary>True if the output is a new one, and listening went over to it.</summary>
        private bool RestartIfOutputChanged()
        {
            string current = CurrentOutputId();
            if (current == null || current == _deviceId) return false;

            End();
            _lastLevels = DateTime.UtcNow;
            Begin();
            return true;
        }

        private string CurrentOutputId()
        {
            try
            {
                using (var enumerator = new MMDeviceEnumerator())
                {
                    if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)) return null;
                    using (MMDevice device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
                    {
                        return device.ID;
                    }
                }
            }
            catch (Exception e)
            {
                Report(e);
                return null;
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
