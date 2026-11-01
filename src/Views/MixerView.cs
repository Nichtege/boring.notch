using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;

namespace BoringNotch
{
    /// <summary>The Mixer tab: the PC itself, and every app making sound.</summary>
    internal sealed class MixerView : Grid
    {
        private const double RowHeight = 20;
        private const double RowGap = 2;
        private const double IconSize = 16;
        private const int IconPixels = 32;
        private const double NameWidth = 120;
        private const double PercentWidth = 38;
        private const double ColumnGap = 8;

        private sealed class Row
        {
            public Grid Root;
            public NotchSlider Slider;
            public TextBlock Name;
            public TextBlock Percent;
            public Image Picture;
            public UIElement Fallback;
            public string IconPath;

            public void Show(double volume)
            {
                // A finger on the slider knows better than the last look at the app
                if (!Slider.IsDragging)
                {
                    Slider.Value = volume;
                }
                ShowPercent();
            }

            public void ShowPercent()
            {
                Percent.Text = (int)Math.Round(Slider.Value * 100) + " %";
            }
        }

        private readonly AudioMixer _mixer;
        private readonly StackPanel _list;
        private readonly TextBlock _nothingElse;
        private readonly DispatcherTimer _timer;
        private readonly Dictionary<string, Row> _rows = new Dictionary<string, Row>();
        private Row _pc;

        public MixerView(AudioMixer mixer)
        {
            _mixer = mixer;
            Background = Brushes.Transparent;

            _list = new StackPanel();
            _nothingElse = Theme.Text("Sonst spielt gerade nichts", 11, Theme.DimGray);
            _nothingElse.Margin = new Thickness(6, 4, 6, 0);

            Children.Add(new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Focusable = false,
                Background = Brushes.Transparent,
                Margin = new Thickness(12, 2, 12, 4),
                Content = _list,
            });

            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += (sender, e) => Refresh();
        }

        /// <summary>Only looked after while the tab is on screen.</summary>
        public void Shown()
        {
            Refresh();
            _timer.Start();
        }

        public void Hidden()
        {
            _timer.Stop();
        }

        private void Refresh()
        {
            _mixer.Refresh();

            // Taking a row out from under the mouse would end the drag, so the list changes after it
            bool isDragging = (_pc != null && _pc.Slider.IsDragging) || _rows.Values.Any(row => row.Slider.IsDragging);
            if (!isDragging)
            {
                UpdateList();
            }

            if (_pc != null && _mixer.HasMaster)
            {
                _pc.Show(_mixer.MasterVolume);
            }
            foreach (MixerApp app in _mixer.Apps)
            {
                if (_rows.TryGetValue(app.Id, out Row row))
                {
                    row.Name.Text = app.Name;
                    ShowIcon(row, app.IconPath);
                    row.Show(app.Volume);
                }
            }
        }

        private void UpdateList()
        {
            var shown = new List<UIElement>();

            if (_mixer.HasMaster)
            {
                _pc = _pc ?? MakePcRow();
                shown.Add(_pc.Root);
            }
            else
            {
                _pc = null;
            }

            var seen = new HashSet<string>();
            foreach (MixerApp app in _mixer.Apps)
            {
                if (!seen.Add(app.Id)) continue;
                if (!_rows.TryGetValue(app.Id, out Row row))
                {
                    row = MakeAppRow(app);
                    _rows[app.Id] = row;
                }
                shown.Add(row.Root);
            }
            foreach (string gone in _rows.Keys.Where(id => !seen.Contains(id)).ToList())
            {
                _rows.Remove(gone);
            }

            if (seen.Count == 0)
            {
                shown.Add(_nothingElse);
            }

            if (!_list.Children.Cast<UIElement>().SequenceEqual(shown))
            {
                _list.Children.Clear();
                foreach (UIElement element in shown)
                {
                    _list.Children.Add(element);
                }
            }
        }

        private Row MakePcRow()
        {
            Row row = MakeRow("PC", new GlyphIcon(Icons.Speaker, IconSize, Theme.Gray));
            row.Slider.ValueChanged += volume => _mixer.SetMasterVolume(volume);
            return row;
        }

        private Row MakeAppRow(MixerApp app)
        {
            Row row = MakeRow(app.Name, new GlyphIcon(Icons.App, IconSize, Theme.Gray));
            string id = app.Id;
            row.Slider.ValueChanged += volume => _mixer.SetAppVolume(id, volume);
            ShowIcon(row, app.IconPath);
            return row;
        }

        private Row MakeRow(string name, UIElement fallback)
        {
            var row = new Row { Fallback = fallback };

            row.Picture = new Image { Stretch = Stretch.Uniform, IsHitTestVisible = false };
            RenderOptions.SetBitmapScalingMode(row.Picture, BitmapScalingMode.HighQuality);
            var icon = new Grid { Width = IconSize, Height = IconSize, IsHitTestVisible = false };
            icon.Children.Add(fallback);
            icon.Children.Add(row.Picture);

            row.Name = Theme.Text(name, 12, Theme.White);
            row.Name.VerticalAlignment = VerticalAlignment.Center;

            row.Slider = new NotchSlider { Height = 10, VerticalAlignment = VerticalAlignment.Center };
            row.Slider.ValueChanged += volume => row.ShowPercent();

            row.Percent = Theme.Text("", 11, Theme.Gray);
            row.Percent.VerticalAlignment = VerticalAlignment.Center;
            row.Percent.TextAlignment = TextAlignment.Right;
            Typography.SetNumeralAlignment(row.Percent, FontNumeralAlignment.Tabular);

            row.Root = new Grid
            {
                Height = RowHeight,
                Margin = new Thickness(6, 0, 6, RowGap),
                Background = Brushes.Transparent,
            };
            AddColumn(row.Root, new GridLength(IconSize), icon);
            AddColumn(row.Root, new GridLength(ColumnGap), null);
            AddColumn(row.Root, new GridLength(NameWidth), row.Name);
            AddColumn(row.Root, new GridLength(ColumnGap), null);
            AddColumn(row.Root, new GridLength(1, GridUnitType.Star), row.Slider);
            AddColumn(row.Root, new GridLength(ColumnGap), null);
            AddColumn(row.Root, new GridLength(PercentWidth), row.Percent);
            return row;
        }

        private static void AddColumn(Grid grid, GridLength width, UIElement content)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            if (content == null) return;
            SetColumn(content, grid.ColumnDefinitions.Count - 1);
            grid.Children.Add(content);
        }

        private static void ShowIcon(Row row, string iconPath)
        {
            if (string.IsNullOrEmpty(iconPath) || iconPath == row.IconPath) return;
            row.IconPath = iconPath;
            ShellIcons.Load(iconPath, IconPixels, source =>
            {
                // A later look may have found another path for this row
                if (source == null || row.IconPath != iconPath) return;
                row.Picture.Source = source;
                row.Fallback.Visibility = Visibility.Collapsed;
            });
        }
    }
}
