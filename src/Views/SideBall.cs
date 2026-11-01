using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using BoringNotch.Core;

namespace BoringNotch
{
    /// <summary>
    /// The timer as a small ball beside the notch while music keeps the notch for itself. As on the iPhone the ring
    /// alone tells the time, and the exact number is one hover or click away.
    /// </summary>
    internal sealed class SideBall : Grid
    {
        private const double RingThickness = 3;
        private const double InsetFraction = 0.2;
        private const double HoverScale = 1.08;
        private static readonly TimeSpan HoverLength = TimeSpan.FromMilliseconds(200);
        private static readonly Brush RingBrush = Theme.Solid(0x47, 0xFF, 0x9F, 0x0A);

        private readonly FocusClock _clock;
        private readonly ScaleTransform _scale = new ScaleTransform(1, 1);
        private readonly Path _ring = new Path { Stroke = RingBrush, StrokeThickness = RingThickness, IsHitTestVisible = false };
        private readonly Path _rest = new Path
        {
            Stroke = Theme.Orange,
            StrokeThickness = RingThickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            IsHitTestVisible = false,
        };

        private double _diameter = 26;

        public SideBall(FocusClock clock, Action onClick)
        {
            _clock = clock;
            RenderTransform = _scale;
            RenderTransformOrigin = new Point(0.5, 0.5);

            Children.Add(new Ellipse { Fill = Theme.Black });
            Children.Add(_ring);
            Children.Add(_rest);

            MouseEnter += (sender, e) => ScaleTo(HoverScale);
            MouseLeave += (sender, e) => ScaleTo(1);
            Press.OnClick(this, onClick);

            ApplyDiameter();
        }

        public double Diameter
        {
            get => _diameter;
            set
            {
                if (value == _diameter) return;
                _diameter = value;
                ApplyDiameter();
            }
        }

        /// <summary>The notch window calls this every second while a session runs.</summary>
        public void Update()
        {
            DateTime now = DateTime.UtcNow;
            _rest.Data = MakeArc(Math.Max(0, 1 - _clock.Progress(now)));
            ToolTip = _clock.ClockText(now);
        }

        private void ApplyDiameter()
        {
            Width = _diameter;
            Height = _diameter;
            _ring.Data = new EllipseGeometry(new Point(_diameter / 2, _diameter / 2), Radius, Radius);
            Update();
        }

        private double Radius => _diameter * (1 - 2 * InsetFraction) / 2;

        /// <summary>Clockwise from the top, as far as the share of time that's left.</summary>
        private Geometry MakeArc(double share)
        {
            var center = new Point(_diameter / 2, _diameter / 2);
            if (share <= 0) return Geometry.Empty;
            if (share >= 0.9999) return new EllipseGeometry(center, Radius, Radius);

            double angle = share * 2 * Math.PI;
            var start = new Point(center.X, center.Y - Radius);
            var end = new Point(center.X + Radius * Math.Sin(angle), center.Y - Radius * Math.Cos(angle));

            var geometry = new StreamGeometry();
            using (StreamGeometryContext context = geometry.Open())
            {
                context.BeginFigure(start, false, false);
                context.ArcTo(end, new Size(Radius, Radius), 0, share > 0.5, SweepDirection.Clockwise, true, false);
            }
            geometry.Freeze();
            return geometry;
        }

        private void ScaleTo(double scale)
        {
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            _scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(scale, HoverLength) { EasingFunction = ease });
            _scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(scale, HoverLength) { EasingFunction = ease });
        }
    }
}
