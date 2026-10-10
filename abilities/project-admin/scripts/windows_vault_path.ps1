# Physical directory identity, including junctions/symlinks and path spelling.
# Source only; no Syncthing/config access or mutation.
if (-not ('Maxa.VaultDirectory' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Maxa {
    public static class VaultDirectory {
        [StructLayout(LayoutKind.Sequential)]
        private struct Information {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access,
            uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information info);
        private static Information Read(string path) {
            // OPEN_EXISTING + FILE_FLAG_BACKUP_SEMANTICS, follow reparse points.
            using (var handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                Information info;
                if (!GetFileInformationByHandle(handle, out info))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((info.Attributes & 0x10) == 0) throw new InvalidOperationException("Vault path is not a directory");
                return info;
            }
        }
        public static bool Same(string first, string second) {
            var a = Read(first); var b = Read(second);
            return a.Volume == b.Volume && a.IndexHigh == b.IndexHigh && a.IndexLow == b.IndexLow;
        }
    }
}
'@
}
function Test-SameVaultDirectory([string]$First, [string]$Second) {
    return [Maxa.VaultDirectory]::Same($First, $Second)
}
