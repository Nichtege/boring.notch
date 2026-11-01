using System;
using System.Windows;
using System.Windows.Media;

namespace BoringNotch
{
    /// <summary>
    /// The notch's outline, as in NotchShape.swift: the top corners flare outward into the screen's edge, the bottom ones
    /// round inward. Derived from DynamicNotchKit by Kai Azim (MIT), see THIRD_PARTY_LICENSES.
    /// </summary>
    internal static class NotchGeometry
    {
        public static Geometry Make(double x, double width, double height, double topRadius, double bottomRadius)
        {
            // A notch on its way to height 0, over a video, mustn't turn inside out
            double h = Math.Max(0, height);
            double top = Math.Min(Math.Max(0, topRadius), h / 2);
            double bottom = Math.Min(Math.Max(0, bottomRadius), h / 2);
            double minX = x;
            double maxX = x + width;

            var geometry = new StreamGeometry();
            using (StreamGeometryContext c = geometry.Open())
            {
                c.BeginFigure(new Point(minX, 0), true, true);
                c.QuadraticBezierTo(new Point(minX + top, 0), new Point(minX + top, top), true, false);
                c.LineTo(new Point(minX + top, h - bottom), true, false);
                c.QuadraticBezierTo(new Point(minX + top, h), new Point(minX + top + bottom, h), true, false);
                c.LineTo(new Point(maxX - top - bottom, h), true, false);
                c.QuadraticBezierTo(new Point(maxX - top, h), new Point(maxX - top, h - bottom), true, false);
                c.LineTo(new Point(maxX - top, top), true, false);
                c.QuadraticBezierTo(new Point(maxX - top, 0), new Point(maxX, 0), true, false);
            }
            geometry.Freeze();
            return geometry;
        }
    }
}
