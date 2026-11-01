using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using BoringNotch.Core;
using IOPath = System.IO.Path;
using ShapeRectangle = System.Windows.Shapes.Rectangle;

namespace BoringNotch
{
    /// <summary>
    /// The shelf tab: what's on it, and a way to drag it out again. Taking drops is up to the notch window,
    /// as they also arrive while the notch is still closed.
    /// </summary>
    internal sealed class ShelfView : Grid
    {
        private const double TileWidth = 115;
        private const double PictureSize = 56;
        private const int PicturePixels = 112;
        private const double ButtonSize = 18;
        private const double DragDistance = 4;
        private static readonly Brush ButtonBackground = Theme.Solid(0xFF, 0x2C, 0x2C, 0x2E);

        private readonly ShelfStore _store;
        private readonly ShapeRectangle _frame;
        private readonly StackPanel _empty;
        private readonly ScrollViewer _scroll;
        private readonly StackPanel _items;

        private string _pressedPath;
        private Point _pressedAt;

        public ShelfView(ShelfStore store)
        {
            _store = store;
            Background = Brushes.Transparent;

            _frame = new ShapeRectangle
            {
                RadiusX = 16,
                RadiusY = 16,
                StrokeThickness = 3,
                // In widths of the line, so 10 points each as on the Mac
                StrokeDashArray = new DoubleCollection { 10.0 / 3, 10.0 / 3 },
                StrokeDashCap = PenLineCap.Round,
                Stroke = Theme.Faint,
                IsHitTestVisible = false,
            };
            Children.Add(_frame);

            _empty = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
            };
            _empty.Children.Add(new GlyphIcon(Icons.Tray, 24, Theme.White) { Margin = new Thickness(0, 0, 0, 10) });
            _empty.Children.Add(Theme.Text("Dateien hier ablegen", 17, Theme.Gray, FontWeights.Medium));
            Children.Add(_empty);

            _items = new StackPanel { Orientation = Orientation.Horizontal };
            _scroll = new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Focusable = false,
                Margin = new Thickness(8, 0, 8, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Content = _items,
            };
            _scroll.PreviewMouseWheel += (sender, e) =>
            {
                _scroll.ScrollToHorizontalOffset(_scroll.HorizontalOffset - e.Delta);
                e.Handled = true;
            };
            Children.Add(_scroll);

            Refresh();
        }

        /// <summary>While a file is on its way out of the shelf, so it can't be dropped back on it.</summary>
        public bool DraggingOut { get; private set; }

        /// <summary>Takes off what's gone from disk and shows the rest.</summary>
        public void Refresh()
        {
            // The tile being dragged has to stay until the drag is over, which refreshes anyway
            if (DraggingOut) return;

            _store.CleanupMissing();
            _pressedPath = null;
            _items.Children.Clear();
            foreach (string path in _store.Paths)
            {
                _items.Children.Add(MakeTile(path));
            }

            bool isEmpty = _store.IsEmpty;
            _empty.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
            _scroll.Visibility = isEmpty ? Visibility.Collapsed : Visibility.Visible;
        }

        public void SetTargeted(bool targeted)
        {
            _frame.Stroke = targeted ? SystemColors.HighlightBrush : Theme.Faint;
        }

        private FrameworkElement MakeTile(string path)
        {
            var content = new StackPanel();
            content.Children.Add(MakePicture(path));
            content.Children.Add(new TextBlock
            {
                Text = DisplayName(path),
                FontFamily = Theme.Font,
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                Foreground = Theme.White,
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                TextTrimming = TextTrimming.CharacterEllipsis,
                // Two lines exactly, or the second would be cut off below
                LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
                LineHeight = 15,
                Height = 30,
                Margin = new Thickness(0, 2, 0, 0),
                IsHitTestVisible = false,
            });

            var background = new Border
            {
                CornerRadius = new CornerRadius(12),
                Background = Brushes.Transparent,
                Padding = new Thickness(5, 10, 5, 10),
                Child = content,
            };

            FrameworkElement remove = MakeRemoveButton(path);
            FrameworkElement reveal = MakeRevealButton(path);

            var tile = new Grid { Width = TileWidth, Background = Brushes.Transparent };
            tile.Children.Add(background);
            tile.Children.Add(reveal);
            tile.Children.Add(remove);

            tile.MouseEnter += (sender, e) =>
            {
                background.Background = Theme.Hover;
                remove.Visibility = Visibility.Visible;
                reveal.Visibility = Visibility.Visible;
            };
            tile.MouseLeave += (sender, e) =>
            {
                background.Background = Brushes.Transparent;
                remove.Visibility = Visibility.Collapsed;
                reveal.Visibility = Visibility.Collapsed;
            };

            AddPressAndDrag(tile, path);
            return tile;
        }

