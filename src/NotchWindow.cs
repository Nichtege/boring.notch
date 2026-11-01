using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using BoringNotch.Core;

namespace BoringNotch
{
    internal enum NotchTab
    {
        Shelf,
        Mixer,
        Timer,
    }

    /// <summary>
    /// The notch at the top of the main screen. The window stays one size and never activates. What moves is the
    /// black shape inside it, and clicks pass through everything around that shape, as those pixels are fully clear.
    /// The exception is the shadow of an open or hovered notch: its ring of a few pixels takes clicks and does nothing.
    /// </summary>
    internal sealed class NotchWindow : Window
    {
        // The Mac's sizes
        private const double OpenWidth = 640;
        public const double OpenHeight = 190;
        private const double ClosedBodyWidth = 185;
        private const double ClosedWidth = 193;
        public const double ClosedHeight = 32;
        private const double TimerWidth = 269;
        private const double BannerWidth = 599;
        private const double BannerSideWidth = 190;
        private const double OpenSideInset = 31;
        private const double BodyTop = 40;
        private const double BodyHeight = 138;
        private const double TabWidth = 46;
        private const double TabHeight = 26;

        // Room for the shadow and the springs to overshoot
        private const double Bleed = 24;
        private const double WindowWidth = OpenWidth + 2 * Bleed;
        private const double WindowHeight = OpenHeight + Bleed;

        private const double DragLinger = 0.5;
        private const double BannerSeconds = 3;
        private const int HotKeyId = 1;
        private const uint KeyA = 0x41;

        private readonly ShelfStore _shelf;
        private readonly SearchWindow _search;
        private readonly FocusClock _clock = new FocusClock();
        private readonly HoverMachine _hover = new HoverMachine();
        private readonly Stopwatch _time = Stopwatch.StartNew();

        private readonly Spring _width = new Spring(ClosedWidth);
        private readonly Spring _height = new Spring(ClosedHeight);
        private readonly Spring _topRadius = new Spring(6);
        private readonly Spring _bottomRadius = new Spring(14);

        private readonly Grid _root = new Grid { Width = WindowWidth, Height = WindowHeight, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        private readonly Path _shape = new Path { Fill = Theme.Black };
        private readonly DropShadowEffect _shadow = new DropShadowEffect { Color = Colors.Black, BlurRadius = 12, ShadowDepth = 0, Opacity = 0 };
        private readonly Canvas _clipped = new Canvas { IsHitTestVisible = true };
        private readonly Canvas _openContent = new Canvas { Width = WindowWidth, Height = WindowHeight, Opacity = 0, Visibility = Visibility.Hidden, IsHitTestVisible = false };
        private readonly ScaleTransform _openScale = new ScaleTransform(0.8, 0.8, WindowWidth / 2, 0);
        private readonly Canvas _closedContent = new Canvas { Width = WindowWidth, Height = ClosedHeight, IsHitTestVisible = false };

        private readonly Border _tabCapsule = new Border { Width = TabWidth, Height = TabHeight, CornerRadius = new CornerRadius(TabHeight / 2), Background = Theme.Pill };
        private readonly GlyphIcon[] _tabIcons = new GlyphIcon[3];

        private readonly ShelfView _shelfView;
        private readonly MixerView _mixerView;
        private readonly TimerView _timerView;

        private readonly GlyphIcon _closedTimerIcon = new GlyphIcon(Icons.Timer, 13, Theme.Orange);
        private readonly TextBlock _closedTimerText = Theme.Text("", 11, Theme.Orange, FontWeights.SemiBold);
        private readonly TextBlock _bannerText = Theme.Text("Timer abgelaufen", 12, Theme.White);
        private readonly GlyphIcon _bannerIcon = new GlyphIcon(Icons.Timer, 14, Theme.Orange);

        private readonly DispatcherTimer _mouseTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        private readonly DispatcherTimer _secondTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private readonly DispatcherTimer _fullscreenTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private readonly DispatcherTimer _bannerTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(BannerSeconds) };

        private IntPtr _handle;
        private NotchTab _tab = NotchTab.Shelf;
        private bool _isOpen;
        private bool _isHidden;
        private bool _isHovered;
        private bool _isAnimating;
        private bool _bannerPending;
        private bool _bannerShown;
        private bool _hotKeyRegistered;
        private double _lastFrame;
        private double _lastDrag = double.NegativeInfinity;

