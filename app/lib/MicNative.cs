// Live microphone level for the checklist (Phase 11). Windows Core Audio (WASAPI): opens a shared capture stream on the
// default recording device and reads IAudioMeterInformation.GetPeakValue (0..1), the same level Windows Settings shows.
// Captured audio is discarded immediately (never stored or sent). C# 5 only (built-in csc). Compiled into
// app\native\WonderKid.Native.dll by tools\Build-Exe.ps1; the dev tree falls back to Add-Type of this file.
using System;
using System.Runtime.InteropServices;

namespace WonderKid
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr pointer; [FieldOffset(16)] public IntPtr pad; }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint padding);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    public static class MicMeter
    {
        const int CLSCTX_ALL = 23;
        static IAudioClient client;
        static IAudioCaptureClient capture;
        static IAudioMeterInformation meter;
        public static string DeviceName = "";
        public static string LastError = "";

        // Returns true when the stream runs. LastError: "nodevice", "denied" or a short code.
        public static bool Start()
        {
            Stop();
            LastError = ""; DeviceName = "";
            try
            {
                IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
                IMMDevice dev;
                int hr = en.GetDefaultAudioEndpoint(1, 0, out dev);   // eCapture, eConsole
                if (hr != 0 || dev == null) { LastError = "nodevice"; return false; }
                DeviceName = ReadName(dev);
                object o;
                Guid iidMeter = typeof(IAudioMeterInformation).GUID;
                hr = dev.Activate(ref iidMeter, CLSCTX_ALL, IntPtr.Zero, out o);
                if (hr != 0) { LastError = "meter 0x" + hr.ToString("X8"); return false; }
                meter = (IAudioMeterInformation)o;
                Guid iidClient = typeof(IAudioClient).GUID;
                hr = dev.Activate(ref iidClient, CLSCTX_ALL, IntPtr.Zero, out o);
                if (hr != 0) { LastError = "client 0x" + hr.ToString("X8"); Stop(); return false; }
                client = (IAudioClient)o;
                IntPtr fmt;
                hr = client.GetMixFormat(out fmt);
                if (hr != 0) { LastError = "format 0x" + hr.ToString("X8"); Stop(); return false; }
                hr = client.Initialize(0, 0, 2000000, 0, fmt, IntPtr.Zero);   // shared mode, 200 ms buffer
                Marshal.FreeCoTaskMem(fmt);
                if (hr != 0) { LastError = (hr == unchecked((int)0x80070005)) ? "denied" : "init 0x" + hr.ToString("X8"); Stop(); return false; }
                Guid iidCapture = typeof(IAudioCaptureClient).GUID;
                hr = client.GetService(ref iidCapture, out o);
                if (hr != 0) { LastError = "service 0x" + hr.ToString("X8"); Stop(); return false; }
                capture = (IAudioCaptureClient)o;
                hr = client.Start();
                if (hr != 0) { LastError = "start 0x" + hr.ToString("X8"); Stop(); return false; }
                return true;
            }
            catch (Exception ex) { LastError = ex.Message; Stop(); return false; }
        }

        // Current peak 0..1, or -1 when not running. Drains (discards) captured packets first.
        public static float Peak()
        {
            if (meter == null) { return -1f; }
            try
            {
                Drain();
                float p;
                if (meter.GetPeakValue(out p) != 0) { return -1f; }
                return p;
            }
            catch { return -1f; }
        }

        public static bool Running { get { return meter != null && client != null; } }

        static void Drain()
        {
            if (capture == null) { return; }
            uint size;
            int guard = 0;
            while (capture.GetNextPacketSize(out size) == 0 && size > 0 && guard++ < 64)
            {
                IntPtr data; uint frames; uint flags; ulong a; ulong b;
                if (capture.GetBuffer(out data, out frames, out flags, out a, out b) != 0) { break; }
                capture.ReleaseBuffer(frames);
            }
        }

        public static void Stop()
        {
            try { if (client != null) { client.Stop(); } } catch { }
            if (capture != null) { try { Marshal.ReleaseComObject(capture); } catch { } capture = null; }
            if (client != null) { try { Marshal.ReleaseComObject(client); } catch { } client = null; }
            if (meter != null) { try { Marshal.ReleaseComObject(meter); } catch { } meter = null; }
        }

        static string ReadName(IMMDevice dev)
        {
            try
            {
                IPropertyStore ps;
                if (dev.OpenPropertyStore(0, out ps) != 0 || ps == null) { return ""; }
                PropertyKey k = new PropertyKey();
                k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); k.pid = 14;   // PKEY_Device_FriendlyName
                PropVariant v;
                if (ps.GetValue(ref k, out v) != 0) { return ""; }
                if (v.vt == 31 && v.pointer != IntPtr.Zero) { return Marshal.PtrToStringUni(v.pointer); }   // VT_LPWSTR
            }
            catch { }
            return "";
        }
    }
}
