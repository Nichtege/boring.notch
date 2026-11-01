using System;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace BoringNotch
{
    /// <summary>
    /// The graph to the right of the closed notch: four bars that follow the real levels of what plays. Without any
    /// they go up and down at random, as on the Mac. Nothing runs and nothing listens while it can't be seen or nothing plays.
    /// </summary>
    internal sealed class MusicBars : Canvas
    {
        private const int BarCount = 4;
        private const double BarWidth = 2;
        private const double BarSpacing = 2;
        private const double BarHeight = 14;
        private const double FrameWidth = 16;
        private const double FrameHeight = 12;
        private const double RestScale = 0.35;
        private const double LowestLiveScale = 0.2;
        private static readonly TimeSpan LiveSmoothing = TimeSpan.FromMilliseconds(60);
        private static readonly TimeSpan RandomStep = TimeSpan.FromMilliseconds(300);

        private readonly AudioLevels _levels;
        private readonly Rectangle[] _bars = new Rectangle[BarCount];
        private readonly ScaleTransform[] _scales = new ScaleTransform[BarCount];
        private readonly Random _random = new Random();
        private readonly DispatcherTimer _randomTimer = new DispatcherTimer { Interval = RandomStep };

        private bool _isPlaying;
        private bool _isVisible;
        private bool _isListening;
        private bool _isLive;

        // Levels may come from the capture thread, faster than they can be drawn: only the newest counts
        private double[] _waitingLevels;
        private int _isDeliveryScheduled;

        public MusicBars(AudioLevels levels)
        {
            _levels = levels;
            Width = FrameWidth;
            Height = FrameHeight;
            ClipToBounds = true;
            IsHitTestVisible = false;

            for (int i = 0; i < BarCount; i++)
            {
                var scale = new ScaleTransform(1, RestScale);
                var bar = new Rectangle
                {
                    Width = BarWidth,
                    Height = BarHeight,
                    RadiusX = BarWidth / 2,
                    RadiusY = BarWidth / 2,
                    RenderTransform = scale,
                    RenderTransformOrigin = new Point(0.5, 0.5),
                };
                SetLeft(bar, i * (BarWidth + BarSpacing));
                SetTop(bar, (FrameHeight - BarHeight) / 2);
                Children.Add(bar);
                _bars[i] = bar;
                _scales[i] = scale;
            }

            SetTint(Colors.White);
            _randomTimer.Tick += (sender, e) => MoveAtRandom();
        }

        public void SetPlaying(bool playing)
        {
            if (playing == _isPlaying) return;
            _isPlaying = playing;
            Apply();
        }

        public void SetVisible(bool visible)
        {
            if (visible == _isVisible) return;
            _isVisible = visible;
            Apply();
        }

        /// <summary>A soft fall from a little lighter at the top, like Color.gradient on the Mac.</summary>
        public void SetTint(Color color)
        {
            Color lighter = Color.FromArgb(
                color.A,
                (byte)Math.Min(255, color.R + (255 - color.R) / 4),
                (byte)Math.Min(255, color.G + (255 - color.G) / 4),
                (byte)Math.Min(255, color.B + (255 - color.B) / 4));
            var brush = new LinearGradientBrush(lighter, color, 90);
            brush.Freeze();
            foreach (Rectangle bar in _bars)
            {
                bar.Fill = brush;
            }
        }

        private void Apply()
        {
            bool runs = _isPlaying && _isVisible;
            if (runs)
            {
                StartListening();
                if (!_isLive)
                {
                    MoveAtRandom();
                    _randomTimer.Start();
                }
                return;
            }

            StopListening();
            _randomTimer.Stop();
            _isLive = false;
            Rest();
        }

        private void StartListening()
        {
            if (_isListening || _levels == null) return;
            _isListening = true;
            _levels.LevelsChanged += LevelsArrived;
            _levels.Start();
        }

        private void StopListening()
        {
            if (!_isListening) return;
            _isListening = false;
            _levels.LevelsChanged -= LevelsArrived;
            _levels.Stop();
        }

        private void LevelsArrived(double[] levels)
        {
            _waitingLevels = levels;
            if (Interlocked.Exchange(ref _isDeliveryScheduled, 1) == 0)
            {
                Dispatcher.BeginInvoke(new Action(DeliverLevels));
            }
        }

        private void DeliverLevels()
        {
            Interlocked.Exchange(ref _isDeliveryScheduled, 0);
            if (!_isListening || !_isPlaying || !_isVisible) return;
            Show(_waitingLevels);
        }

        /// <summary>The real levels of the song. Without any, the bars go back to moving at random.</summary>
        private void Show(double[] levels)
        {
            if (levels == null)
            {
                if (!_isLive) return;
                _isLive = false;
                MoveAtRandom();
                _randomTimer.Start();
                return;
            }

            if (!_isLive)
            {
                _isLive = true;
                _randomTimer.Stop();
            }

            int count = Math.Min(BarCount, levels.Length);
            for (int i = 0; i < count; i++)
            {
                double level = Math.Max(0, Math.Min(1, levels[i]));
                MoveTo(i, LowestLiveScale + (1 - LowestLiveScale) * level, LiveSmoothing);
            }
        }

        private void MoveAtRandom()
        {
            for (int i = 0; i < BarCount; i++)
            {
                MoveTo(i, RestScale + _random.NextDouble() * (1 - RestScale), RandomStep);
            }
        }

        private void MoveTo(int bar, double scale, TimeSpan length)
        {
            _scales[bar].BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(scale, length));
        }

        private void Rest()
        {
            foreach (ScaleTransform scale in _scales)
            {
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
                scale.ScaleY = RestScale;
            }
        }
    }
}