        /// <summary>The self test drives the notch itself, and the runner's mouse shouldn't interfere.</summary>
        public bool IgnoresMouse { get; set; }

        public FrameworkElement Root => _root;

        public MixerView MixerViewForTest => _mixerView;

        public FocusClock Clock => _clock;

        public bool IsNotchOpen => _isOpen;

        public bool HotKeyRegistered => _hotKeyRegistered;

        public NotchWindow(ShelfStore shelf, AudioMixer mixer, SearchWindow search)
        {
            _shelf = shelf;
            _search = search;
            _shelfView = new ShelfView(shelf);
            _mixerView = new MixerView(mixer);
            _timerView = new TimerView(_clock, TimerChanged);

            Title = "Boring Notch";
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowInTaskbar = false;
            ShowActivated = false;
            Focusable = false;
            Topmost = true;
            Width = WindowWidth;
            Height = WindowHeight;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = 0;
            Top = 0;
            UseLayoutRounding = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
            RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);

            BuildContent();
            RedrawShape();

            SourceInitialized += OnSourceInitialized;
            // Later, as WPF moves the window itself right after telling about the new scale
            DpiChanged += (sender, e) => Dispatcher.BeginInvoke(new Action(Place));
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (sender, e) =>
                Dispatcher.BeginInvoke(new Action(Place));
            Closed += (sender, e) => Cleanup();

            _mouseTimer.Tick += (sender, e) => CheckMouse();
            _secondTimer.Tick += (sender, e) => SecondPassed();
            _fullscreenTimer.Tick += (sender, e) => CheckFullscreen();
            _bannerTimer.Tick += (sender, e) => BannerOver();
        }

        private double CenterX => WindowWidth / 2;

        private void BuildContent()
        {
            _shape.Effect = _shadow;
            _root.Children.Add(_shape);
            _root.Children.Add(_clipped);

            _openContent.RenderTransform = _openScale;
            _clipped.Children.Add(_openContent);
            _clipped.Children.Add(_closedContent);

            BuildTabs();
            BuildBody();
            BuildClosedContent();

            _shape.MouseLeftButtonDown += (sender, e) =>
            {
                if (!_isOpen && !_isHidden) Open();
            };

            _root.AllowDrop = true;
            _root.DragEnter += OnDragEnter;
            _root.DragOver += OnDragOver;
            _root.DragLeave += OnDragLeave;
            _root.Drop += OnDrop;

            Content = _root;
        }

        private void BuildTabs()
        {
            double left = CenterX - OpenWidth / 2 + OpenSideInset;

            Canvas.SetLeft(_tabCapsule, left);
            Canvas.SetTop(_tabCapsule, 3);
            _openContent.Children.Add(_tabCapsule);

            AddTabButton(left, Icons.Tray, "Ablage", 0, () => ShowTab(NotchTab.Shelf));
            AddTabButton(left + TabWidth, Icons.Sliders, "Mixer", 1, () => ShowTab(NotchTab.Mixer));
            AddTabButton(left + 2 * TabWidth, Icons.Timer, "Timer", 2, () => ShowTab(NotchTab.Timer));
            AddTabButton(left + 3 * TabWidth, Icons.Search, "Windows durchsuchen", -1, OpenSearch);
            UpdateTabColors();
        }

        private void AddTabButton(double x, string glyph, string label, int index, Action action)
        {
            var icon = new GlyphIcon(glyph, 15, Theme.Gray, filled: glyph == Icons.Sliders);
            if (index >= 0) _tabIcons[index] = icon;

            var button = new Grid { Width = TabWidth, Height = TabHeight, Background = Brushes.Transparent, ToolTip = label };
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            icon.VerticalAlignment = VerticalAlignment.Center;
            button.Children.Add(icon);
            Press.OnClick(button, action);

            Canvas.SetLeft(button, x);
            Canvas.SetTop(button, 3);
            _openContent.Children.Add(button);
        }

        private void BuildBody()
        {
            double left = CenterX - OpenWidth / 2 + OpenSideInset;
            double width = OpenWidth - 2 * OpenSideInset;
            foreach (FrameworkElement view in new FrameworkElement[] { _shelfView, _mixerView, _timerView })
            {
                view.Width = width;
                view.Height = BodyHeight;
                Canvas.SetLeft(view, left);
                Canvas.SetTop(view, BodyTop);
                _openContent.Children.Add(view);
            }
            UpdateBodyVisibility();
        }

