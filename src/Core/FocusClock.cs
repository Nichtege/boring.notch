using System;

namespace BoringNotch.Core
{
    /// <summary>
    /// A session that counts down to a date and not by ticks, so a sleeping PC doesn't stretch it.
    /// It ends silently: the notch shows a banner once it can be seen.
    /// </summary>
    public sealed class FocusClock
    {
        private DateTime? _end;

        public double Duration { get; private set; }

        public bool IsRunning => _end != null;

        public void Start(DateTime now, double seconds)
        {
            Duration = seconds;
            _end = now.AddSeconds(seconds);
        }

        public void Stop() => _end = null;

        /// <summary>True once, at the moment the session is over.</summary>
        public bool Tick(DateTime now)
        {
            if (_end == null || now < _end.Value) return false;
            _end = null;
            return true;
        }

        public double Remaining(DateTime now)
        {
            return _end == null ? 0 : Math.Max(0, (_end.Value - now).TotalSeconds);
        }

        public double Progress(DateTime now)
        {
            if (Duration <= 0 || _end == null) return 0;
            return Math.Min(1, Math.Max(0, 1 - Remaining(now) / Duration));
        }

        /// <summary>24:13</summary>
        public string ClockText(DateTime now)
        {
            int seconds = (int)Math.Ceiling(Remaining(now));
            return string.Format("{0}:{1:00}", seconds / 60, seconds % 60);
        }

        /// <summary>What fits beside the closed notch: 24m, then 45s in the last minute.</summary>
        public string ShortText(DateTime now)
        {
            int seconds = (int)Math.Ceiling(Remaining(now));
            return seconds > 60 ? (int)Math.Ceiling(seconds / 60.0) + "m" : seconds + "s";
        }
    }
}
