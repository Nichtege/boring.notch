using System;

namespace BoringNotch.Core
{
    /// <summary>
    /// Turns sound into one level per bar, as the Mac's MusicAudioAnalyzer does: bass, low mids, mids and highs. The sound
    /// is analyzed as it passes and never kept beyond the last 2048 samples in memory. Only for one thread at a time.
    /// </summary>
    public sealed class SpectrumBands
    {
        public const int BandCount = 4;

        private const int Size = 2048;
        private const int HalfSize = Size / 2;
        private const float QuietestPeak = 0.0005f;
        private const double SmallestRangeInDecibels = 8;
        private const double LimitDriftPerUpdate = 0.08;
        private const double Rise = 0.7;
        private const double Fall = 0.25;
        private const int UpdatesPerSecond = 30;

        // Where each bar starts and ends, in Hz
        private static readonly double[] BandEdges = { 60, 250, 1000, 4000, 14000 };

        private readonly double _sampleRate;
        private readonly int _framesPerUpdate;
        private readonly double[] _window = new double[Size];
        private readonly float[] _samples = new float[Size];
        private readonly double[] _real = new double[Size];
        private readonly double[] _imaginary = new double[Size];
        private readonly double[] _loudest = new double[BandCount];
        private readonly double[] _quietest = new double[BandCount];
        private readonly double[] _smoothed = new double[BandCount];
        private int _filled;
        private int _next;
        private int _framesSinceUpdate;

        public SpectrumBands(double sampleRate)
        {
            _sampleRate = sampleRate;
            _framesPerUpdate = Math.Max(1, (int)(sampleRate / UpdatesPerSecond));
            for (int i = 0; i < Size; i++)
            {
                _window[i] = 0.5 * Math.Sqrt(8.0 / 3) * (1 - Math.Cos(2 * Math.PI * i / Size));
            }
            for (int band = 0; band < BandCount; band++)
            {
                _loudest[band] = -200;
                _quietest[band] = 200;
            }
        }

        /// <summary>The levels of the last update. All 0 until there was sound.</summary>
        public double[] Levels => (double[])_smoothed.Clone();

        /// <summary>
        /// Takes interleaved 32-bit float sound in the bytes given. Returns new levels from 0 to 1 when they're due, and
        /// null when they aren't or when it's silent, so that the bars can fall back to something else.
        /// </summary>
        public double[] Feed(byte[] buffer, int bytes, int channels)
        {
            if (buffer == null || channels <= 0) return null;

            int frameBytes = channels * sizeof(float);
            int frames = Math.Min(bytes, buffer.Length) / frameBytes;
            for (int frame = 0; frame < frames; frame++)
            {
                float sum = 0;
                for (int channel = 0; channel < channels; channel++)
                {
                    sum += BitConverter.ToSingle(buffer, (frame * channels + channel) * sizeof(float));
                }
                _samples[_next] = sum / channels;
                _next = (_next + 1) % Size;
                if (_filled < Size) _filled++;
            }

            _framesSinceUpdate += frames;
            if (_filled < Size || _framesSinceUpdate < _framesPerUpdate) return null;
            _framesSinceUpdate = 0;

            return IsSilent() ? null : Analyze();
        }

        private bool IsSilent()
        {
            for (int i = 0; i < Size; i++)
            {
                if (Math.Abs(_samples[i]) > QuietestPeak) return false;
            }
            return true;
        }

        private double[] Analyze()
        {
            for (int i = 0; i < Size; i++)
            {
                // The ring starts at its oldest sample
                float sample = _samples[(_next + i) % Size];
                _real[i] = float.IsNaN(sample) || float.IsInfinity(sample) ? 0 : sample * _window[i];
                _imaginary[i] = 0;
            }
            Transform(_real, _imaginary);

            double hertzPerBin = _sampleRate / Size;
            for (int band = 0; band < BandCount; band++)
            {
                int low = Math.Max(1, (int)(BandEdges[band] / hertzPerBin));
                int high = Math.Min(HalfSize, Math.Max(low + 1, (int)(BandEdges[band + 1] / hertzPerBin)));

                double total = 0;
                int bins = 0;
                for (int bin = low; bin < high; bin++)
                {
                    total += 2 * Math.Sqrt(_real[bin] * _real[bin] + _imaginary[bin] * _imaginary[bin]);
                    bins++;
                }
                double mean = bins > 0 ? total / bins : 0;
                double decibels = 20 * Math.Log10(Math.Max(mean, 1e-7));

                // Each bar measures between its own recent quietest and loudest, so every song fills the whole height
                _loudest[band] = Math.Max(decibels, _loudest[band] - LimitDriftPerUpdate);
                _quietest[band] = Math.Min(decibels, _quietest[band] + LimitDriftPerUpdate);
                double range = Math.Max(_loudest[band] - _quietest[band], SmallestRangeInDecibels);
                double level = Math.Min(1, Math.Max(0, (decibels - _quietest[band]) / range));
                double shaped = level * level;

                // Up at once, down slowly, as a level meter does
                double speed = shaped > _smoothed[band] ? Rise : Fall;
                _smoothed[band] += (shaped - _smoothed[band]) * speed;
            }
            return Levels;
        }

        /// <summary>A plain radix-2 FFT in place. The size is a power of two.</summary>
        private static void Transform(double[] real, double[] imaginary)
        {
            int n = real.Length;
            for (int i = 1, j = 0; i < n; i++)
            {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1)
                {
                    j ^= bit;
                }
                j ^= bit;
                if (i < j)
                {
                    double swap = real[i];
                    real[i] = real[j];
                    real[j] = swap;
                    swap = imaginary[i];
                    imaginary[i] = imaginary[j];
                    imaginary[j] = swap;
                }
            }

            for (int length = 2; length <= n; length <<= 1)
            {
                double angle = -2 * Math.PI / length;
                double stepReal = Math.Cos(angle);
                double stepImaginary = Math.Sin(angle);
                for (int start = 0; start < n; start += length)
                {
                    double turnReal = 1;
                    double turnImaginary = 0;
                    for (int k = 0; k < length / 2; k++)
                    {
                        int top = start + k;
                        int bottom = top + length / 2;
                        double tempReal = real[bottom] * turnReal - imaginary[bottom] * turnImaginary;
                        double tempImaginary = real[bottom] * turnImaginary + imaginary[bottom] * turnReal;
                        real[bottom] = real[top] - tempReal;
                        imaginary[bottom] = imaginary[top] - tempImaginary;
                        real[top] += tempReal;
                        imaginary[top] += tempImaginary;

                        double nextTurn = turnReal * stepReal - turnImaginary * stepImaginary;
                        turnImaginary = turnReal * stepImaginary + turnImaginary * stepReal;
                        turnReal = nextTurn;
                    }
                }
            }
        }
    }
}
