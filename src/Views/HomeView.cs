using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using BoringNotch.Core;

namespace BoringNotch
{
    /// <summary>
    /// The music tab, the Mac's player: the cover with its glow, what plays, the time, the buttons, the volume of the
    /// app that plays, and where the sound comes out. Only looks after itself while it's on screen.
    /// </summary>
    internal sealed class HomeView : Grid
    {
        private const double ArtBox = 138;
        private const double ArtSize = 128;
        private const double ArtRadius = 13;
        private const double GlowOpacity = 0.5;
        private const double PausedScale = 0.85;
        private const double PausedCover = 0.55;
        private const double ColumnGap = 8;
        private const double SmallButton = 30;
        private const double LargeButton = 40;
        private const double SmallGlyph = 15;
        private const double LargeGlyph = 26;
        private const double ButtonGap = 6;
        private const double DisabledOpacity = 0.35;
        private const double PickerRowHeight = 24;
        private const double OutputMaxWidth = 84;
        private const int OutputRefreshEverySeconds = 3;
        private const double SeekWaitSeconds = 3;
        private const double SeekNewsToleranceSeconds = 1;
        private static readonly TimeSpan StateChange = TimeSpan.FromMilliseconds(300);
        private static readonly TimeSpan HoverChange = TimeSpan.FromMilliseconds(300);
        private static readonly Brush ArtBackground = Theme.Solid(0xFF, 0x1C, 0x1C, 0x1E);
        private static readonly Brush HoverCircle = Theme.Solid(0x33, 0x8E, 0x8E, 0x93);
        private static readonly Brush PickerEdge = Theme.Solid(0x1F, 0xFF, 0xFF, 0xFF);

        private readonly MediaSessions _media;
        private readonly AudioMixer _mixer;

        private readonly Image _glow;
        private readonly Grid _art;
        private readonly ScaleTransform _artScale = new ScaleTransform(PausedScale, PausedScale);
        private readonly Image _cover;
        private readonly GlyphIcon _noCover;
        private readonly Rectangle _pausedCover;

        private readonly MarqueeText _title = new MarqueeText(13, FontWeights.SemiBold);
        private readonly MarqueeText _artist = new MarqueeText(13, FontWeights.Medium);
        private readonly NotchSlider _time;
        private readonly TextBlock _elapsed;
        private readonly TextBlock _total;

        private readonly NotchSlider _volume;
        private readonly FrameworkElement _volumeRow;
        private readonly GlyphIcon[] _speakers;

        private readonly FrameworkElement _previous;
        private readonly FrameworkElement _playPause;
        private readonly FrameworkElement _next;
        private readonly GlyphIcon _playIcon;
        private readonly GlyphIcon _pauseIcon;

        private readonly FrameworkElement _outputButton;
        private readonly GlyphIcon _outputSpeaker;
        private readonly GlyphIcon _outputHeadphones;
        private readonly GlyphIcon _outputMonitor;
        private readonly TextBlock _outputName;

        private readonly Grid _pickerScrim;
        private readonly Border _pickerCard;
        private readonly StackPanel _pickerRows = new StackPanel();

        private readonly DispatcherTimer _progressTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        private readonly DispatcherTimer _secondTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };

        private bool _isShown;
        private bool? _shownPlaying;
        private Color? _shownTint;
        private string _volumeApp;
        private int _secondsSinceOutputRefresh;
        private DateTime _lastSeek = DateTime.MinValue;

