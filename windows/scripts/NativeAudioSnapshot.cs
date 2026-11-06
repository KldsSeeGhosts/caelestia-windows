using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Caelestia.AudioSnapshot {
    // COM declarations follow Windows SDK 10.0.26100.0 mmdeviceapi.h and
    // endpointvolume.h. Capture only calls enumeration/getters, never setters.
    public static class Native {
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class DeviceEnumerator {}

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IEnumerator {
            [PreserveSig] int EnumAudioEndpoints(int flow, uint mask, out ICollection devices);
            [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IDevice device);
        }

        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ICollection {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int Item(uint index, out IDevice device);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDevice {
            [PreserveSig] int Activate(ref Guid id, uint context, IntPtr parameters,
                [MarshalAs(UnmanagedType.IUnknown)] out object instance);
            [PreserveSig] int OpenPropertyStore(uint access, out IntPtr store);
            [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
            [PreserveSig] int GetState(out uint state);
        }

        [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IVolume {
            [PreserveSig] int RegisterControlChangeNotify(IntPtr callback);
            [PreserveSig] int UnregisterControlChangeNotify(IntPtr callback);
            [PreserveSig] int GetChannelCount(out uint count);
            [PreserveSig] int SetMasterVolumeLevel(float value, IntPtr context);
            [PreserveSig] int SetMasterVolumeLevelScalar(float value, IntPtr context);
            [PreserveSig] int GetMasterVolumeLevel(out float value);
            [PreserveSig] int GetMasterVolumeLevelScalar(out float value);
            [PreserveSig] int SetChannelVolumeLevel(uint channel, float value, IntPtr context);
            [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float value, IntPtr context);
            [PreserveSig] int GetChannelVolumeLevel(uint channel, out float value);
            [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float value);
            [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool value, IntPtr context);
            [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool value);
        }

        public sealed class Endpoint {
            public string IdHash, Flow;
            public double? Volume;
            public bool? Muted;
            public double[] Channels;
            public List<string> Errors = new List<string>();
        }
        public sealed class Result {
            public SortedDictionary<string, string> Defaults = new SortedDictionary<string, string>();
            public List<Endpoint> Endpoints = new List<Endpoint>();
            public List<string> Errors = new List<string>();
        }

        private static string HashId(IDevice device) {
            string id;
            Marshal.ThrowExceptionForHR(device.GetId(out id));
            using (SHA256 hash = SHA256.Create()) {
                return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(id)))
                    .Replace("-", "").ToLowerInvariant();
            }
        }
        private static void Release(object value) {
            if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
        }
        private static bool Check(int hr, string operation, List<string> errors) {
            if (hr >= 0) return true;
            errors.Add(operation + ": 0x" + ((uint)hr).ToString("X8"));
            return false;
        }
        private static Endpoint ReadEndpoint(IDevice device, string flow) {
            Endpoint result = new Endpoint { IdHash = HashId(device), Flow = flow };
            object raw = null;
            try {
                Guid id = typeof(IVolume).GUID;
                if (!Check(device.Activate(ref id, 23, IntPtr.Zero, out raw),
                    "Activate(IAudioEndpointVolume)", result.Errors)) return result;
                IVolume volume = (IVolume)raw;
                float level;
                bool muted;
                if (Check(volume.GetMasterVolumeLevelScalar(out level), "GetMasterVolumeLevelScalar", result.Errors))
                    result.Volume = Math.Round(level, 6);
                if (Check(volume.GetMute(out muted), "GetMute", result.Errors)) result.Muted = muted;
                uint count;
                if (Check(volume.GetChannelCount(out count), "GetChannelCount", result.Errors)) {
                    List<double> channels = new List<double>();
                    for (uint i = 0; i < count; i++) {
                        if (Check(volume.GetChannelVolumeLevelScalar(i, out level),
                            "GetChannelVolumeLevelScalar(" + i + ")", result.Errors))
                            channels.Add(Math.Round(level, 6));
                    }
                    result.Channels = channels.ToArray();
                }
            } finally { Release(raw); }
            return result;
        }

        public static Result Capture() {
            Result result = new Result();
            IEnumerator enumerator = (IEnumerator)new DeviceEnumerator();
            try {
                for (int flow = 0; flow < 2; flow++) {
                    string flowName = flow == 0 ? "render" : "capture";
                    string[] roles = { "console", "multimedia", "communications" };
                    for (int role = 0; role < roles.Length; role++) {
                        IDevice device = null;
                        try {
                            int hr = enumerator.GetDefaultAudioEndpoint(flow, role, out device);
                            // E_NOTFOUND means this role has no default endpoint.
                            if (hr == unchecked((int)0x80070490))
                                result.Defaults.Add(flowName + "." + roles[role], null);
                            else if (Check(hr, "GetDefaultAudioEndpoint(" + flowName + "," + roles[role] + ")", result.Errors))
                                result.Defaults.Add(flowName + "." + roles[role], HashId(device));
                        } finally { Release(device); }
                    }
                    ICollection devices = null;
                    try {
                        if (!Check(enumerator.EnumAudioEndpoints(flow, 1, out devices),
                            "EnumAudioEndpoints(" + flowName + ")", result.Errors)) continue;
                        uint count;
                        if (!Check(devices.GetCount(out count), "GetCount", result.Errors)) continue;
                        for (uint i = 0; i < count; i++) {
                            IDevice device = null;
                            try {
                                if (Check(devices.Item(i, out device), "Item", result.Errors))
                                    result.Endpoints.Add(ReadEndpoint(device, flowName));
                            } finally { Release(device); }
                        }
                    } finally { Release(devices); }
                }
            } finally { Release(enumerator); }
            result.Endpoints.Sort((a, b) => String.CompareOrdinal(a.IdHash, b.IdHash));
            return result;
        }
    }
}
