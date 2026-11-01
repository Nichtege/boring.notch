using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace BoringNotch
{
    /// <summary>The Mac's CustomSlider: a thin line that gets thicker under the finger, and a click jumps there.</summary>
    internal sealed class NotchSlider : FrameworkElement
    {
        private const double RestThickness = 5;
        private const double DragThickness = 9;
        private static readonly Duration ThicknessChange = TimeSpan.FromMilliseconds(150);

        private static readonly DependencyProperty TrackThicknessProperty = DependencyProperty.Register(
            "TrackThickness",
            typeof(double),
            typeof(NotchSlider),
            new FrameworkPropertyMetadata(RestThickness, FrameworkPropertyMetadataOptions.AffectsRender));

        private double _value;

        /// <summary>Set by the user, and only then with a ValueChanged.</summary>
        public event Action<double> ValueChanged;
        public event Action DragEnded;

        public bool IsDragging { get; private set; }

        /// <summary>From 0 to 1. Setting it from outside says nothing to the listeners.</summary>
        public double Value
        {
            get => _value;
            set
            {
                double clamped = Clamp(value);
                if (clamped == _value) return;
                _value = clamped;
                InvalidateVisual();
            }
        }

        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonDown(e);
            if (!CaptureMouse()) return;
            IsDragging = true;
            AnimateThickness(DragThickness);
            MoveTo(e.GetPosition(this));
            e.Handled = true;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (IsDragging)
            {
                MoveTo(e.GetPosition(this));
            }
        }

        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonUp(e);
            if (!IsDragging) return;
            e.Handled = true;
            ReleaseMouseCapture();
        }

        // Every way a drag can end comes through here, a window taking the mouse away as well
        protected override void OnLostMouseCapture(MouseEventArgs e)
        {
            base.OnLostMouseCapture(e);
            if (!IsDragging) return;
            IsDragging = false;
            AnimateThickness(RestThickness);
            DragEnded?.Invoke();
        }

        protected override void OnRender(DrawingContext context)
        {
            double width = ActualWidth;
            double height = ActualHeight;

            // The whole height takes the mouse, not only the thin line
            context.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, width, height));

            double thickness = (double)GetValue(TrackThicknessProperty);
            double radius = thickness / 2;
            var track = new Rect(0, (height - thickness) / 2, width, thickness);
            context.DrawRoundedRectangle(Theme.Track, null, track, radius, radius);

            double filled = _value * width;
            if (filled <= 0) return;

            // Inside the line's own shape, so a short fill doesn't stick out of its rounded end
            context.PushClip(new RectangleGeometry(track, radius, radius));
            context.DrawRoundedRectangle(Theme.White, null, new Rect(track.X, track.Y, filled, thickness), radius, radius);
            context.Pop();
        }

        private void MoveTo(Point at)
        {
            if (ActualWidth <= 0) return;
            double value = Clamp(at.X / ActualWidth);
            if (value == _value) return;
            _value = value;
            InvalidateVisual();
            ValueChanged?.Invoke(value);
        }

        private void AnimateThickness(double thickness)
        {
            BeginAnimation(TrackThicknessProperty, new DoubleAnimation(thickness, ThicknessChange)
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            });
        }

        private static double Clamp(double value) => Math.Min(1, Math.Max(0, value));
    }
}
