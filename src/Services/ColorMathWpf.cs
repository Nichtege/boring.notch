using System.Windows.Media;

namespace BoringNotch.Core
{
    // The part that knows WPF's colors, so src/Core stays testable without Windows
    public static partial class ColorMath
    {
        public static Color EnsureMinimumBrightness(Color color, double factor)
        {
            Rgb result = EnsureMinimumBrightness(new Rgb(color.R, color.G, color.B), factor);
            return Color.FromArgb(color.A, result.R, result.G, result.B);
        }
    }
}
