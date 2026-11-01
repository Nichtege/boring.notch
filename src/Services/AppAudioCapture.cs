using System;
using System.Runtime.InteropServices;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wasapi.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace BoringNotch
{
    /// <summary>
    /// The sound of one process and its children, as Microsoft's Application Loopback sample gets it: nothing of any other
    /// app is in there. Windows 11 and newer versions of Windows 10 have this. Everything happens on the capture's own
    /// thread, and the sound only passes through to whoever listens.
    /// </summary>
    internal sealed class AppAudioCapture
    {
        public const int SampleRate = 44100;
        public const int Channels = 2;

        private const string LoopbackDevice = "VAD\\Process_Loopback";
        private const short VtBlob = 65;
        private const int ActivationTypeProcessLoopback = 1;
        private const int IncludeTargetProcessTree = 0;
        private const long BufferDuration = 2000000; // 200 ms, in steps of 100 ns
        private const int WaitMilliseconds = 100;
        // Some Windows versions may never answer this request at all
        private static readonly TimeSpan ActivationTimeout = TimeSpan.FromSeconds(3);

        private readonly int _process;
        private readonly Thread _thread;
        private volatile bool _isStopping;
        private short[] _samples = new short[0];
        private float[] _floats = new float[0];
        private byte[] _bytes = new byte[0];

        public AppAudioCapture(int process)
        {
            _process = process;
            _thread = new Thread(Run) { IsBackground = true, Name = "App audio" };
        }

        /// <summary>Interleaved 32-bit floats and how many bytes of them. On the capture's thread.</summary>
        public event Action<byte[], int> DataAvailable;

        /// <summary>Why it ended by itself, and whether any sound came before that. On the capture's thread.</summary>
        public event Action<Exception, bool> Failed;

        public bool HadData { get; private set; }

        public void Start() => _thread.Start();

        /// <summary>Ends within a moment. Doesn't wait long: a Windows call that hangs mustn't freeze the notch.</summary>
        public void Stop()
        {
            _isStopping = true;
            if (_thread.IsAlive && _thread != Thread.CurrentThread)
            {
                _thread.Join(500);
            }
        }

        private void Run()
        {
            AudioClient client = null;
            try
            {
                client = new AudioClient((IAudioClient)Activate());
                Capture(client);
            }
            catch (Exception e)
            {
                if (!_isStopping) Failed?.Invoke(e, HadData);
            }
            finally
            {
                try
                {
                    client?.Dispose();
                }
                catch (COMException)
                {
                    // The app or the device is gone, and with it what was to clean up
                }
            }
        }

        private object Activate()
        {
            int size = Marshal.SizeOf(typeof(ActivationParams));
            IntPtr parameters = Marshal.AllocHGlobal(size);
            // A PROPVARIANT holding a blob: its type first, then the size at 8 and the pointer one field later
            int variantSize = 16 + 2 * IntPtr.Size;
            IntPtr variant = Marshal.AllocHGlobal(variantSize);
            try
            {
                Marshal.StructureToPtr(
                    new ActivationParams
                    {
                        ActivationType = ActivationTypeProcessLoopback,
                        TargetProcessId = (uint)_process,
                        ProcessLoopbackMode = IncludeTargetProcessTree,
                    },
                    parameters,
                    false);
                for (int i = 0; i < variantSize; i++)
                {
                    Marshal.WriteByte(variant, i, 0);
                }
                Marshal.WriteInt16(variant, 0, VtBlob);
                Marshal.WriteInt32(variant, 8, size);
                Marshal.WriteIntPtr(variant, 8 + IntPtr.Size, parameters);

                var handler = new CompletionHandler();
                int result = ActivateAudioInterfaceAsync(LoopbackDevice, typeof(IAudioClient).GUID, variant, handler, out IActivateAudioInterfaceAsyncOperation operation);
                Marshal.ThrowExceptionForHR(result);
                if (!handler.Done.WaitOne(ActivationTimeout))
                {
                    throw new TimeoutException();
                }

                operation.GetActivateResult(out int activation, out object activated);
                Marshal.ThrowExceptionForHR(activation);
                return activated;
            }
            finally
            {
                Marshal.FreeHGlobal(variant);
                Marshal.FreeHGlobal(parameters);
            }
        }

        private void Capture(AudioClient client)
        {
            using (var wake = new AutoResetEvent(false))
            {
                client.Initialize(
                    AudioClientShareMode.Shared,
                    AudioClientStreamFlags.Loopback | AudioClientStreamFlags.EventCallback,
                    BufferDuration,
                    0,
                    new WaveFormat(SampleRate, 16, Channels),
                    Guid.Empty);
                client.SetEventHandle(wake.SafeWaitHandle.DangerousGetHandle());
                AudioCaptureClient capture = client.AudioCaptureClient;
                client.Start();

                while (!_isStopping)
                {
                    wake.WaitOne(WaitMilliseconds);
                    while (!_isStopping && capture.GetNextPacketSize() > 0)
                    {
                        IntPtr data = capture.GetBuffer(out int frames, out AudioClientBufferFlags flags);
                        Deliver(data, frames, (flags & AudioClientBufferFlags.Silent) != 0);
                        capture.ReleaseBuffer(frames);
                    }
                }
                client.Stop();
            }
        }

        private void Deliver(IntPtr data, int frames, bool isSilent)
        {
            int count = frames * Channels;
            if (count <= 0) return;
            if (_samples.Length < count)
            {
                _samples = new short[count];
                _floats = new float[count];
                _bytes = new byte[count * sizeof(float)];
            }

            if (isSilent)
            {
                Array.Clear(_floats, 0, count);
            }
            else
            {
                Marshal.Copy(data, _samples, 0, count);
                for (int i = 0; i < count; i++)
                {
                    _floats[i] = _samples[i] / 32768f;
                }
            }
            Buffer.BlockCopy(_floats, 0, _bytes, 0, count * sizeof(float));

            HadData = true;
            DataAvailable?.Invoke(_bytes, count * sizeof(float));
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ActivationParams
        {
            public int ActivationType;
            public uint TargetProcessId;
            public int ProcessLoopbackMode;
        }

        [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = true)]
        private static extern int ActivateAudioInterfaceAsync(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
            IntPtr activationParams,
            IActivateAudioInterfaceCompletionHandler completionHandler,
            out IActivateAudioInterfaceAsyncOperation activationOperation);

        // Windows calls the handler from a thread of its own, which it only does for an object that says it can take that
        [ComImport]
        [Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAgileObject
        {
        }

        private sealed class CompletionHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
        {
            public readonly ManualResetEvent Done = new ManualResetEvent(false);

            public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation)
            {
                Done.Set();
            }
        }
    }
}
