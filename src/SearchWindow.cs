using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using BoringNotch.Core;

namespace BoringNotch
{
    /// <summary>
    /// The search line under the notch, made like the Mac's Atlas line: 560 wide, smoked, the field in one row, and what
    /// it finds growing below it. Unlike the notch this window takes the keyboard, and it goes when the user clicks away.
    /// What's typed stays in memory and only leaves the PC if the web row is picked.
    /// </summary>
    internal sealed class SearchWindow : Window
    {
        private const double LineWidth = 560;
        private const double Side = 30;
        private const double GapBelowNotch = 6;
        private const double SlideDistance = 14;
        private const double RowHeight = 40;
        private const int FileRows = 6;
        private const int ThinkingTimeMs = 180;

        private readonly Canvas _root;
        private readonly Border _card;
        private readonly TranslateTransform _slide = new TranslateTransform();
        private readonly TextBox _field;
        private readonly TextBlock _placeholder;
        private readonly StackPanel _rows = new StackPanel();
        private readonly TextBlock _problem = Theme.Text("", 12, Theme.Orange);
        private readonly DispatcherTimer _thinking = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ThinkingTimeMs) };

        private IntPtr _handle;
        private double _notchBottom = NotchWindow.ClosedHeight;
        private int _generation;
        private List<SearchResult> _results = new List<SearchResult>();
        private IReadOnlyList<string> _files = new string[0];
        private int _selected;
        private bool _isOpen;

        public IntPtr Handle => _handle;

        public FrameworkElement Root => _root;

        public bool FileSearchFailed { get; private set; }

        public int ResultCount => _results.Count;

        public SearchWindow()
        {
            double height = NotchWindow.OpenHeight + GapBelowNotch + 52 + 10 + SearchResults.MaxRows * RowHeight + 24 + 2 * Side;
            Title = "Boring Notch Suche";
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowInTaskbar = false;
            Topmost = true;
            Width = LineWidth + 2 * Side;
            Height = height;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = 0;
            Top = 0;
            UseLayoutRounding = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
            RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);

            _field = new TextBox
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = Theme.White,
                CaretBrush = Theme.White,
                SelectionBrush = Theme.Gray,
                FontFamily = Theme.Font,
                FontSize = 16,
                Padding = new Thickness(0),
                VerticalContentAlignment = VerticalAlignment.Center,
                FocusVisualStyle = null,
            };
            _placeholder = Theme.Text("Windows durchsuchen…", 16, Theme.Gray);
            _placeholder.VerticalAlignment = VerticalAlignment.Center;
            _placeholder.Margin = new Thickness(2, 0, 0, 0);

            _card = BuildCard();
            _root = new Canvas { Width = Width, Height = Height };
            _card.RenderTransform = _slide;
            Canvas.SetLeft(_card, Side);
            _root.Children.Add(_card);
            Content = _root;

            _field.TextChanged += (sender, e) => QueryChanged();
            PreviewKeyDown += OnKey;
            Deactivated += (sender, e) => HideLine();
            _thinking.Tick += (sender, e) => SearchFiles();
            SourceInitialized += (sender, e) =>
            {
                _handle = new WindowInteropHelper(this).Handle;
                Native.AddExStyle(_handle, Native.WS_EX_TOOLWINDOW);
            };
            new WindowInteropHelper(this).EnsureHandle();
        }

        private Border BuildCard()
        {
            var fieldHost = new Grid();
            fieldHost.Children.Add(_placeholder);
            fieldHost.Children.Add(_field);

            var close = new Grid { Background = Brushes.Transparent, Width = 22, Height = 24, ToolTip = "Schließen" };
            var circle = Icons.CloseCircle(16);
            circle.HorizontalAlignment = HorizontalAlignment.Center;
            circle.VerticalAlignment = VerticalAlignment.Center;
            close.Children.Add(circle);
            Press.OnClick(close, HideLine);

            var row = new Grid { Height = 24 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var glass = new GlyphIcon(Icons.Search, 17, Theme.White);
            glass.VerticalAlignment = VerticalAlignment.Center;
            glass.Margin = new Thickness(0, 0, 10, 0);
            Grid.SetColumn(glass, 0);
            row.Children.Add(glass);

            Grid.SetColumn(fieldHost, 1);
            row.Children.Add(fieldHost);

            close.Margin = new Thickness(10, 0, 0, 0);
            Grid.SetColumn(close, 2);
            row.Children.Add(close);

            _rows.Margin = new Thickness(-6, 10, -6, 0);
            _rows.Visibility = Visibility.Collapsed;
            _problem.Margin = new Thickness(0, 8, 0, 0);
            _problem.Visibility = Visibility.Collapsed;

            var content = new StackPanel { Margin = new Thickness(14) };
            content.Children.Add(row);
            content.Children.Add(_rows);
            content.Children.Add(_problem);

            return new Border
            {
                Width = LineWidth,
                CornerRadius = new CornerRadius(18),
                Background = Theme.Solid(0xEB, 0x14, 0x14, 0x16),
                BorderBrush = Theme.Solid(0x1F, 0xFF, 0xFF, 0xFF),
                BorderThickness = new Thickness(1),
                Child = content,
                Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 24, ShadowDepth = 4, Direction = 270, Opacity = 0.5 },
            };
        }

        // MARK: - Showing

        public void Toggle()
        {
            if (_isOpen && IsActive) HideLine();
            else Open();
        }

        public void Open()
        {
            AppCatalog.RefreshIfStale();
            Native.PlaceTopCenter(_handle, Width, Height);

            bool wasOpen = _isOpen;
            _isOpen = true;
            if (!wasOpen)
            {
                // Comes down from under the notch
                Canvas.SetTop(_card, 0);
                double y = _notchBottom + GapBelowNotch;
                _slide.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(y - SlideDistance, y, TimeSpan.FromMilliseconds(220))
                {
                    EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                });
                _card.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));
            }

            Show();
            Activate();
            Native.SetForegroundWindow(_handle);
            // The field can only take the keyboard once the window has been laid out and activated
            Dispatcher.BeginInvoke(new Action(() =>
            {
                _field.Focus();
                Keyboard.Focus(_field);
            }), DispatcherPriority.Input);
        }

        public void HideLine()
        {
            if (!_isOpen) return;
            _isOpen = false;
            _thinking.Stop();
            _generation++;
            Hide();
            _field.Text = "";
        }

        /// <summary>The line stays under the notch, so it moves with an opening or closing notch.</summary>
        public void SetNotchBottom(double bottom)
        {
            _notchBottom = bottom;
            if (!_isOpen) return;
            _slide.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(bottom + GapBelowNotch, TimeSpan.FromMilliseconds(300))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut },
            });
        }

        // MARK: - Searching

        private void QueryChanged()
        {
            _placeholder.Visibility = _field.Text.Length == 0 ? Visibility.Visible : Visibility.Hidden;
            _generation++;
            _files = new string[0];
            _selected = 0;
            _problem.Visibility = Visibility.Collapsed;
            ShowResults();

            _thinking.Stop();
            if (_field.Text.Trim().Length > 0)
            {
                _thinking.Start();
            }
        }

        private async void SearchFiles()
        {
            _thinking.Stop();
            int generation = _generation;
            FileSearchOutcome outcome = await FileSearch.FindAsync(_field.Text, FileRows);

            // Typed on in the meantime, or closed
            if (generation != _generation) return;

            FileSearchFailed = outcome.Failed;
            _files = outcome.Paths;
            if (outcome.Failed)
            {
                ShowProblem("Dateien werden nicht gefunden: Der Windows-Suchdienst antwortet nicht.");
            }
            ShowResults();
        }

        private void ShowResults()
        {
            string selectedKey = _selected < _results.Count ? _results[_selected].Key : null;
            _results = SearchResults.Combine(_field.Text, AppCatalog.Apps, SettingsCatalog.All, _files);

            // Files arrive late, and the row in reach shouldn't jump away under the keyboard
            int kept = selectedKey == null ? -1 : _results.FindIndex(r => r.Key == selectedKey);
            _selected = kept >= 0 ? kept : 0;

            _rows.Children.Clear();
            foreach (SearchResult result in _results)
            {
                _rows.Children.Add(MakeRow(result, _rows.Children.Count));
            }
            _rows.Visibility = _results.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateSelection();
        }

        private FrameworkElement MakeRow(SearchResult result, int index)
        {
            var title = Theme.Text(result.Title, 13, Theme.White);
            var subtitle = Theme.Text(result.Subtitle, 11, Theme.Gray);
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(title);
            texts.Children.Add(subtitle);

            var iconHost = new Grid { Width = 24, Height = 24, Margin = new Thickness(0, 0, 10, 0) };
            FillIcon(iconHost, result);

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(iconHost, 0);
            Grid.SetColumn(texts, 1);
            grid.Children.Add(iconHost);
            grid.Children.Add(texts);

            var row = new Border
            {
                Height = RowHeight,
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(6, 0, 6, 0),
                Background = Brushes.Transparent,
                Child = grid,
            };
            row.MouseEnter += (sender, e) =>
            {
                if (index != _selected) row.Background = Theme.Hover;
            };
            row.MouseLeave += (sender, e) =>
            {
                if (index != _selected) row.Background = Brushes.Transparent;
            };
            Press.OnClick(row, () =>
            {
                _selected = index;
                OpenSelected();
            });
            return row;
        }

        private static void FillIcon(Grid host, SearchResult result)
        {
            string glyph;
            switch (result.Kind)
            {
                case ResultKind.Setting: glyph = Icons.Gear; break;
                case ResultKind.ExplorerSearch: glyph = Icons.Search; break;
                case ResultKind.WebSearch: glyph = Icons.Globe; break;
                case ResultKind.App: glyph = Icons.App; break;
                default: glyph = Icons.Document; break;
            }

            var fallback = new GlyphIcon(glyph, 18, Theme.Gray) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            host.Children.Add(fallback);

            if (result.Kind == ResultKind.App || result.Kind == ResultKind.File)
            {
                ShellIcons.Load(result.Target, 48, image =>
                {
                    if (image == null) return;
                    host.Children.Clear();
                    host.Children.Add(new Image { Source = image, Width = 24, Height = 24, Stretch = Stretch.Uniform });
                });
            }
        }

        private void UpdateSelection()
        {
            for (int i = 0; i < _rows.Children.Count; i++)
            {
                ((Border)_rows.Children[i]).Background = i == _selected ? Theme.Selected : Brushes.Transparent;
            }
        }

        private void OpenSelected()
        {
            if (_selected >= _results.Count) return;
            if (Launcher.Open(_results[_selected].Target))
            {
                HideLine();
            }
            else
            {
                ShowProblem("Das ließ sich nicht öffnen.");
            }
        }

        private void ShowProblem(string text)
        {
            _problem.Text = text;
            _problem.Visibility = Visibility.Visible;
        }

        private void OnKey(object sender, KeyEventArgs e)
        {
            switch (e.Key)
            {
                case Key.Escape:
                    HideLine();
                    e.Handled = true;
                    break;
                case Key.Enter:
                    OpenSelected();
                    e.Handled = true;
                    break;
                case Key.Down:
                    MoveSelection(1);
                    e.Handled = true;
                    break;
                case Key.Up:
                    MoveSelection(-1);
                    e.Handled = true;
                    break;
            }
        }

        private void MoveSelection(int step)
        {
            if (_results.Count == 0) return;
            _selected = (_selected + step + _results.Count) % _results.Count;
            UpdateSelection();
        }

        // MARK: - For the self test

        public void TypeForTest(string text)
        {
            _field.Text = text;
        }

        public void SettleForTest()
        {
            _slide.BeginAnimation(TranslateTransform.YProperty, null);
            _slide.Y = _notchBottom + GapBelowNotch;
            _card.BeginAnimation(OpacityProperty, null);
            _card.Opacity = 1;
        }
    }
}
