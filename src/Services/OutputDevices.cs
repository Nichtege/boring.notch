using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;

namespace BoringNotch
{
    internal sealed class OutputDevice
    {
        public string Id;
        public string Name;
        public bool IsCurrent;
    }

    /// <summary>
    /// What sound can come out of, and picking one. Windows has no public call for picking: everything that does it,
    /// EarTrumpet and SoundSwitch among them, uses the same undocumented interface as Windows' own sound settings.
    /// </summary>
    internal static class OutputDevices
    {
        private const int RoleConsole = 0;
        private const int RoleMultimedia = 1;
        private const int RoleCommunications = 2;

        /// <summary>Active outputs by name. Empty if none can be read, never an exception.</summary>
        public static IReadOnlyList<OutputDevice> List()
        {
            var devices = new List<OutputDevice>();
            try
            {
                using (var enumerator = new MMDeviceEnumerator())
                {
                    string current = CurrentId(enumerator);
                    MMDeviceCollection found = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
                    for (int index = 0; index < found.Count; index++)
                    {
                        using (MMDevice device = found[index])
                        {
                            devices.Add(new OutputDevice
                            {
                                Id = device.ID,
                                Name = device.FriendlyName,
                                IsCurrent = device.ID == current,
                            });
                        }
                    }
                }
            }
            catch (Exception e)
            {
                // No sound service, or a device going away this moment: there's then nothing to pick from
                Report("List", e);
            }
            return devices.OrderBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }

        /// <summary>Makes this the output for everything, as picking it in the Windows settings does. False if it didn't work.</summary>
        public static bool Select(string id)
        {
            if (string.IsNullOrEmpty(id)) return false;

            object client = null;
            try
            {
                client = new PolicyConfigClient();
                var policy = (IPolicyConfig)client;
                foreach (int role in new[] { RoleConsole, RoleMultimedia, RoleCommunications })
                {
                    int result = policy.SetDefaultEndpoint(id, role);
                    if (result < 0)
                    {
                        Log.Note("Ausgabe waehlen: 0x" + result.ToString("X8", CultureInfo.InvariantCulture));
                        return false;
                    }
                }
                return true;
            }
            catch (Exception e)
            {
                Report("Select", e);
                return false;
            }
            finally
            {
                if (client != null && Marshal.IsComObject(client))
                {
                    Marshal.ReleaseComObject(client);
                }
            }
        }

        private static string CurrentId(MMDeviceEnumerator enumerator)
        {
            if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)) return null;
            using (MMDevice device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
            {
                return device.ID;
            }
        }

        private static void Report(string where, Exception e)
        {
            Log.Note("Ausgabe " + where + ": " + e.GetType().Name + " 0x" + e.HResult.ToString("X8", CultureInfo.InvariantCulture));
        }

        [ComImport]
        [Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
        private class PolicyConfigClient
        {
        }

        /// <summary>
        /// Only the last-but-one method gets called, but all of them hold their place: what counts in a COM interface
        /// is the position. In this order in EarTrumpet and SoundSwitch alike, from Windows 7 on and again in Windows 10
        /// since 1607.
        /// </summary>
        [ComImport]
        [Guid("F8679F50-850A-41CF-9C72-430F290290C8")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPolicyConfig
        {
            [PreserveSig] int GetMixFormat();
            [PreserveSig] int GetDeviceFormat();
            [PreserveSig] int ResetDeviceFormat();
            [PreserveSig] int SetDeviceFormat();
            [PreserveSig] int GetProcessingPeriod();
            [PreserveSig] int SetProcessingPeriod();
            [PreserveSig] int GetShareMode();
            [PreserveSig] int SetShareMode();
            [PreserveSig] int GetPropertyValue();
            [PreserveSig] int SetPropertyValue();
            [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
            [PreserveSig] int SetEndpointVisibility();
        }
    }
}