        private void BuildClosedContent()
        {
            double gap = ClosedBodyWidth / 2;
            Canvas.SetLeft(_closedTimerIcon, CenterX - gap - 22);
            Canvas.SetTop(_closedTimerIcon, (ClosedHeight - 13) / 2);
            _closedContent.Children.Add(_closedTimerIcon);

            Canvas.SetLeft(_closedTimerText, CenterX + gap + 2);
            Canvas.SetTop(_closedTimerText, (ClosedHeight - 15) / 2);
            _closedContent.Children.Add(_closedTimerText);

            _bannerText.Width = BannerSideWidth;
            _bannerText.TextAlignment = TextAlignment.Right;
            Canvas.SetLeft(_bannerText, CenterX - gap - 5 - BannerSideWidth);
            Canvas.SetTop(_bannerText, (ClosedHeight - 16) / 2);
            _closedContent.Children.Add(_bannerText);

            Canvas.SetLeft(_bannerIcon, CenterX + gap + 5);
            Canvas.SetTop(_bannerIcon, (ClosedHeight - 14) / 2);
            _closedContent.Children.Add(_bannerIcon);

            UpdateClosedContent();
        }

        private void OnSourceInitialized(object sender, EventArgs e)
        {
            _handle = new WindowInteropHelper(this).Handle;
            Native.AddExStyle(_handle, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
            Place();

            HwndSource.FromHwnd(_handle).AddHook(WindowMessage);
            _hotKeyRegistered = Native.RegisterHotKey(_handle, HotKeyId, Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT, KeyA);
            if (!_hotKeyRegistered)
            {
                Log.Note("Strg+Alt+A is taken by another app, the search still opens from the notch.");
            }

            _mouseTimer.Start();
            _fullscreenTimer.Start();
        }

        private IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (message == Native.WM_HOTKEY && wParam.ToInt32() == HotKeyId)
            {
                _search.Toggle();
                handled = true;
            }
            return IntPtr.Zero;
        }

        private void Place()
        {
            if (_handle != IntPtr.Zero)
            {
                Native.PlaceTopCenter(_handle, WindowWidth, WindowHeight);
            }
        }

        private void Cleanup()
        {
            _mouseTimer.Stop();
            _secondTimer.Stop();
            _fullscreenTimer.Stop();
            _bannerTimer.Stop();
            if (_hotKeyRegistered)
            {
                Native.UnregisterHotKey(_handle, HotKeyId);
                _hotKeyRegistered = false;
            }
        }

        // MARK: - Open and close

        public void Open()
        {
            if (_isOpen) return;
            _isOpen = true;

            Native.KeepOnTop(_handle);
            ConfigureSprings(0.42, 0.8);
            UpdateTargets();
            UpdateClosedContent();

            _openContent.Visibility = Visibility.Visible;
            _openContent.IsHitTestVisible = true;
            AnimateOpenContent(1, 1);
            ShowBody();

            _search.SetNotchBottom(OpenHeight);
        }

        public void CloseNotch()
        {
            if (!_isOpen) return;
            _isOpen = false;

            ConfigureSprings(0.45, 1.0);
            UpdateTargets();
            _openContent.IsHitTestVisible = false;
            AnimateOpenContent(0, 0.8);
            _mixerView.Hidden();
            ShowBannerIfWaiting();
            UpdateClosedContent();

            _search.SetNotchBottom(ClosedHeight);
        }

        private void OpenSearch()
        {
            // The mouse is still on the notch, and that shouldn't bring it right back
            _hover.MustLeaveFirst();
            CloseNotch();
            _search.Open();
        }

        private void ConfigureSprings(double response, double damping)
        {
            _width.Configure(response, damping);
            _height.Configure(response, damping);
            _topRadius.Configure(response, damping);
            _bottomRadius.Configure(response, damping);
        }