        private static FrameworkElement MakePicture(string path)
        {
            var fallback = new GlyphIcon(Icons.Document, 40, Theme.Gray)
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var image = new Image { Stretch = Stretch.Uniform, IsHitTestVisible = false };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);

            var picture = new Grid
            {
                Width = PictureSize,
                Height = PictureSize,
                HorizontalAlignment = HorizontalAlignment.Center,
                Clip = new RectangleGeometry(new Rect(0, 0, PictureSize, PictureSize), 12, 12),
                IsHitTestVisible = false,
            };
            picture.Children.Add(fallback);
            picture.Children.Add(image);

            ShellIcons.Load(path, PicturePixels, source =>
            {
                if (source == null) return;
                image.Source = source;
                fallback.Visibility = Visibility.Collapsed;
            });
            return picture;
        }

        private FrameworkElement MakeRemoveButton(string path)
        {
            var button = new Border
            {
                Width = ButtonSize,
                Height = ButtonSize,
                Background = Brushes.Transparent,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 3, 3, 0),
                Visibility = Visibility.Collapsed,
                Child = Icons.CloseCircle(ButtonSize),
                ToolTip = "Entfernen",
            };
            AutomationProperties.SetName(button, "Entfernen");
            Press.OnClick(button, () =>
            {
                _store.Remove(path);
                Refresh();
            });
            return button;
        }

        private FrameworkElement MakeRevealButton(string path)
        {
            var button = new Border
            {
                Width = ButtonSize,
                Height = ButtonSize,
                CornerRadius = new CornerRadius(ButtonSize / 2),
                Background = ButtonBackground,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(3, 3, 0, 0),
                Visibility = Visibility.Collapsed,
                Child = new GlyphIcon(Icons.Folder, 12, Theme.White)
                {
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
                ToolTip = "Im Explorer zeigen",
            };
            AutomationProperties.SetName(button, "Im Explorer zeigen");
            Press.OnClick(button, () =>
            {
                if (!Launcher.ShowInExplorer(path))
                {
                    Refresh();
                }
            });
            return button;
        }

        /// <summary>
        /// A double click opens the file and a press that moves drags it out. The buttons on the tile handle their
        /// own press, which never gets here.
        /// </summary>
        private void AddPressAndDrag(FrameworkElement tile, string path)
        {
            tile.MouseLeftButtonDown += (sender, e) =>
            {
                e.Handled = true;
                if (e.ClickCount >= 2)
                {
                    _pressedPath = null;
                    if (!Launcher.Open(path))
                    {
                        Refresh();
                    }
                    return;
                }
                _pressedPath = path;
                _pressedAt = e.GetPosition(this);
                tile.CaptureMouse();
            };

            tile.MouseMove += (sender, e) =>
            {
                if (_pressedPath != path || e.LeftButton != MouseButtonState.Pressed) return;

                Point now = e.GetPosition(this);
                if ((now - _pressedAt).Length < DragDistance) return;

                _pressedPath = null;
                tile.ReleaseMouseCapture();
                DragOut(tile, path);
            };

            tile.MouseLeftButtonUp += (sender, e) =>
            {
                if (_pressedPath != path) return;
                _pressedPath = null;
                tile.ReleaseMouseCapture();
                e.Handled = true;
            };
        }

        private void DragOut(FrameworkElement tile, string path)
        {
            var data = new DataObject(DataFormats.FileDrop, new[] { path });
            DraggingOut = true;
            try
            {
                DragDrop.DoDragDrop(tile, data, DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link);
            }
            finally
            {
                DraggingOut = false;
            }
            // Moved somewhere else it isn't there any more
            Refresh();
        }

        private static string DisplayName(string path)
        {
            string name = IOPath.GetFileName(path.TrimEnd('\\', '/'));
            // A whole drive has no name of its own
            return string.IsNullOrEmpty(name) ? path : name;
        }
    }
}
