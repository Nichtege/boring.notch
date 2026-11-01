using System;

namespace BoringNotch.Core
{
    /// <summary>
    /// The notch's springs, with the same meaning of response and damping as on the Mac:
    /// response is the period of the undamped spring in seconds, 1 for damping means no overshoot.
    /// </summary>
    public sealed class Spring
    {
        private const double StepLength = 1.0 / 240;
        private const double LongestFrame = 0.05;
        private const double RestDistance = 0.02;
        private const double RestSpeed = 0.5;

        private double _stiffness;
        private double _damping;

        public double Value { get; private set; }
        public double Target { get; private set; }
        public double Velocity { get; private set; }

        public bool IsSettled => Value == Target && Velocity == 0;

        public Spring(double value)
        {
            Value = value;
            Target = value;
            Configure(0.42, 0.8);
        }

        public void Configure(double response, double dampingFraction)
        {
            double frequency = 2 * Math.PI / response;
            _stiffness = frequency * frequency;
            _damping = 2 * dampingFraction * frequency;
        }

        public void SetTarget(double target) => Target = target;

        public void Snap()
        {
            Value = Target;
            Velocity = 0;
        }

        public void Step(double seconds)
        {
            if (IsSettled) return;

            // A long frame, like one after the PC slept, would otherwise throw the spring off
            double left = Math.Min(seconds, LongestFrame);
            while (left > 0)
            {
                double step = Math.Min(left, StepLength);
                double acceleration = -_stiffness * (Value - Target) - _damping * Velocity;
                Velocity += acceleration * step;
                Value += Velocity * step;
                left -= step;
            }

            if (Math.Abs(Value - Target) < RestDistance && Math.Abs(Velocity) < RestSpeed)
            {
                Snap();
            }
        }
    }
}
