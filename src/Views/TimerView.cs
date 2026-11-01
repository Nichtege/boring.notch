using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using BoringNotch.Core;

namespace BoringNotch
{
    /// <summary>The Timer tab, the Mac's Focus tab: a big clock and the session lengths to start from.</summary>
    internal sealed class TimerView : Grid
    {
        private const double ClockWidth = 190;
        private const double ProgressHeight = 4;
        private const double PillIconSize = 12;
        private static readonly int[] SessionLengths = { 25, 45, 60 };

        private readonly FocusClock _clock;
        private readonly Action _changed;
        private readonly TextBlock _time;
        private readonly Border _progress;
        private readonly StackPanel _starts;
        private readonly FrameworkElement _stop;

        public TimerView(FocusClock clock, Action changed)
        {
            _clock = clock;
            _changed = changed;
            Background = Brushes.Transparent;

            _time = Theme.Text("0:00", 52, Theme.Gray, FontWeights.SemiBold);
            Typography.SetNumeralAlignment(_time, FontNumeralAlignment.Tabular);

            _progress = new Border
            {
                Width = 0,
                CornerRadius = new CornerRadius(ProgressHeight / 2),
                Background = Theme.Orange,
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            var progressTrack = new Grid { Height = ProgressHeight, Margin = new Thickness(0, 8, 0, 0) };
            progressTrack.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(ProgressHeight / 2),
                Background = Theme.Track,
            });
            progressTrack.Children.Add(_progress);

            var clockColumn = new StackPanel { Width = ClockWidth, VerticalAlignment = VerticalAlignment.Center };
            clockColumn.Children.Add(_time);
            clockColumn.Children.Add(progressTrack);

            _starts = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (int minutes in SessionLengths)
            {
                FrameworkElement pill = MakePill(
                    minutes + " min",
                    new GlyphIcon(Icons.Timer, PillIconSize, Theme.White),
                    () => Start(minutes));
                if (_starts.Children.Count > 0)
                {
                    pill.Margin = new Thickness(8, 0, 0, 0);
                }
                _starts.Children.Add(pill);
            }

            _stop = MakePill("Stop", new GlyphIcon(Icons.Stop, PillIconSize, Theme.White, filled: true), Stop);
            _stop.HorizontalAlignment = HorizontalAlignment.Left;

            var buttonColumn = new Grid { Margin = new Thickness(28, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            buttonColumn.Children.Add(_starts);
            buttonColumn.Children.Add(_stop);

            var content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            content.Children.Add(clockColumn);
            content.Children.Add(buttonColumn);
            Children.Add(content);

            Update();
        }

        /// <summary>Shows where the session is now. The notch window calls it every second while one runs.</summary>
        public void Update()
        {
            DateTime now = DateTime.UtcNow;
            bool isRunning = _clock.IsRunning;

            _time.Text = _clock.ClockText(now);
            _time.Foreground = isRunning ? Theme.White : Theme.Gray;
            _progress.Width = ClockWidth * _clock.Progress(now);
            _starts.Visibility = isRunning ? Visibility.Collapsed : Visibility.Visible;
            _stop.Visibility = isRunning ? Visibility.Visible : Visibility.Collapsed;
        }

        private void Start(int minutes)
        {
            _clock.Start(DateTime.UtcNow, minutes * 60);
            Update();
            _changed?.Invoke();
        }

        private void Stop()
        {
            _clock.Stop();
            Update();
            _changed?.Invoke();
        }

        private static FrameworkElement MakePill(string title, UIElement icon, Action action)
        {
            var label = Theme.Text(title, 12, Theme.White, FontWeights.SemiBold);
            label.Margin = new Thickness(5, 0, 0, 0);
            label.VerticalAlignment = VerticalAlignment.Center;

            var row = new StackPanel { Orientation = Orientation.Horizontal, IsHitTestVisible = false };
            row.Children.Add(icon);
            row.Children.Add(label);

            var pill = new Border
            {
                CornerRadius = new CornerRadius(14),
                Background = Theme.Pill,
                Padding = new Thickness(10, 6, 10, 6),
                Child = row,
            };
            Press.OnClick(pill, action);
            return pill;
        }
    }
}