        public HomeView(MediaSessions media, AudioMixer mixer)
        {
            _media = media;
            _mixer = mixer;
            Background = Brushes.Transparent;

            // The art
            _glow = new Image
            {
                Width = ArtSize,
                Height = ArtSize,
                Stretch = Stretch.UniformToFill,
                Opacity = 0,
                IsHitTestVisible = false,
                RenderTransformOrigin = new Point(0.5, 0.5),
                Effect = new BlurEffect { Radius = 60, RenderingBias = RenderingBias.Performance },
            };
            var glowTransform = new TransformGroup();
            glowTransform.Children.Add(new ScaleTransform(1.3, 1.4));
            glowTransform.Children.Add(new RotateTransform(92));
            _glow.RenderTransform = glowTransform;
            RenderOptions.SetBitmapScalingMode(_glow, BitmapScalingMode.LowQuality);

            _cover = new Image { Stretch = Stretch.UniformToFill, IsHitTestVisible = false };
            RenderOptions.SetBitmapScalingMode(_cover, BitmapScalingMode.HighQuality);
            _noCover = new GlyphIcon(Icons.Note, 44, Theme.Gray, thickness: 1.2)
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            _pausedCover = new Rectangle { Fill = Theme.Black, Opacity = 0, IsHitTestVisible = false };

            _art = new Grid
            {
                Width = ArtSize,
                Height = ArtSize,
                Background = ArtBackground,
                IsHitTestVisible = false,
                RenderTransform = _artScale,
                RenderTransformOrigin = new Point(0.5, 0.5),
                Clip = new RectangleGeometry(new Rect(0, 0, ArtSize, ArtSize), ArtRadius, ArtRadius),
            };
            _art.Children.Add(_noCover);
            _art.Children.Add(_cover);
            _art.Children.Add(_pausedCover);

            var artBox = new Grid { Width = ArtBox, Height = ArtBox, IsHitTestVisible = false };
            artBox.Children.Add(_glow);
            artBox.Children.Add(_art);

            // What plays and how far it is
            _time = new NotchSlider { Height = 10, Margin = new Thickness(0, 9, 0, 0) };
            _time.ValueChanged += value => ShowDraggedTime(value);
            _time.DragEnded += FinishSeek;

            _elapsed = MakeTimeLabel(TextAlignment.Left);
            _total = MakeTimeLabel(TextAlignment.Right);
            var times = new Grid { Margin = new Thickness(0, 6, 0, 0) };
            times.Children.Add(_elapsed);
            times.Children.Add(_total);

            var info = new StackPanel { Margin = new Thickness(5, 10, 0, 0) };
            info.Children.Add(_title);
            info.Children.Add(_artist);
            info.Children.Add(_time);
            info.Children.Add(times);

            // The row of buttons
            _speakers = new[]
            {
                new GlyphIcon(Icons.SpeakerMute, 14, Theme.White),
                new GlyphIcon(Icons.SpeakerLow, 14, Theme.White),
                new GlyphIcon(Icons.SpeakerMedium, 14, Theme.White),
                new GlyphIcon(Icons.Speaker, 14, Theme.White),
            };
            _volume = new NotchSlider { Width = 80, Height = 10, VerticalAlignment = VerticalAlignment.Center };
            _volume.ValueChanged += SetVolume;
            _volumeRow = MakeVolumeRow();

            _previous = MakeButton(new GlyphIcon(Icons.Previous, SmallGlyph, Theme.White, filled: true, thickness: 1), null, SmallButton, () => _media.Previous());
            _playIcon = new GlyphIcon(Icons.Play, LargeGlyph, Theme.White, filled: true, thickness: 1);
            _pauseIcon = new GlyphIcon(Icons.Pause, LargeGlyph, Theme.White, filled: true, thickness: 1);
            _playPause = MakeButton(_playIcon, _pauseIcon, LargeButton, () => _media.TogglePlayPause());
            _next = MakeButton(new GlyphIcon(Icons.Next, SmallGlyph, Theme.White, filled: true, thickness: 1), null, SmallButton, () => _media.Next());
            _playPause.Margin = new Thickness(ButtonGap, 0, ButtonGap, 0);

            var transport = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            transport.Children.Add(_previous);
            transport.Children.Add(_playPause);
            transport.Children.Add(_next);

            _outputSpeaker = new GlyphIcon(Icons.Speaker, 13, Theme.Gray);
            _outputHeadphones = new GlyphIcon(Icons.Headphones, 13, Theme.Gray);
            _outputMonitor = new GlyphIcon(Icons.Monitor, 13, Theme.Gray);
            _outputName = Theme.Text("", 11, Theme.Gray);
            _outputButton = MakeOutputButton();

            // Both sides take what's left, so the middle stays in the middle
            var toolbar = new Grid { Height = LargeButton };
            toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            SetColumn(_volumeRow, 0);
            SetColumn(transport, 1);
            SetColumn(_outputButton, 2);
            toolbar.Children.Add(_volumeRow);
            toolbar.Children.Add(transport);
            toolbar.Children.Add(_outputButton);

            var controls = new Grid();
            controls.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            controls.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            SetRow(info, 0);
            SetRow(toolbar, 1);
            controls.Children.Add(info);
            controls.Children.Add(toolbar);

            var content = new Grid();
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ArtBox) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ColumnGap) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            SetColumn(artBox, 0);
            SetColumn(controls, 2);
            content.Children.Add(artBox);
            content.Children.Add(controls);
            Children.Add(content);

            // The list of outputs lies on top of all this, and a click beside it closes it
            _pickerScrim = new Grid { Background = Brushes.Transparent, Visibility = Visibility.Collapsed };
            _pickerScrim.MouseLeftButtonDown += (sender, e) =>
            {
                ClosePicker();
                e.Handled = true;
            };
            Children.Add(_pickerScrim);

            _pickerCard = MakePickerCard();
            Children.Add(_pickerCard);

            _progressTimer.Tick += (sender, e) => UpdateProgress();
            _secondTimer.Tick += (sender, e) => SecondPassed();

            Update();
        }

        public bool IsPickerOpen => _pickerCard.Visibility == Visibility.Visible;

        /// <summary>Only looked after while the tab is on screen.</summary>
        public void Shown()
        {
            if (_isShown) return;
            _isShown = true;
            _media.Changed += MediaChanged;
            _secondsSinceOutputRefresh = 0;
            UpdateVolume(true);
            RefreshOutput();
            _secondTimer.Start();
            Update();
        }

        public void Hidden()
        {
            ClosePicker();
            if (!_isShown) return;
            _isShown = false;
            _media.Changed -= MediaChanged;
            _progressTimer.Stop();
            _secondTimer.Stop();
        }

        /// <summary>Shows what plays now.</summary>
        public void Update()
        {
            NowPlaying now = _media.Current;
            bool isPlaying = now != null && now.IsPlaying;

            _title.Foreground = now != null ? Theme.White : Theme.Gray;
            _title.Text = now == null ? "Es läuft nichts" : string.IsNullOrWhiteSpace(now.Title) ? "Unbekannter Titel" : now.Title;
            _artist.Text = now?.Artist ?? "";

            // A session without a cover has no color of its own, and see-through text would be gone
            ShowTint(now != null && now.Tint.A > 0 ? now.Tint : Colors.Gray);
            ShowArt(now?.Art);
            ShowPlaying(isPlaying);

            SetEnabled(_previous, now != null && now.CanPrevious);
            SetEnabled(_next, now != null && now.CanNext);
            SetEnabled(_playPause, now != null && now.CanPlayPause);
            _playIcon.Visibility = isPlaying ? Visibility.Collapsed : Visibility.Visible;
            _pauseIcon.Visibility = isPlaying ? Visibility.Visible : Visibility.Collapsed;

            _time.IsHitTestVisible = now != null && now.CanSeek && now.Duration > 0;
            UpdateProgress();

            if (isPlaying && _isShown) _progressTimer.Start();
            else _progressTimer.Stop();
        }

        private void MediaChanged()
        {
            // News of a session can come from any thread
            if (Dispatcher.CheckAccess()) Update();
            else Dispatcher.BeginInvoke(new Action(Update));
        }

        // MARK: - The art

        private void ShowArt(ImageSource art)
        {
            if (!ReferenceEquals(_cover.Source, art))
            {
                _cover.Source = art;
                _glow.Source = art;
            }
            _noCover.Visibility = art == null ? Visibility.Visible : Visibility.Collapsed;
            // Only a cover needs dimming, and the note on the empty one would almost disappear
            _pausedCover.Visibility = art == null ? Visibility.Collapsed : Visibility.Visible;
        }

        private void ShowPlaying(bool isPlaying)
        {
            if (_shownPlaying == isPlaying) return;
            _shownPlaying = isPlaying;

            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            double scale = isPlaying ? 1 : PausedScale;
            _artScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(scale, StateChange) { EasingFunction = ease });
            _artScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(scale, StateChange) { EasingFunction = ease });
            _glow.BeginAnimation(OpacityProperty, new DoubleAnimation(isPlaying ? GlowOpacity : 0, StateChange));
            _pausedCover.BeginAnimation(OpacityProperty, new DoubleAnimation(isPlaying ? 0 : PausedCover, StateChange));
        }

        private void ShowTint(Color tint)
        {
            if (_shownTint == tint) return;
            _shownTint = tint;

            Rgb readable = ColorMath.EnsureMinimumBrightness(new Rgb(tint.R, tint.G, tint.B), 0.6);
            var brush = new SolidColorBrush(Color.FromRgb(readable.R, readable.G, readable.B));
            brush.Freeze();
            _artist.Foreground = brush;
            _elapsed.Foreground = brush;
            _total.Foreground = brush;
        }

        // MARK: - The time

        private static TextBlock MakeTimeLabel(TextAlignment alignment)
        {
            TextBlock label = Theme.Text("", 11, Theme.Gray, FontWeights.Medium);
            label.TextAlignment = alignment;
            Typography.SetNumeralAlignment(label, FontNumeralAlignment.Tabular);
            return label;
        }

        private void UpdateProgress()
        {
            NowPlaying now = _media.Current;
            if (now == null || now.Duration <= 0)
            {
                if (!_time.IsDragging) _time.Value = 0;
                _elapsed.Text = "";
                _total.Text = "";
                return;
            }

            _total.Text = PlaybackMath.TimeText(now.Duration);
            if (_time.IsDragging) return;

            // After a seek it waits for news of it, but not for good: that news may never come
            DateTime utc = DateTime.UtcNow;
            bool hasNews = (now.ElapsedAtUtc - _lastSeek).TotalSeconds > -SeekNewsToleranceSeconds;
            bool waitedEnough = (utc - _lastSeek).TotalSeconds > SeekWaitSeconds;
            if (!hasNews && !waitedEnough) return;

            double position = PlaybackMath.Estimated(now.Elapsed, now.Duration, now.IsPlaying, now.Rate, now.ElapsedAtUtc, utc);
            _time.Value = position / now.Duration;
            _elapsed.Text = PlaybackMath.TimeText(position);
        }

        private void ShowDraggedTime(double share)
        {
            NowPlaying now = _media.Current;
            if (now == null || now.Duration <= 0) return;
            _elapsed.Text = PlaybackMath.TimeText(share * now.Duration);
        }

        private void FinishSeek()
        {
            NowPlaying now = _media.Current;
            if (now == null || now.Duration <= 0) return;
            _lastSeek = DateTime.UtcNow;
            _media.Seek(_time.Value * now.Duration);
        }

        // MARK: - The buttons

        private FrameworkElement MakeButton(GlyphIcon icon, GlyphIcon otherIcon, double size, Action action)
        {
            var circle = new Ellipse { Fill = HoverCircle, Opacity = 0, IsHitTestVisible = false };
            var button = new Grid { Width = size, Height = size, Background = Brushes.Transparent };
            button.Children.Add(circle);
            foreach (GlyphIcon glyph in new[] { icon, otherIcon })
            {
                if (glyph == null) continue;
                glyph.HorizontalAlignment = HorizontalAlignment.Center;
                glyph.VerticalAlignment = VerticalAlignment.Center;
                button.Children.Add(glyph);
            }
            button.MouseEnter += (sender, e) => circle.BeginAnimation(OpacityProperty, new DoubleAnimation(1, HoverChange));
            button.MouseLeave += (sender, e) => circle.BeginAnimation(OpacityProperty, new DoubleAnimation(0, HoverChange));
            Press.OnClick(button, action);
            return button;
        }

        private static void SetEnabled(FrameworkElement button, bool enabled)
        {
            button.IsHitTestVisible = enabled;
            button.Opacity = enabled ? 1 : DisabledOpacity;
        }

        // MARK: - The volume

        private FrameworkElement MakeVolumeRow()
        {
            var icons = new Grid { Width = 24, Height = 14, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
            foreach (GlyphIcon speaker in _speakers)
            {
                speaker.HorizontalAlignment = HorizontalAlignment.Center;
                speaker.Visibility = Visibility.Collapsed;
                icons.Children.Add(speaker);
            }

            _volume.Margin = new Thickness(4, 0, 0, 0);
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Center,
            };
            row.Children.Add(icons);
            row.Children.Add(_volume);
            return row;
        }

        private void SecondPassed()
        {
            UpdateVolume(true);
            _secondsSinceOutputRefresh++;
            if (_secondsSinceOutputRefresh >= OutputRefreshEverySeconds)
            {
                _secondsSinceOutputRefresh = 0;
                RefreshOutput();
            }
        }

        private void UpdateVolume(bool refresh)
        {
            if (refresh) _mixer.Refresh();

            // A finger on the slider knows better, and it should stay with the app it started on
            if (_volume.IsDragging) return;

            NowPlaying now = _media.Current;
            _volumeApp = string.IsNullOrEmpty(now?.AppId) ? null : _mixer.FindApp(now.AppId);

            bool available = _volumeApp != null || _mixer.HasMaster;
            _volumeRow.IsHitTestVisible = available;
            _volumeRow.Opacity = available ? 1 : DisabledOpacity;

            _volume.Value = _volumeApp != null ? _mixer.VolumeOf(_volumeApp) : _mixer.MasterVolume;
            ShowSpeaker(_volume.Value);
        }

        private void SetVolume(double volume)
        {
            if (_volumeApp != null) _mixer.SetAppVolume(_volumeApp, volume);
            else _mixer.SetMasterVolume(volume);
            ShowSpeaker(volume);
        }

        private void ShowSpeaker(double volume)
        {
            int level = volume <= 0 ? 0 : volume < 0.33 ? 1 : volume < 0.66 ? 2 : 3;
            for (int i = 0; i < _speakers.Length; i++)
            {
                _speakers[i].Visibility = i == level ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        // MARK: - Where the sound comes out

        private FrameworkElement MakeOutputButton()
        {
            var icons = new Grid { Width = 13, Height = 13, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
            icons.Children.Add(_outputSpeaker);
            icons.Children.Add(_outputHeadphones);
            icons.Children.Add(_outputMonitor);

            _outputName.Margin = new Thickness(4, 0, 0, 0);
            _outputName.VerticalAlignment = VerticalAlignment.Center;

            var row = new DockPanel { LastChildFill = true, HorizontalAlignment = HorizontalAlignment.Right, IsHitTestVisible = false };
            DockPanel.SetDock(icons, Dock.Left);
            row.Children.Add(icons);
            row.Children.Add(_outputName);

            var button = new Grid
            {
                Height = SmallButton,
                MaxWidth = OutputMaxWidth,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                Background = Brushes.Transparent,
                ToolTip = "Ausgabe wählen",
            };
            button.Children.Add(row);
            Press.OnClick(button, OpenPicker);
            return button;
        }

        private void RefreshOutput()
        {
            OutputDevice current = OutputDevices.List().FirstOrDefault(device => device.IsCurrent);
            _outputButton.Visibility = current == null ? Visibility.Hidden : Visibility.Visible;
            if (current == null) return;

            _outputName.Text = ShortName(current.Name);
            GlyphIcon icon = IconOf(current.Name);
            _outputSpeaker.Visibility = icon == _outputSpeaker ? Visibility.Visible : Visibility.Collapsed;
            _outputHeadphones.Visibility = icon == _outputHeadphones ? Visibility.Visible : Visibility.Collapsed;
            _outputMonitor.Visibility = icon == _outputMonitor ? Visibility.Visible : Visibility.Collapsed;
        }

        private GlyphIcon IconOf(string name)
        {
            switch (KindOf(name))
            {
                case Icons.Headphones: return _outputHeadphones;
                case Icons.Monitor: return _outputMonitor;
                default: return _outputSpeaker;
            }
        }

        /// <summary>Windows only gives a name, so that's all there is to go by.</summary>
        private static string KindOf(string name)
        {
            string lower = (name ?? "").ToLowerInvariant();
            string[] headphones = { "kopfh", "headphone", "headset", "airpods", "earbuds", "buds", "ohrh" };
            string[] monitors = { "hdmi", "monitor", "display", "displayport", "fernseher" };
            if (headphones.Any(lower.Contains)) return Icons.Headphones;
            if (monitors.Any(lower.Contains) || lower.Contains(" tv")) return Icons.Monitor;
            return Icons.Speaker;
        }

        /// <summary>"Lautsprecher (Realtek Audio)" is a lot for the little space, and the list has the whole name.</summary>
        private static string ShortName(string name)
        {
            if (string.IsNullOrEmpty(name)) return "";
            int bracket = name.IndexOf(" (", StringComparison.Ordinal);
            return bracket > 0 ? name.Substring(0, bracket) : name;
        }

        private Border MakePickerCard()
        {
            var scroller = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Focusable = false,
                Content = _pickerRows,
            };
            return new Border
            {
                Background = ArtBackground,
                BorderBrush = PickerEdge,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(6),
                Margin = new Thickness(0, 2, 0, 2),
                MaxWidth = 420,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Bottom,
                Visibility = Visibility.Collapsed,
                Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 16, ShadowDepth = 2, Direction = 270, Opacity = 0.5 },
                Child = scroller,
            };
        }

        private void OpenPicker()
        {
            _pickerRows.Children.Clear();
            foreach (OutputDevice device in OutputDevices.List())
            {
                _pickerRows.Children.Add(MakePickerRow(device));
            }
            if (_pickerRows.Children.Count == 0) return;

            _pickerScrim.Visibility = Visibility.Visible;
            _pickerCard.Visibility = Visibility.Visible;
        }

        private void ClosePicker()
        {
            _pickerScrim.Visibility = Visibility.Collapsed;
            _pickerCard.Visibility = Visibility.Collapsed;
        }

        private FrameworkElement MakePickerRow(OutputDevice device)
        {
            var icon = new GlyphIcon(KindOf(device.Name), 13, Theme.White)
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            TextBlock name = Theme.Text(device.Name, 12, Theme.White);
            name.VerticalAlignment = VerticalAlignment.Center;
            var check = new GlyphIcon(Icons.Check, 12, Theme.White)
            {
                VerticalAlignment = VerticalAlignment.Center,
                Visibility = device.IsCurrent ? Visibility.Visible : Visibility.Hidden,
            };

            var grid = new Grid { IsHitTestVisible = false };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            SetColumn(icon, 0);
            SetColumn(name, 2);
            SetColumn(check, 4);
            grid.Children.Add(icon);
            grid.Children.Add(name);
            grid.Children.Add(check);

            var row = new Border
            {
                Height = PickerRowHeight,
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(8, 0, 8, 0),
                Background = Brushes.Transparent,
                Child = grid,
            };
            row.MouseEnter += (sender, e) => row.Background = Theme.Hover;
            row.MouseLeave += (sender, e) => row.Background = Brushes.Transparent;

            string id = device.Id;
            Press.OnClick(row, () =>
            {
                ClosePicker();
                // If it fails, the old name stays, as that's still where the sound comes out
                OutputDevices.Select(id);
                RefreshOutput();
                UpdateVolume(true);
            });
            return row;
        }
    }
}
