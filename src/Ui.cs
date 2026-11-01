using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace BoringNotch
{
    /// <summary>The colors and sizes of the Mac version.</summary>
    internal static class Theme
    {
        public static readonly Brush White = Brushes.White;
        public static readonly Brush Black = Brushes.Black;
        public static readonly Brush Gray = Solid(0xFF, 0x8E, 0x8E, 0x93);
        public static readonly Brush DimGray = Solid(0xB3, 0x8E, 0x8E, 0x93);
        public static readonly Brush Orange = Solid(0xFF, 0xFF, 0x9F, 0x0A);
        public static readonly Brush Track = Solid(0x4D, 0x8E, 0x8E, 0x93);
        public static readonly Brush Faint = Solid(0x1A, 0xFF, 0xFF, 0xFF);
        public static readonly Brush Hover = Solid(0x17, 0xFF, 0xFF, 0xFF);
        public static readonly Brush Pill = Solid(0x26, 0xFF, 0xFF, 0xFF);
        public static readonly Brush Selected = Solid(0x29, 0xFF, 0xFF, 0xFF);
        public static readonly FontFamily Font = new FontFamily("Segoe UI");

        public static Brush Solid(byte alpha, byte red, byte green, byte blue)
        {
            var brush = new SolidColorBrush(Color.FromArgb(alpha, red, green, blue));
            brush.Freeze();
            return brush;
        }

        public static TextBlock Text(string text, double size, Brush brush, FontWeight? weight = null)
        {
            return new TextBlock
            {
                Text = text,
                FontFamily = Font,
                FontSize = size,
                Foreground = brush,
                FontWeight = weight ?? FontWeights.Normal,
                TextTrimming = TextTrimming.CharacterEllipsis,
                IsHitTestVisible = false,
            };
        }
    }

    /// <summary>An icon drawn from lines on a 16 by 16 grid, so it needs no font that a Windows version may lack.</summary>
    internal sealed class GlyphIcon : Viewbox
    {
        private readonly Path _path;
        private readonly bool _filled;

        public GlyphIcon(string data, double size, Brush brush, bool filled = false, double thickness = 1.6)
        {
            _filled = filled;
            Width = size;
            Height = size;
            Stretch = Stretch.Uniform;
            IsHitTestVisible = false;
            _path = new Path
            {
                Data = Icons.Parse(data),
                StrokeThickness = thickness,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round,
            };
            var canvas = new Canvas { Width = 16, Height = 16 };
            canvas.Children.Add(_path);
            Child = canvas;
            SetBrush(brush);
        }

        public void SetBrush(Brush brush)
        {
            _path.Stroke = brush;
            _path.Fill = _filled ? brush : null;
        }
    }

    internal static class Icons
    {
        public const string Tray = "M2,9 L4.5,3 H11.5 L14,9 V13 H2 Z M2,9 H5.5 L6.5,11 H9.5 L10.5,9 H14";
        public const string Sliders = "M2,4 H14 M2,8 H14 M2,12 H14 M6.5,2.5 A1.5,1.5 0 1 1 6.49,2.5 M11.5,6.5 A1.5,1.5 0 1 1 11.49,6.5 M5.5,10.5 A1.5,1.5 0 1 1 5.49,10.5";
        public const string Timer = "M8,3 V1 M6,1 H10 M8,8.5 L10.5,6 M13.5,8.5 A5.5,5.5 0 1 1 2.5,8.5 A5.5,5.5 0 1 1 13.5,8.5";
        public const string Search = "M10.8,10.8 L14.5,14.5 M12,7 A5,5 0 1 1 2,7 A5,5 0 1 1 12,7";
        public const string Close = "M5,5 L11,11 M11,5 L5,11";
        public const string Speaker = "M2,6 V10 H5 L9,13 V3 L5,6 Z M11,5.5 A3.5,3.5 0 0 1 11,10.5 M12.8,3.5 A6,6 0 0 1 12.8,12.5";
        public const string Stop = "M4,4 H12 V12 H4 Z";
        public const string Folder = "M1.5,4 H6 L7.5,5.5 H14.5 V13 H1.5 Z";
        public const string Document = "M4,1.5 H10 L13,4.5 V14.5 H4 Z M10,1.5 V4.5 H13";
        public const string Gear = "M11,8 A3,3 0 1 1 5,8 A3,3 0 1 1 11,8 M8,1 V3 M8,13 V15 M1,8 H3 M13,8 H15 M3,3 L4.4,4.4 M11.6,11.6 L13,13 M3,13 L4.4,11.6 M11.6,4.4 L13,3";
        public const string Globe = "M14.5,8 A6.5,6.5 0 1 1 1.5,8 A6.5,6.5 0 1 1 14.5,8 M1.5,8 H14.5 M8,1.5 A9,9 0 0 1 8,14.5 M8,1.5 A9,9 0 0 0 8,14.5";
        public const string App = "M2,2 H14 V14 H2 Z M2,5.5 H14";

        private static readonly Dictionary<string, Geometry> Parsed = new Dictionary<string, Geometry>();

        public static Geometry Parse(string data)
        {
            if (!Parsed.TryGetValue(data, out Geometry geometry))
            {
                try
                {
                    geometry = Geometry.Parse(data);
                    geometry.Freeze();
                }
                catch (FormatException)
                {
                    // A missing icon shouldn't take the app down
                    geometry = Geometry.Empty;
                }
                Parsed[data] = geometry;
            }
            return geometry;
        }

        /// <summary>A gray circle with a dark cross, like xmark.circle.fill on the Mac.</summary>
        public static FrameworkElement CloseCircle(double size)
        {
            var grid = new Grid { Width = size, Height = size, IsHitTestVisible = false };
            grid.Children.Add(new Ellipse { Fill = Theme.Gray });
            grid.Children.Add(new GlyphIcon(Close, size, Theme.Solid(0xFF, 0x1C, 0x1C, 0x1E), thickness: 1.8));
            return grid;
        }
    }

    internal static class Press
    {
        /// <summary>
        /// A click for anything on screen. The windows here don't activate, and a real Button would bring its own look.
        /// The element needs a background, or only its drawn parts take the click.
        /// </summary>
        public static void OnClick(UIElement element, Action action)
        {
            element.MouseLeftButtonDown += (sender, e) =>
            {
                element.CaptureMouse();
                e.Handled = true;
            };
            element.MouseLeftButtonUp += (sender, e) =>
            {
                if (!element.IsMouseCaptured) return;
                element.ReleaseMouseCapture();
                e.Handled = true;

                Point at = e.GetPosition(element);
                Size size = element.RenderSize;
                if (at.X >= 0 && at.Y >= 0 && at.X <= size.Width && at.Y <= size.Height)
                {
                    action();
                }
            };
            if (element is FrameworkElement framework)
            {
                framework.Cursor = Cursors.Hand;
            }
        }
    }
}
