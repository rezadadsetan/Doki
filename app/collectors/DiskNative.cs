// Disk health straight from the drive, no third-party tools (Phase 4, D-016). C# 5 only (Add-Type with .NET Framework csc).
// NVMe: SMART / Health Information log (log page 0x02) through IOCTL_STORAGE_QUERY_PROPERTY with
// StorageDeviceProtocolSpecificProperty. The handle is opened with access 0, which Windows allows without administrator.
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace WonderKid
{
    public class NvmeHealth
    {
        public bool Ok;
        public string Error = "";
        public int CriticalWarning;
        public int TemperatureC;
        public int AvailableSpare;
        public int SpareThreshold;
        public int PercentageUsed;
        public double PowerOnHours;
        public double PowerCycles;
        public double UnsafeShutdowns;
        public double MediaErrors;
        public double DataWrittenTB;
        public double DataReadTB;
    }

    public static class DiskNative
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inLen, byte[] outBuf, int outLen, out int returned, IntPtr overlapped);

        private const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
        private const int HeaderSize = 8;          // STORAGE_PROPERTY_QUERY.PropertyId + QueryType
        private const int ProtocolDataSize = 40;   // STORAGE_PROTOCOL_SPECIFIC_DATA
        private const int LogSize = 512;

        // Low 64 bits of a 128-bit little-endian NVMe counter (enough for any real drive).
        private static double U128(byte[] b, int at) { return (double)BitConverter.ToUInt64(b, at); }

        // Parses a 512-byte NVMe SMART/Health log that starts at 'at'. Public so tests can feed a fake log.
        public static NvmeHealth ParseNvmeLog(byte[] b, int at)
        {
            NvmeHealth h = new NvmeHealth();
            if (b == null || b.Length < at + LogSize) { h.Error = "log too short"; return h; }
            h.CriticalWarning = b[at];
            int kelvin = BitConverter.ToUInt16(b, at + 1);
            h.TemperatureC = kelvin > 0 ? kelvin - 273 : 0;
            h.AvailableSpare = b[at + 3];
            h.SpareThreshold = b[at + 4];
            h.PercentageUsed = b[at + 5];   // may exceed 100 on worn drives
            h.DataReadTB = U128(b, at + 32) * 512000.0 / 1e12;     // units of 1000 * 512 bytes
            h.DataWrittenTB = U128(b, at + 48) * 512000.0 / 1e12;
            h.PowerCycles = U128(b, at + 112);
            h.PowerOnHours = U128(b, at + 128);
            h.UnsafeShutdowns = U128(b, at + 144);
            h.MediaErrors = U128(b, at + 160);
            h.Ok = true;
            return h;
        }

        public static NvmeHealth ReadNvme(int physicalDrive)
        {
            NvmeHealth fail = new NvmeHealth();
            try
            {
                using (SafeFileHandle h = CreateFile("\\\\.\\PhysicalDrive" + physicalDrive, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
                {
                    if (h.IsInvalid) { fail.Error = "open failed (" + Marshal.GetLastWin32Error() + ")"; return fail; }
                    int len = HeaderSize + ProtocolDataSize + LogSize;
                    byte[] q = new byte[len];
                    BitConverter.GetBytes(50).CopyTo(q, 0);                 // StorageDeviceProtocolSpecificProperty
                    BitConverter.GetBytes(0).CopyTo(q, 4);                  // PropertyStandardQuery
                    BitConverter.GetBytes(3).CopyTo(q, 8);                  // ProtocolTypeNvme
                    BitConverter.GetBytes(2).CopyTo(q, 12);                 // NVMeDataTypeLogPage
                    BitConverter.GetBytes(2).CopyTo(q, 16);                 // log page 0x02: SMART / Health
                    BitConverter.GetBytes(0).CopyTo(q, 20);
                    BitConverter.GetBytes(ProtocolDataSize).CopyTo(q, 24);  // ProtocolDataOffset
                    BitConverter.GetBytes(LogSize).CopyTo(q, 28);           // ProtocolDataLength
                    byte[] o = new byte[len];
                    int ret;
                    if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, q, len, o, len, out ret, IntPtr.Zero))
                    {
                        fail.Error = "ioctl failed (" + Marshal.GetLastWin32Error() + ")";
                        return fail;
                    }
                    if (ret < HeaderSize + ProtocolDataSize + 6) { fail.Error = "short answer (" + ret + " bytes)"; return fail; }
                    return ParseNvmeLog(o, HeaderSize + ProtocolDataSize);
                }
            }
            catch (Exception ex) { fail.Error = ex.GetType().Name + ": " + ex.Message; return fail; }
        }
    }
}
