namespace BoringNotch.Core
{
    public enum HoverAction
    {
        None,
        Open,
        Close,
    }

    /// <summary>
    /// When the mouse opens and closes the notch: open after 0.3 s on it, closed 0.1 s after it left.
    /// Fed with where the mouse is, so nothing depends on enter and leave events reaching a window that never activates.
    /// </summary>
    public sealed class HoverMachine
    {
        public const double OpenDelay = 0.3;
        public const double CloseDelay = 0.1;

        private double? _insideSince;
        private double? _outsideSince;
        private bool _mustLeaveFirst;

        /// <summary>The app closed the notch with the mouse still on it, which shouldn't open it right away.</summary>
        public void MustLeaveFirst()
        {
            _mustLeaveFirst = true;
            _insideSince = null;
        }

        public HoverAction Update(double now, bool inside, bool isOpen, bool holdOpen, bool canOpen)
        {
            if (isOpen)
            {
                _insideSince = null;
                if (inside || holdOpen)
                {
                    _outsideSince = null;
                    return HoverAction.None;
                }
                _outsideSince = _outsideSince ?? now;
                if (now - _outsideSince.Value >= CloseDelay)
                {
                    _outsideSince = null;
                    return HoverAction.Close;
                }
                return HoverAction.None;
            }

            _outsideSince = null;
            if (!inside)
            {
                _mustLeaveFirst = false;
                _insideSince = null;
                return HoverAction.None;
            }
            if (_mustLeaveFirst || !canOpen)
            {
                _insideSince = null;
                return HoverAction.None;
            }
            _insideSince = _insideSince ?? now;
            if (now - _insideSince.Value >= OpenDelay)
            {
                _insideSince = null;
                return HoverAction.Open;
            }
            return HoverAction.None;
        }
    }
}