        private void AnimateOpenContent(double opacity, double scale)
        {
            var length = TimeSpan.FromMilliseconds(350);
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            var fade = new DoubleAnimation(opacity, length) { EasingFunction = ease };
            fade.Completed += (sender, e) =>
            {
                if (_isOpen) return;
                _openContent.Visibility = Visibility.Hidden;
                ShowTab(NotchTab.Shelf);
            };
            _openContent.BeginAnimation(OpacityProperty, fade);
            _openScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(scale, length) { EasingFunction = ease });
            _openScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(scale, length) { EasingFunction = ease });
        }

        private void UpdateTargets()
        {
            double width;
            if (_isOpen) width = OpenWidth;
            else if (_bannerShown) width = BannerWidth;
            else if (_clock.IsRunning && !_isHidden) width = TimerWidth;
            else width = ClosedWidth;

            _width.SetTarget(width);
            _height.SetTarget(_isOpen ? OpenHeight : _isHidden ? 0 : ClosedHeight);
            _topRadius.SetTarget(_isOpen ? 19 : 6);
            _bottomRadius.SetTarget(_isOpen ? 24 : 14);
            StartAnimating();
        }

        private void StartAnimating()
        {
            if (_isAnimating) return;
            _isAnimating = true;
            _lastFrame = _time.Elapsed.TotalSeconds;
            CompositionTarget.Rendering += OnFrame;
        }

        private void OnFrame(object sender, EventArgs e)
        {
            double now = _time.Elapsed.TotalSeconds;
            double seconds = now - _lastFrame;
            _lastFrame = now;
            if (seconds <= 0) return;

            _width.Step(seconds);
            _height.Step(seconds);
            _topRadius.Step(seconds);
            _bottomRadius.Step(seconds);
            RedrawShape();

            // Nothing runs while the notch is at rest
            if (_width.IsSettled && _height.IsSettled && _topRadius.IsSettled && _bottomRadius.IsSettled)
            {
                CompositionTarget.Rendering -= OnFrame;
                _isAnimating = false;
            }
        }

        private void RedrawShape()
        {
            Geometry geometry = NotchGeometry.Make(CenterX - _width.Value / 2, _width.Value, _height.Value, _topRadius.Value, _bottomRadius.Value);
            _shape.Data = geometry;
            _clipped.Clip = geometry;
        }

        /// <summary>For the self test, which renders final states and has no time to watch the springs.</summary>
        public void SettleForTest()
        {
            _width.Snap();
            _height.Snap();
            _topRadius.Snap();
            _bottomRadius.Snap();
            RedrawShape();
            _openContent.BeginAnimation(OpacityProperty, null);
            _openContent.Opacity = _isOpen ? 1 : 0;
            _openScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            _openScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            _openScale.ScaleX = _openScale.ScaleY = _isOpen ? 1 : 0.8;
            _openContent.Visibility = _isOpen ? Visibility.Visible : Visibility.Hidden;
        }

        // MARK: - Tabs

        public void ShowTab(NotchTab tab)
        {
            _tab = tab;
            UpdateTabColors();

            double left = CenterX - OpenWidth / 2 + OpenSideInset + (int)tab * TabWidth;
            _tabCapsule.BeginAnimation(Canvas.LeftProperty, new DoubleAnimation(left, TimeSpan.FromMilliseconds(250))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            });

            UpdateBodyVisibility();
            ShowBody();
        }

        private void UpdateTabColors()
        {
            for (int i = 0; i < _tabIcons.Length; i++)
            {
                _tabIcons[i].SetBrush(i == (int)_tab ? Theme.White : Theme.Gray);
            }
        }

        private void UpdateBodyVisibility()
        {
            _shelfView.Visibility = _tab == NotchTab.Shelf ? Visibility.Visible : Visibility.Hidden;
            _mixerView.Visibility = _tab == NotchTab.Mixer ? Visibility.Visible : Visibility.Hidden;
            _timerView.Visibility = _tab == NotchTab.Timer ? Visibility.Visible : Visibility.Hidden;
        }

        private void ShowBody()
        {
            if (!_isOpen) return;
            if (_tab == NotchTab.Mixer) _mixerView.Shown();
            else _mixerView.Hidden();
            if (_tab == NotchTab.Shelf) _shelfView.Refresh();
            if (_tab == NotchTab.Timer) _timerView.Update();
        }

        // MARK: - The mouse

        private void CheckMouse()
        {
            if (IgnoresMouse) return;

            bool inside = MouseIsOnShape();
            if (inside != _isHovered)
            {
                _isHovered = inside;
                UpdateShadow();
            }

            bool hold = Mouse.Captured != null || _time.Elapsed.TotalSeconds - _lastDrag < DragLinger;
            switch (_hover.Update(_time.Elapsed.TotalSeconds, inside, _isOpen, hold, !_isHidden))
            {
                case HoverAction.Open:
                    Open();
                    UpdateShadow();
                    break;
                case HoverAction.Close:
                    CloseNotch();
                    UpdateShadow();
                    break;
            }
        }

        private bool MouseIsOnShape()
        {
            if (!Native.GetCursorPos(out Native.POINT cursor)) return false;
            Point point;
            try
            {
                point = PointFromScreen(new Point(cursor.X, cursor.Y));
            }
            catch (InvalidOperationException)
            {
                // The window isn't on screen at this moment
                return false;
            }

            double halfWidth = _width.Value / 2;
            return point.X >= CenterX - halfWidth && point.X <= CenterX + halfWidth
                && point.Y >= -1 && point.Y <= _height.Value;
        }

        private void UpdateShadow()
        {
            double target = _isOpen || _isHovered ? 0.7 : 0;
            _shadow.BeginAnimation(DropShadowEffect.OpacityProperty, new DoubleAnimation(target, TimeSpan.FromMilliseconds(150)));
        }

        // MARK: - Files dragged onto the notch

        private void OnDragEnter(object sender, DragEventArgs e)
        {
            if (!AcceptsDrag(e)) return;
            _lastDrag = _time.Elapsed.TotalSeconds;
            _shelfView.SetTargeted(true);
            if (_tab != NotchTab.Shelf) ShowTab(NotchTab.Shelf);
            if (!_isOpen) Open();
        }

        private void OnDragOver(object sender, DragEventArgs e)
        {
            if (AcceptsDrag(e))
            {
                _lastDrag = _time.Elapsed.TotalSeconds;
            }
        }

        private void OnDragLeave(object sender, DragEventArgs e)
        {
            _shelfView.SetTargeted(false);
            e.Handled = true;
        }

        private bool AcceptsDrag(DragEventArgs e)
        {
            bool accepts = !_shelfView.DraggingOut && e.Data.GetDataPresent(DataFormats.FileDrop);
            e.Effects = accepts ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
            return accepts;
        }

        private void OnDrop(object sender, DragEventArgs e)
        {
            _shelfView.SetTargeted(false);
            if (AcceptsDrag(e) && e.Data.GetData(DataFormats.FileDrop) is string[] paths)
            {
                foreach (string path in paths)
                {
                    _shelf.Add(path);
                }
                _shelfView.Refresh();
            }
            _lastDrag = _time.Elapsed.TotalSeconds;
        }

        // MARK: - The timer

        private void TimerChanged()
        {
            if (_clock.IsRunning) _secondTimer.Start();
            else _secondTimer.Stop();
            _timerView.Update();
            UpdateTargets();
            UpdateClosedContent();
        }

        private void SecondPassed()
        {
            if (_clock.Tick(DateTime.UtcNow))
            {
                _secondTimer.Stop();
                _bannerPending = true;
                ShowBannerIfWaiting();
                UpdateTargets();
            }
            _timerView.Update();
            UpdateClosedContent();
        }

        /// <summary>The banner is the only sign that a session is over, so it waits until it can be seen.</summary>
        private void ShowBannerIfWaiting()
        {
            if (!_bannerPending || _isOpen || _isHidden || _bannerShown) return;
            _bannerPending = false;
            _bannerShown = true;
            _bannerTimer.Start();
            UpdateTargets();
            UpdateClosedContent();
        }

        private void BannerOver()
        {
            _bannerTimer.Stop();
            _bannerShown = false;
            UpdateTargets();
            UpdateClosedContent();
        }

        public void ShowBannerForTest()
        {
            _bannerPending = true;
            ShowBannerIfWaiting();
        }

        public void TimerChangedForTest() => TimerChanged();

        private void UpdateClosedContent()
        {
            bool closed = !_isOpen && !_isHidden;
            bool timer = closed && !_bannerShown && _clock.IsRunning;
            bool banner = closed && _bannerShown;

            _closedTimerIcon.Visibility = timer ? Visibility.Visible : Visibility.Hidden;
            _closedTimerText.Visibility = timer ? Visibility.Visible : Visibility.Hidden;
            if (timer) _closedTimerText.Text = _clock.ShortText(DateTime.UtcNow);
            _bannerText.Visibility = banner ? Visibility.Visible : Visibility.Hidden;
            _bannerIcon.Visibility = banner ? Visibility.Visible : Visibility.Hidden;
        }

        // MARK: - Full screen

        private void CheckFullscreen()
        {
            bool hidden = Native.ForegroundIsFullscreenOnMainScreen(_handle, _search.Handle);
            if (hidden == _isHidden) return;
            _isHidden = hidden;
            UpdateTargets();
            UpdateClosedContent();
            ShowBannerIfWaiting();
        }
    }
}
