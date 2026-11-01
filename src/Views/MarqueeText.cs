using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace BoringNotch
{
    /// <summary>
    /// A line that stands still if it fits and otherwise runs by, with a second copy following so the loop has no seam.
    /// Nothing runs while it can't be seen.
    /// </summary>
    internal sealed class MarqueeText : Canvas
    {
        private const double Gap = 20;
        private const double PointsPerSecond = 30;
        private const double PauseSeconds = 1;

        private readonly TextBlock _first;
        private readonly TextBlock _second;
        private readonly StackPanel _line;
        private readonly TranslateTransform _offset = new TranslateTransform();

        private string _text = "";
        private double _runningWidth;

        public MarqueeText(double size, FontWeight weight)
        {
            ClipToBounds = true;
            IsHitTestVisible = false;

            _first = MakeBlock(size, weight);
            _second = MakeBlock(size, weight);
            _second.Margin = new Thickness(Gap, 0, 0, 0);
            _second.Visibility = Visibility.Collapsed;

            _line = new StackPanel { Orientation = Orientation.Horizontal, RenderTransform = _offset };
            _line.Children.Add(_first);
            _line.Children.Add(_second);
            Children.Add(_line);

            // A canvas asks nothing of its children, so the height of a line has to be set here
            _first.Text = "Ag";
            _first.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Height = Math.Ceiling(_first.DesiredSize.Height);
            _first.Text = "";

            SizeChanged += (sender, e) => Restart();
            IsVisibleChanged += (sender, e) => Restart();
        }

        public string Text
        {
            get => _text;
            set
            {
                string text = value ?? "";
                if (text == _text) return;
                _text = text;
                _first.Text = text;
                _second.Text = text;
                _runningWidth = 0;
                Restart();
            }
        }

        public Brush Foreground
        {
            get => _first.Foreground;
            set
            {
                _first.Foreground = value;
                _second.Foreground = value;
            }
        }

        private static TextBlock MakeBlock(double size, FontWeight weight)
        {
            return new TextBlock
            {
                FontFamily = Theme.Font,
                FontSize = size,
                FontWeight = weight,
                Foreground = Theme.White,
                IsHitTestVisible = false,
            };
        }

        private void Restart()
        {
            _first.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double width = _first.DesiredSize.Width;
            bool runs = IsVisible && ActualWidth > 0 && width > ActualWidth + 0.5;

            if (!runs)
            {
                _runningWidth = 0;
                _offset.BeginAnimation(TranslateTransform.XProperty, null);
                _offset.X = 0;
                _second.Visibility = Visibility.Collapsed;
                return;
            }

            // Already running for this text: a new width of the frame doesn't need a jump back to the start
            if (_runningWidth == width) return;
            _runningWidth = width;

            _second.Visibility = Visibility.Visible;
            double distance = width + Gap;
            TimeSpan pause = TimeSpan.FromSeconds(PauseSeconds);
            TimeSpan end = pause + TimeSpan.FromSeconds(width / PointsPerSecond);

            var run = new DoubleAnimationUsingKeyFrames { Duration = end, RepeatBehavior = RepeatBehavior.Forever };
            run.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            run.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(pause)));
            run.KeyFrames.Add(new LinearDoubleKeyFrame(-distance, KeyTime.FromTimeSpan(end)));
            _offset.BeginAnimation(TranslateTransform.XProperty, run);
        }
    }
}
