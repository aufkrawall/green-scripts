<#
.SYNOPSIS
    Set NVIDIA output color depth to 8, 10, or 12 bpc while keeping Windows Advanced Color/ACM disabled best-effort.

.DESCRIPTION
    This is a PowerShell port of the working Python NVAPI script.

    It uses embedded C# interop to call:
      - Windows DisplayConfig APIs to disable Advanced Color / HDR / WCG states
      - NVIDIA NVAPI NvAPI_Disp_ColorControl to set output color depth

    By default it first shows a numbered display-selection menu, then asks which bit depth to set: 8, 10, or 12 bpc.
    The display-selection menu is shown whenever no -Display or -AllDisplays argument is supplied,
    even when only one NVIDIA display is connected.

    You can pass -Bits 8, -Bits 10, or -Bits 12 for non-interactive bit-depth selection.
    You can pass -Display DISPLAY1, -Display 1, or -Display 0xDISPLAYID for non-interactive display selection.
    Use -AllDisplays to apply the selected bit depth to every active NVIDIA display.

.NOTES
    Requirements:
      - Windows 10/11
      - NVIDIA driver with NVAPI installed
      - 64-bit PowerShell is recommended
      - Run as Administrator for the Windows color-state and registry guards

    This is a best-effort guard. Windows can re-enable Advanced Color / ACM later.
#>

[CmdletBinding()]
param(
    [ValidateSet(0, 8, 10, 12)]
    [int]$Bits = 0,

    [string]$Display,

    [switch]$AllDisplays,

    [switch]$DryRun,

    [switch]$ForceRgbFull,

    [switch]$SkipSupportCheck,

    [switch]$StrictDesktopDepth,

    [switch]$NoWindowsAcmGuard,

    [switch]$NoRegistryGuard,

    [int]$GuardPasses = 4,

    [double]$GuardDelaySeconds = 0.40,

    [switch]$VerboseDetails
)

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Error 'This script must be run on Windows.'
    exit 2
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-TargetBits {
    param([int]$RequestedBits)

    if (@(8, 10, 12) -contains $RequestedBits) {
        return $RequestedBits
    }

    while ($true) {
        $answer = Read-Host 'Choose NVIDIA output color depth in bpc (8, 10, or 12)'
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and (@(8, 10, 12) -contains $parsed)) {
            return $parsed
        }
        Write-Host 'Enter only 8, 10, or 12.'
    }
}

function Set-AcmDeveloperPreviewOff {
    param([bool]$ShowDetails)

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $name = 'EnableAcmSupportDeveloperPreview'

    try {
        New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        if ($ShowDetails) {
            Write-Host "Set $path\$name=0"
        }
        return $true
    }
    catch [System.UnauthorizedAccessException] {
        Write-Host 'Registry guard skipped: Administrator rights are required for HKLM writes.'
        return $false
    }
    catch {
        Write-Host "Registry guard skipped: $($_.Exception.Message)"
        return $false
    }
}

$csharp = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WinDisplayConfig
{
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;
    private const int ERROR_INVALID_PARAMETER = 87;

    private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;

    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO = 9;
    private const uint DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE = 10;
    private const uint DISPLAYCONFIG_DEVICE_INFO_SET_HDR_STATE = 16;
    private const uint DISPLAYCONFIG_DEVICE_INFO_SET_WCG_STATE = 17;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_RATIONAL
    {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_2DREGION
    {
        public uint cx;
        public uint cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINTL
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECTL
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_SOURCE_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        public int targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_INFO
    {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO
    {
        public ulong pixelRate;
        public DISPLAYCONFIG_RATIONAL hSyncFreq;
        public DISPLAYCONFIG_RATIONAL vSyncFreq;
        public DISPLAYCONFIG_2DREGION activeSize;
        public DISPLAYCONFIG_2DREGION totalSize;
        public uint videoStandard;
        public uint scanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_TARGET_MODE
    {
        public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_SOURCE_MODE
    {
        public uint width;
        public uint height;
        public uint pixelFormat;
        public POINTL position;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_DESKTOP_IMAGE_INFO
    {
        public POINTL PathSourceSize;
        public RECTL DesktopImageRegion;
        public RECTL DesktopImageClip;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct DISPLAYCONFIG_MODE_INFO_UNION
    {
        [FieldOffset(0)] public DISPLAYCONFIG_TARGET_MODE targetMode;
        [FieldOffset(0)] public DISPLAYCONFIG_SOURCE_MODE sourceMode;
        [FieldOffset(0)] public DISPLAYCONFIG_DESKTOP_IMAGE_INFO desktopImageInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_MODE_INFO
    {
        public uint infoType;
        public uint id;
        public LUID adapterId;
        public DISPLAYCONFIG_MODE_INFO_UNION modeInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_DEVICE_INFO_HEADER
    {
        public uint type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAYCONFIG_TARGET_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_SET_BOOLEAN_STATE
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint value;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint value;
        public uint colorEncoding;
        public uint bitsPerColorChannel;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(
        uint flags,
        out uint numPathArrayElements,
        out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(
        uint flags,
        ref uint numPathArrayElements,
        [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
        ref uint numModeInfoArrayElements,
        [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
        IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SET_BOOLEAN_STATE requestPacket);

    private static string WinErrorText(int code)
    {
        return new System.ComponentModel.Win32Exception(code).Message;
    }

    private static List<DISPLAYCONFIG_PATH_INFO> GetActiveDisplayPaths()
    {
        uint pathCount;
        uint modeCount;
        int ret = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
        if (ret != ERROR_SUCCESS)
        {
            throw new InvalidOperationException("GetDisplayConfigBufferSizes failed: " + ret + " " + WinErrorText(ret));
        }

        for (int attempt = 0; attempt < 5; attempt++)
        {
            DISPLAYCONFIG_PATH_INFO[] paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
            DISPLAYCONFIG_MODE_INFO[] modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
            uint pc = pathCount;
            uint mc = modeCount;

            ret = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pc, paths, ref mc, modes, IntPtr.Zero);
            if (ret == ERROR_SUCCESS)
            {
                List<DISPLAYCONFIG_PATH_INFO> result = new List<DISPLAYCONFIG_PATH_INFO>();
                for (int i = 0; i < pc; i++)
                {
                    result.Add(paths[i]);
                }
                return result;
            }

            if (ret == ERROR_INSUFFICIENT_BUFFER)
            {
                ret = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
                if (ret != ERROR_SUCCESS)
                {
                    throw new InvalidOperationException("GetDisplayConfigBufferSizes failed: " + ret + " " + WinErrorText(ret));
                }
                continue;
            }

            throw new InvalidOperationException("QueryDisplayConfig failed: " + ret + " " + WinErrorText(ret));
        }

        throw new InvalidOperationException("QueryDisplayConfig failed repeatedly because display topology changed.");
    }

    private static string NormalizeDisplayName(string name)
    {
        if (name == null) return "";
        string n = name.Trim().ToUpperInvariant();
        n = n.Replace("\\\\.\\", "");
        n = n.Replace("\\", "");
        return n;
    }

    private static string QuerySourceDeviceName(DISPLAYCONFIG_PATH_INFO path)
    {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME info = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
        info.viewGdiDeviceName = new string('\0', 32);
        info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        info.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME));
        info.header.adapterId = path.sourceInfo.adapterId;
        info.header.id = path.sourceInfo.id;

        int ret = DisplayConfigGetDeviceInfo(ref info);
        if (ret != ERROR_SUCCESS)
        {
            return "";
        }
        return CleanDisplayString(info.viewGdiDeviceName);
    }

    private static DISPLAYCONFIG_TARGET_DEVICE_NAME? QueryTargetDeviceName(DISPLAYCONFIG_PATH_INFO path)
    {
        DISPLAYCONFIG_TARGET_DEVICE_NAME info = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
        info.monitorFriendlyDeviceName = new string('\0', 64);
        info.monitorDevicePath = new string('\0', 128);
        info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        info.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
        info.header.adapterId = path.targetInfo.adapterId;
        info.header.id = path.targetInfo.id;

        int ret = DisplayConfigGetDeviceInfo(ref info);
        if (ret != ERROR_SUCCESS)
        {
            return null;
        }
        return info;
    }

    private static string CleanDisplayString(string value)
    {
        if (value == null) return "";
        int nul = value.IndexOf('\0');
        if (nul >= 0) value = value.Substring(0, nul);
        return value.Trim();
    }

    private static string OutputTechnologyName(uint value)
    {
        if (value == 0xFFFFFFFF) return "other";
        if (value == 0) return "HD15/VGA";
        if (value == 1) return "S-Video";
        if (value == 2) return "Composite";
        if (value == 3) return "Component";
        if (value == 4) return "DVI";
        if (value == 5) return "HDMI";
        if (value == 6) return "LVDS";
        if (value == 8) return "D-JPN";
        if (value == 9) return "SDI";
        if (value == 10) return "DisplayPort";
        if (value == 11) return "Embedded DisplayPort";
        if (value == 12) return "UDI external";
        if (value == 13) return "UDI embedded";
        if (value == 14) return "SDTV dongle";
        if (value == 15) return "Miracast";
        if (value == 16) return "Indirect wired";
        if (value == 17) return "Indirect virtual";
        if (value == 0x80000000) return "Internal";
        return "outputTechnology=" + value.ToString();
    }

    public static string[] GetDisplayDetailsForSourceName(string gdiDisplayName)
    {
        string wanted = NormalizeDisplayName(gdiDisplayName);
        try
        {
            List<DISPLAYCONFIG_PATH_INFO> paths = GetActiveDisplayPaths();
            foreach (DISPLAYCONFIG_PATH_INFO path in paths)
            {
                string source = QuerySourceDeviceName(path);
                if (NormalizeDisplayName(source) != wanted)
                {
                    continue;
                }

                string friendly = "";
                string connection = "";
                string devicePath = "";
                string edid = "";

                DISPLAYCONFIG_TARGET_DEVICE_NAME? maybeTarget = QueryTargetDeviceName(path);
                if (maybeTarget.HasValue)
                {
                    DISPLAYCONFIG_TARGET_DEVICE_NAME target = maybeTarget.Value;
                    friendly = CleanDisplayString(target.monitorFriendlyDeviceName);
                    connection = OutputTechnologyName(target.outputTechnology);
                    devicePath = CleanDisplayString(target.monitorDevicePath);
                    if (target.edidManufactureId != 0 || target.edidProductCodeId != 0)
                    {
                        edid = "edid=0x" + target.edidManufactureId.ToString("X4") + ":0x" + target.edidProductCodeId.ToString("X4");
                    }
                }

                return new string[] { source, friendly, connection, devicePath, edid };
            }
        }
        catch
        {
        }

        return new string[] { gdiDisplayName == null ? "" : gdiDisplayName, "", "", "", "" };
    }

    private static bool PathIsSelected(DISPLAYCONFIG_PATH_INFO path, string[] selectedDisplayNames)
    {
        if (selectedDisplayNames == null || selectedDisplayNames.Length == 0)
        {
            return true;
        }

        string sourceName = NormalizeDisplayName(QuerySourceDeviceName(path));
        if (sourceName.Length == 0)
        {
            // If Windows cannot report the GDI source name, do not risk changing unrelated displays.
            return false;
        }

        foreach (string selected in selectedDisplayNames)
        {
            if (sourceName == NormalizeDisplayName(selected))
            {
                return true;
            }
        }
        return false;
    }

    private static DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO? QueryAdvancedColorInfo(DISPLAYCONFIG_PATH_INFO path)
    {
        DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO info = new DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO();
        info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
        info.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO));
        info.header.adapterId = path.targetInfo.adapterId;
        info.header.id = path.targetInfo.id;

        int ret = DisplayConfigGetDeviceInfo(ref info);
        if (ret != ERROR_SUCCESS)
        {
            return null;
        }
        return info;
    }

    private static int SetDisplayBooleanState(DISPLAYCONFIG_PATH_INFO path, uint infoType, uint value)
    {
        DISPLAYCONFIG_SET_BOOLEAN_STATE req = new DISPLAYCONFIG_SET_BOOLEAN_STATE();
        req.header.type = infoType;
        req.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SET_BOOLEAN_STATE));
        req.header.adapterId = path.targetInfo.adapterId;
        req.header.id = path.targetInfo.id;
        req.value = value;
        return DisplayConfigSetDeviceInfo(ref req);
    }

    public static int[] DisableAdvancedColorOnce(bool verbose, string[] selectedDisplayNames)
    {
        int successes = 0;
        int ignored = 0;
        HashSet<string> seen = new HashSet<string>();

        List<DISPLAYCONFIG_PATH_INFO> paths = GetActiveDisplayPaths();
        foreach (DISPLAYCONFIG_PATH_INFO path in paths)
        {
            if (!PathIsSelected(path, selectedDisplayNames))
            {
                continue;
            }

            string sourceName = QuerySourceDeviceName(path);
            string key = path.targetInfo.adapterId.LowPart.ToString() + ":" + path.targetInfo.adapterId.HighPart.ToString() + ":" + path.targetInfo.id.ToString();
            if (seen.Contains(key))
            {
                continue;
            }
            seen.Add(key);

            uint[] infoTypes = new uint[] {
                DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE,
                DISPLAYCONFIG_DEVICE_INFO_SET_HDR_STATE,
                DISPLAYCONFIG_DEVICE_INFO_SET_WCG_STATE
            };

            foreach (uint infoType in infoTypes)
            {
                int ret = SetDisplayBooleanState(path, infoType, 0);
                if (ret == ERROR_SUCCESS)
                {
                    successes++;
                    if (verbose)
                    {
                        Console.WriteLine("DisplayConfig type " + infoType + ": disabled on " + sourceName + " target " + key);
                    }
                }
                else if (ret == ERROR_INVALID_PARAMETER)
                {
                    ignored++;
                }
                else
                {
                    ignored++;
                    if (verbose)
                    {
                        Console.WriteLine("DisplayConfig type " + infoType + ": ignored on " + sourceName + " target " + key + ": " + ret + " " + WinErrorText(ret));
                    }
                }
            }
        }

        return new int[] { successes, ignored };
    }

    public static void PrintAdvancedColorSnapshot(string label, string[] selectedDisplayNames)
    {
        Console.WriteLine();
        Console.WriteLine("Windows Advanced Color state snapshot: " + label);

        try
        {
            List<DISPLAYCONFIG_PATH_INFO> paths = GetActiveDisplayPaths();
            HashSet<string> seen = new HashSet<string>();

            foreach (DISPLAYCONFIG_PATH_INFO path in paths)
            {
                if (!PathIsSelected(path, selectedDisplayNames))
                {
                    continue;
                }

                string sourceName = QuerySourceDeviceName(path);
                string key = path.targetInfo.adapterId.LowPart.ToString() + ":" + path.targetInfo.adapterId.HighPart.ToString() + ":" + path.targetInfo.id.ToString();
                if (seen.Contains(key))
                {
                    continue;
                }
                seen.Add(key);

                DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO? maybeInfo = QueryAdvancedColorInfo(path);
                if (!maybeInfo.HasValue)
                {
                    Console.WriteLine("  " + sourceName + " target=" + key + ": Advanced Color info unavailable");
                    continue;
                }

                DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO info = maybeInfo.Value;
                bool supported = (info.value & 0x1) != 0;
                bool enabled = ((info.value >> 1) & 0x1) != 0;
                bool wideColorEnforced = ((info.value >> 2) & 0x1) != 0;
                bool forceDisabled = ((info.value >> 3) & 0x1) != 0;

                Console.WriteLine(
                    "  " + sourceName + " target=" + key +
                    ": supported=" + supported +
                    ", enabled=" + enabled +
                    ", force_disabled=" + forceDisabled +
                    ", wide_color_enforced=" + wideColorEnforced +
                    ", bits_per_channel=" + info.bitsPerColorChannel);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("  Could not query DisplayConfig: " + ex.Message);
        }
    }
}

public static class NvApiColorControl
{
    private const int NVAPI_OK = 0;
    private const int NVAPI_END_ENUMERATION = -7;

    private const uint ID_NvAPI_Initialize = 0x0150E828;
    private const uint ID_NvAPI_Unload = 0xD22BDD7E;
    private const uint ID_NvAPI_GetErrorMessage = 0x6C2D048C;
    private const uint ID_NvAPI_EnumNvidiaDisplayHandle = 0x9ABDD40D;
    private const uint ID_NvAPI_GetAssociatedNvidiaDisplayName = 0x22A78B05;
    private const uint ID_NvAPI_DISP_GetDisplayIdByDisplayName = 0xAE457190;
    private const uint ID_NvAPI_Disp_ColorControl = 0x92F9D80D;

    private const byte NV_COLOR_CMD_GET = 1;
    private const byte NV_COLOR_CMD_SET = 2;
    private const byte NV_COLOR_CMD_IS_SUPPORTED_COLOR = 3;

    private const byte NV_COLOR_FORMAT_RGB = 0;
    private const byte NV_COLOR_COLORIMETRY_RGB = 0;
    private const byte NV_COLOR_DYNAMIC_RANGE_VESA = 0;

    private const uint NV_BPC_DEFAULT = 0;
    private const uint NV_BPC_6 = 1;
    private const uint NV_BPC_8 = 2;
    private const uint NV_BPC_10 = 3;
    private const uint NV_BPC_12 = 4;
    private const uint NV_BPC_16 = 5;

    private const uint NV_COLOR_SELECTION_POLICY_USER = 0;

    private const uint NV_DESKTOP_COLOR_DEPTH_DEFAULT = 0;
    private const uint NV_DESKTOP_COLOR_DEPTH_8BPC = 1;
    private const uint NV_DESKTOP_COLOR_DEPTH_10BPC = 2;
    private const uint NV_DESKTOP_COLOR_DEPTH_16BPC_FLOAT = 3;

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_COLOR_DATA_V5_DATA
    {
        public byte colorFormat;
        public byte colorimetry;
        public byte dynamicRange;
        public uint bpc;
        public uint colorSelectionPolicy;
        public uint depth;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_COLOR_DATA_V5
    {
        public uint version;
        public ushort size;
        public byte cmd;
        public NV_COLOR_DATA_V5_DATA data;
    }

    private class DisplayInfo
    {
        public uint Index;
        public IntPtr Handle;
        public string Name;
        public string FriendlyName;
        public string ConnectionType;
        public string MonitorDevicePath;
        public string EdidText;
        public uint DisplayId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true)]
    private static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr hModule);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr NvAPI_QueryInterfaceDelegate(uint id);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_InitializeDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_UnloadDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_GetErrorMessageDelegate(int status, [MarshalAs(UnmanagedType.LPStr)] StringBuilder message);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_EnumNvidiaDisplayHandleDelegate(uint index, out IntPtr handle);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_GetAssociatedNvidiaDisplayNameDelegate(IntPtr handle, [MarshalAs(UnmanagedType.LPStr)] StringBuilder name);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_GetDisplayIdByDisplayNameDelegate([MarshalAs(UnmanagedType.LPStr)] string displayName, out uint displayId);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_Disp_ColorControlDelegate(uint displayId, ref NV_COLOR_DATA_V5 colorData);

    private class NvApi : IDisposable
    {
        private IntPtr dllHandle;
        private NvAPI_QueryInterfaceDelegate query;

        private NvAPI_InitializeDelegate initialize;
        private NvAPI_UnloadDelegate unload;
        private NvAPI_GetErrorMessageDelegate getErrorMessage;
        private NvAPI_EnumNvidiaDisplayHandleDelegate enumDisplayHandle;
        private NvAPI_GetAssociatedNvidiaDisplayNameDelegate getDisplayName;
        private NvAPI_GetDisplayIdByDisplayNameDelegate getDisplayIdByDisplayName;
        private NvAPI_Disp_ColorControlDelegate colorControl;

        public NvApi()
        {
            string[] names;
            if (Environment.Is64BitProcess)
            {
                names = new string[] { "nvapi64.dll", "nvapi.dll" };
            }
            else
            {
                names = new string[] { "nvapi.dll", "nvapi64.dll" };
            }

            Exception last = null;
            foreach (string name in names)
            {
                dllHandle = LoadLibrary(name);
                if (dllHandle != IntPtr.Zero)
                {
                    break;
                }
                last = new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }

            if (dllHandle == IntPtr.Zero)
            {
                throw new InvalidOperationException("Could not load nvapi.dll/nvapi64.dll: " + (last == null ? "unknown error" : last.Message));
            }

            IntPtr q = GetProcAddress(dllHandle, "nvapi_QueryInterface");
            if (q == IntPtr.Zero)
            {
                throw new InvalidOperationException("nvapi_QueryInterface was not found in the NVAPI DLL.");
            }

            query = (NvAPI_QueryInterfaceDelegate)Marshal.GetDelegateForFunctionPointer(q, typeof(NvAPI_QueryInterfaceDelegate));

            initialize = GetFunction<NvAPI_InitializeDelegate>(ID_NvAPI_Initialize);
            unload = GetFunction<NvAPI_UnloadDelegate>(ID_NvAPI_Unload);
            getErrorMessage = GetFunction<NvAPI_GetErrorMessageDelegate>(ID_NvAPI_GetErrorMessage);
            enumDisplayHandle = GetFunction<NvAPI_EnumNvidiaDisplayHandleDelegate>(ID_NvAPI_EnumNvidiaDisplayHandle);
            getDisplayName = GetFunction<NvAPI_GetAssociatedNvidiaDisplayNameDelegate>(ID_NvAPI_GetAssociatedNvidiaDisplayName);
            getDisplayIdByDisplayName = GetFunction<NvAPI_GetDisplayIdByDisplayNameDelegate>(ID_NvAPI_DISP_GetDisplayIdByDisplayName);
            colorControl = GetFunction<NvAPI_Disp_ColorControlDelegate>(ID_NvAPI_Disp_ColorControl);
        }

        private T GetFunction<T>(uint id) where T : class
        {
            IntPtr ptr = query(id);
            if (ptr == IntPtr.Zero)
            {
                throw new InvalidOperationException("NVAPI function 0x" + id.ToString("X8") + " is unavailable.");
            }
            return Marshal.GetDelegateForFunctionPointer(ptr, typeof(T)) as T;
        }

        public void Initialize()
        {
            Check(initialize(), "NvAPI_Initialize");
        }

        public void Dispose()
        {
            try
            {
                if (unload != null)
                {
                    unload();
                }
            }
            catch
            {
            }

            if (dllHandle != IntPtr.Zero)
            {
                FreeLibrary(dllHandle);
                dllHandle = IntPtr.Zero;
            }
        }

        public void Check(int status, string action)
        {
            if (status == NVAPI_OK)
            {
                return;
            }
            throw new InvalidOperationException(action + " failed: " + StatusText(status) + " (" + status + ")");
        }

        public string StatusText(int status)
        {
            try
            {
                StringBuilder sb = new StringBuilder(64);
                if (getErrorMessage(status, sb) == NVAPI_OK)
                {
                    return sb.ToString();
                }
            }
            catch
            {
            }
            return "Unknown NVAPI error";
        }

        public List<DisplayInfo> EnumerateDisplays()
        {
            List<DisplayInfo> result = new List<DisplayInfo>();

            for (uint index = 0; ; index++)
            {
                IntPtr handle;
                int status = enumDisplayHandle(index, out handle);
                if (status == NVAPI_END_ENUMERATION)
                {
                    break;
                }
                Check(status, "NvAPI_EnumNvidiaDisplayHandle(" + index + ")");

                StringBuilder name = new StringBuilder(64);
                status = getDisplayName(handle, name);
                Check(status, "NvAPI_GetAssociatedNvidiaDisplayName(" + index + ")");

                uint displayId;
                status = getDisplayIdByDisplayName(name.ToString(), out displayId);
                Check(status, "NvAPI_DISP_GetDisplayIdByDisplayName(" + name.ToString() + ")");

                DisplayInfo info = new DisplayInfo();
                info.Index = index;
                info.Handle = handle;
                info.Name = name.ToString();
                info.DisplayId = displayId;

                string[] details = WinDisplayConfig.GetDisplayDetailsForSourceName(info.Name);
                if (details != null && details.Length >= 5)
                {
                    if (!String.IsNullOrWhiteSpace(details[0])) info.Name = details[0];
                    info.FriendlyName = details[1];
                    info.ConnectionType = details[2];
                    info.MonitorDevicePath = details[3];
                    info.EdidText = details[4];
                }

                result.Add(info);
            }

            return result;
        }

        public NV_COLOR_DATA_V5 GetColor(uint displayId)
        {
            NV_COLOR_DATA_V5 color = NewColorData(NV_COLOR_CMD_GET);
            Check(colorControl(displayId, ref color), "NvAPI_Disp_ColorControl(GET)");
            return color;
        }

        public int IsSupportedColor(uint displayId, NV_COLOR_DATA_V5 color)
        {
            NV_COLOR_DATA_V5 probe = color;
            probe.cmd = NV_COLOR_CMD_IS_SUPPORTED_COLOR;
            return colorControl(displayId, ref probe);
        }

        public void SetColor(uint displayId, NV_COLOR_DATA_V5 color)
        {
            NV_COLOR_DATA_V5 desired = color;
            desired.cmd = NV_COLOR_CMD_SET;
            Check(colorControl(displayId, ref desired), "NvAPI_Disp_ColorControl(SET)");
        }
    }

    private static uint MakeNvApiVersion(Type structType, uint version)
    {
        return (uint)Marshal.SizeOf(structType) | (version << 16);
    }

    private static NV_COLOR_DATA_V5 NewColorData(byte cmd)
    {
        NV_COLOR_DATA_V5 data = new NV_COLOR_DATA_V5();
        data.version = MakeNvApiVersion(typeof(NV_COLOR_DATA_V5), 5);
        data.size = (ushort)Marshal.SizeOf(typeof(NV_COLOR_DATA_V5));
        data.cmd = cmd;
        return data;
    }

    private static uint TargetBpcValue(int bits)
    {
        if (bits == 8) return NV_BPC_8;
        if (bits == 10) return NV_BPC_10;
        if (bits == 12) return NV_BPC_12;
        throw new ArgumentException("bits must be 8, 10, or 12");
    }

    private static uint? ExplicitDesktopDepthForBits(int bits)
    {
        if (bits == 8) return NV_DESKTOP_COLOR_DEPTH_8BPC;
        if (bits == 10) return NV_DESKTOP_COLOR_DEPTH_10BPC;
        return null;
    }

    private static bool EquivalentForRequest(NV_COLOR_DATA_V5 color, int bits, bool strictDesktopDepth)
    {
        if (color.data.bpc != TargetBpcValue(bits))
        {
            return false;
        }

        if (strictDesktopDepth && bits == 8 && color.data.depth != NV_DESKTOP_COLOR_DEPTH_8BPC)
        {
            return false;
        }

        if (strictDesktopDepth && bits == 10 && color.data.depth != NV_DESKTOP_COLOR_DEPTH_10BPC)
        {
            return false;
        }

        return true;
    }

    private static string BpcName(uint value)
    {
        if (value == NV_BPC_DEFAULT) return "default";
        if (value == NV_BPC_6) return "6 bpc";
        if (value == NV_BPC_8) return "8 bpc";
        if (value == NV_BPC_10) return "10 bpc";
        if (value == NV_BPC_12) return "12 bpc";
        if (value == NV_BPC_16) return "16 bpc";
        return value.ToString();
    }

    private static string DepthName(uint value)
    {
        if (value == NV_DESKTOP_COLOR_DEPTH_DEFAULT) return "default/current";
        if (value == NV_DESKTOP_COLOR_DEPTH_8BPC) return "8 bpc desktop depth";
        if (value == NV_DESKTOP_COLOR_DEPTH_10BPC) return "10 bpc desktop depth";
        if (value == NV_DESKTOP_COLOR_DEPTH_16BPC_FLOAT) return "16 bpc float desktop depth";
        return value.ToString();
    }

    private static string FormatName(byte value)
    {
        if (value == 0) return "RGB";
        if (value == 1) return "YUV422";
        if (value == 2) return "YUV444";
        if (value == 3) return "YUV420";
        if (value == 0xFE) return "default";
        if (value == 0xFF) return "auto";
        return value.ToString();
    }

    private static string RangeName(byte value)
    {
        if (value == 0) return "full/VESA";
        if (value == 1) return "limited/CEA";
        if (value == 0xFE) return "default";
        if (value == 0xFF) return "auto";
        return value.ToString();
    }

    private static string DescribeColorData(NV_COLOR_DATA_V5 data)
    {
        return "format=" + FormatName(data.data.colorFormat) +
            ", range=" + RangeName(data.data.dynamicRange) +
            ", bpc=" + BpcName(data.data.bpc) +
            ", desktop_depth=" + DepthName(data.data.depth) +
            ", policy=" + data.data.colorSelectionPolicy;
    }

    private static string NormalizeDisplayName(string name)
    {
        if (name == null) return "";
        string n = name.Trim().ToUpperInvariant();
        n = n.Replace("\\\\.\\", "");
        n = n.Replace("\\", "");
        return n;
    }


    private static string DisplayLabel(DisplayInfo d)
    {
        if (d == null) return "";

        List<string> parts = new List<string>();
        if (!String.IsNullOrWhiteSpace(d.FriendlyName))
        {
            parts.Add(d.FriendlyName.Trim());
        }
        parts.Add(String.IsNullOrWhiteSpace(d.Name) ? "unknown display" : d.Name.Trim());
        if (!String.IsNullOrWhiteSpace(d.ConnectionType))
        {
            parts.Add(d.ConnectionType.Trim());
        }
        if (!String.IsNullOrWhiteSpace(d.EdidText))
        {
            parts.Add(d.EdidText.Trim());
        }
        parts.Add("displayId=0x" + d.DisplayId.ToString("X8"));
        return String.Join(" - ", parts.ToArray());
    }


    private static int DisplayNumberFromName(string name)
    {
        string n = NormalizeDisplayName(name);
        int pos = n.IndexOf("DISPLAY");
        if (pos < 0)
        {
            return -1;
        }

        string digits = "";
        for (int i = pos + 7; i < n.Length; i++)
        {
            if (n[i] >= '0' && n[i] <= '9')
            {
                digits += n[i];
            }
            else if (digits.Length > 0)
            {
                break;
            }
        }

        int value;
        if (digits.Length > 0 && Int32.TryParse(digits, out value))
        {
            return value;
        }
        return -1;
    }

    private static bool MatchesDisplayFilter(DisplayInfo display, string displayFilter)
    {
        if (display == null || String.IsNullOrWhiteSpace(displayFilter))
        {
            return false;
        }

        string f = displayFilter.Trim();
        string normalizedFilter = NormalizeDisplayName(f);
        string normalizedName = NormalizeDisplayName(display.Name);
        string normalizedFriendly = NormalizeDisplayName(display.FriendlyName);
        string normalizedLabel = NormalizeDisplayName(DisplayLabel(display));
        string normalizedDevicePath = NormalizeDisplayName(display.MonitorDevicePath);

        if (normalizedName == normalizedFilter || normalizedFriendly == normalizedFilter || normalizedLabel == normalizedFilter)
        {
            return true;
        }

        if (normalizedFilter.StartsWith("DISPLAY", StringComparison.OrdinalIgnoreCase))
        {
            return normalizedName == normalizedFilter;
        }

        if (f.StartsWith("index:", StringComparison.OrdinalIgnoreCase))
        {
            uint requestedIndex;
            if (UInt32.TryParse(f.Substring(6).Trim(), out requestedIndex))
            {
                return display.Index == requestedIndex;
            }
            return false;
        }

        if (f.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                uint requestedDisplayId = Convert.ToUInt32(f.Substring(2), 16);
                return display.DisplayId == requestedDisplayId;
            }
            catch
            {
                return false;
            }
        }

        uint requestedNumber;
        if (UInt32.TryParse(f, out requestedNumber))
        {
            int displayNumber = DisplayNumberFromName(display.Name);
            if (displayNumber == (int)requestedNumber)
            {
                return true;
            }

            // Also accept one-based menu index for convenience.
            if (display.Index + 1 == requestedNumber)
            {
                return true;
            }

            return false;
        }

        return normalizedName.Contains(normalizedFilter) ||
            normalizedFriendly.Contains(normalizedFilter) ||
            normalizedLabel.Contains(normalizedFilter) ||
            normalizedDevicePath.Contains(normalizedFilter);
    }

    private static List<DisplayInfo> PromptForDisplaySelection(List<DisplayInfo> displays)
    {
        if (displays == null || displays.Count == 0)
        {
            throw new InvalidOperationException("No active NVIDIA displays were found.");
        }

        Console.WriteLine();
        Console.WriteLine("Choose NVIDIA display to change:");
        for (int i = 0; i < displays.Count; i++)
        {
            DisplayInfo d = displays[i];
            Console.WriteLine("  " + (i + 1) + ") " + DisplayLabel(d));
        }
        Console.WriteLine("  A) All displays");

        while (true)
        {
            Console.Write("Selection [1-" + displays.Count + ", A]: ");
            string answer = Console.ReadLine();
            if (answer == null)
            {
                throw new InvalidOperationException("Display selection was cancelled.");
            }

            answer = answer.Trim();
            if (answer.Equals("A", StringComparison.OrdinalIgnoreCase) || answer.Equals("ALL", StringComparison.OrdinalIgnoreCase))
            {
                return new List<DisplayInfo>(displays);
            }

            int menuIndex;
            if (Int32.TryParse(answer, out menuIndex) && menuIndex >= 1 && menuIndex <= displays.Count)
            {
                return new List<DisplayInfo> { displays[menuIndex - 1] };
            }

            List<DisplayInfo> matched = new List<DisplayInfo>();
            foreach (DisplayInfo d in displays)
            {
                if (MatchesDisplayFilter(d, answer))
                {
                    matched.Add(d);
                }
            }
            if (matched.Count == 1)
            {
                return matched;
            }
            if (matched.Count > 1)
            {
                Console.WriteLine("That selection matched more than one display. Use the menu number, DISPLAYn, monitor name, index:n, or displayId.");
            }
            else
            {
                Console.WriteLine("Enter a menu number, A/all, DISPLAYn, monitor name, index:n, or a displayId such as 0x80061086.");
            }
        }
    }

    private static NV_COLOR_DATA_V5 BuildCandidate(NV_COLOR_DATA_V5 current, int bits, bool forceRgbFull, uint? depth)
    {
        NV_COLOR_DATA_V5 candidate = current;
        candidate.cmd = NV_COLOR_CMD_SET;

        if (forceRgbFull)
        {
            candidate.data.colorFormat = NV_COLOR_FORMAT_RGB;
            candidate.data.colorimetry = NV_COLOR_COLORIMETRY_RGB;
            candidate.data.dynamicRange = NV_COLOR_DYNAMIC_RANGE_VESA;
        }

        candidate.data.bpc = TargetBpcValue(bits);
        if (depth.HasValue)
        {
            candidate.data.depth = depth.Value;
        }
        candidate.data.colorSelectionPolicy = NV_COLOR_SELECTION_POLICY_USER;
        return candidate;
    }

    private static bool TrySupportedCandidate(NvApi nv, uint displayId, string label, NV_COLOR_DATA_V5 candidate, bool skipSupportCheck, out int status)
    {
        Console.WriteLine("  candidate: " + label + ": " + DescribeColorData(candidate));
        if (skipSupportCheck)
        {
            status = NVAPI_OK;
            return true;
        }

        status = nv.IsSupportedColor(displayId, candidate);
        if (status == NVAPI_OK)
        {
            return true;
        }

        Console.WriteLine("    unsupported: " + nv.StatusText(status) + " (" + status + ")");
        return false;
    }

    private static bool ApplyToDisplay(NvApi nv, DisplayInfo display, int bits, bool forceRgbFull, bool dryRun, bool skipSupportCheck, bool strictDesktopDepth)
    {
        NV_COLOR_DATA_V5 current = nv.GetColor(display.DisplayId);
        Console.WriteLine();
        Console.WriteLine(DisplayLabel(display));
        Console.WriteLine("  current: " + DescribeColorData(current));

        if (EquivalentForRequest(current, bits, strictDesktopDepth))
        {
            if (current.data.depth == ExplicitDesktopDepthForBits(bits).GetValueOrDefault(UInt32.MaxValue))
            {
                Console.WriteLine("  already OK: NVIDIA reports " + bits + " bpc and explicit " + bits + " bpc desktop depth.");
            }
            else
            {
                Console.WriteLine("  already OK: NVIDIA reports " + bits + " bpc output. The separate desktop_depth field is not required unless strict desktop-depth mode is used.");
            }
            return false;
        }

        bool selected = false;
        NV_COLOR_DATA_V5 selectedCandidate = current;
        int status;

        uint? explicitDepth = ExplicitDesktopDepthForBits(bits);
        if (explicitDepth.HasValue)
        {
            NV_COLOR_DATA_V5 candidate = BuildCandidate(current, bits, forceRgbFull, explicitDepth.Value);
            bool supported = TrySupportedCandidate(nv, display.DisplayId, bits + " bpc + explicit " + bits + " bpc desktop depth", candidate, skipSupportCheck, out status);
            if (supported)
            {
                selected = true;
                selectedCandidate = candidate;
            }
        }
        else
        {
            Console.WriteLine("  note: NVAPI does not expose a separate 12 bpc desktop-depth enum; preserving current/default desktop depth.");
        }

        if (!selected && !strictDesktopDepth)
        {
            NV_COLOR_DATA_V5 candidate = BuildCandidate(current, bits, forceRgbFull, null);
            bool supported = TrySupportedCandidate(nv, display.DisplayId, bits + " bpc + preserve current/default desktop depth", candidate, skipSupportCheck, out status);
            if (supported)
            {
                selected = true;
                selectedCandidate = candidate;
            }
        }

        if (!selected)
        {
            Console.WriteLine("  skipped: no supported " + bits + " bpc candidate was reported by the NVIDIA driver.");
            if (current.data.bpc == TargetBpcValue(bits))
            {
                Console.WriteLine("  note: current output is already " + bits + " bpc, so only the Windows Advanced Color guard was needed.");
            }
            return false;
        }

        if (dryRun)
        {
            Console.WriteLine("  dry-run: no NVIDIA color change applied");
            return false;
        }

        try
        {
            nv.SetColor(display.DisplayId, selectedCandidate);
        }
        catch (Exception ex)
        {
            if (!strictDesktopDepth && current.data.bpc == TargetBpcValue(bits))
            {
                Console.WriteLine("  NVIDIA SET failed, but output was already " + bits + " bpc before SET: " + ex.Message);
                return false;
            }
            throw;
        }

        NV_COLOR_DATA_V5 after = nv.GetColor(display.DisplayId);
        Console.WriteLine("  after:   " + DescribeColorData(after));

        if (after.data.bpc == TargetBpcValue(bits))
        {
            if (explicitDepth.HasValue && selectedCandidate.data.depth == explicitDepth.Value && after.data.depth != explicitDepth.Value)
            {
                Console.WriteLine("  note: driver kept desktop_depth at default/current while preserving " + bits + " bpc output.");
            }
            return true;
        }

        Console.WriteLine("  warning: NVIDIA SET returned success, but GET does not report " + bits + " bpc afterward.");
        return true;
    }

    public static string[] ResolveDisplayNames(string displayFilter, bool allDisplays)
    {
        using (NvApi nv = new NvApi())
        {
            nv.Initialize();
            List<DisplayInfo> displays = nv.EnumerateDisplays();
            if (displays.Count == 0)
            {
                throw new InvalidOperationException("No active NVIDIA displays were found.");
            }

            if (!String.IsNullOrWhiteSpace(displayFilter))
            {
                List<string> names = new List<string>();
                foreach (DisplayInfo d in displays)
                {
                    if (MatchesDisplayFilter(d, displayFilter))
                    {
                        names.Add(d.Name);
                    }
                }

                if (names.Count == 0)
                {
                    throw new InvalidOperationException(
                        "No NVIDIA display matched '" + displayFilter + "'. Use DISPLAY1, a monitor name, a menu number like 1, index:0, or a displayId like 0x80061086.");
                }
                return names.ToArray();
            }

            if (allDisplays)
            {
                List<string> names = new List<string>();
                foreach (DisplayInfo d in displays) names.Add(d.Name);
                return names.ToArray();
            }

            List<DisplayInfo> selected = PromptForDisplaySelection(displays);
            List<string> selectedNames = new List<string>();
            foreach (DisplayInfo d in selected) selectedNames.Add(d.Name);
            return selectedNames.ToArray();
        }
    }

    public static bool Apply(int bits, string displayFilter, bool allDisplays, bool forceRgbFull, bool dryRun, bool skipSupportCheck, bool strictDesktopDepth)
    {
        if (bits != 8 && bits != 10 && bits != 12)
        {
            throw new ArgumentException("bits must be 8, 10, or 12");
        }

        if (bits == 12 && strictDesktopDepth)
        {
            Console.WriteLine("Note: strict desktop-depth mode is ignored for 12 bpc because NVAPI exposes 8, 10, and 16-bit-float desktop-depth enums, not 12.");
        }

        using (NvApi nv = new NvApi())
        {
            nv.Initialize();
            List<DisplayInfo> displays = nv.EnumerateDisplays();
            if (displays.Count == 0)
            {
                throw new InvalidOperationException("No active NVIDIA displays were found.");
            }

            if (!String.IsNullOrWhiteSpace(displayFilter))
            {
                List<DisplayInfo> filtered = new List<DisplayInfo>();
                foreach (DisplayInfo d in displays)
                {
                    if (MatchesDisplayFilter(d, displayFilter))
                    {
                        filtered.Add(d);
                    }
                }
                displays = filtered;

                if (displays.Count == 0)
                {
                    throw new InvalidOperationException(
                        "No NVIDIA display matched '" + displayFilter + "'. Use DISPLAY1, a monitor name, a menu number like 1, index:0, or a displayId like 0x80061086.");
                }
            }
            else if (!allDisplays)
            {
                displays = PromptForDisplaySelection(displays);
            }

            Console.WriteLine("NVIDIA displays to process:");
            foreach (DisplayInfo d in displays)
            {
                Console.WriteLine("  " + DisplayLabel(d));
            }

            bool changedAny = false;
            foreach (DisplayInfo d in displays)
            {
                try
                {
                    changedAny = ApplyToDisplay(nv, d, bits, forceRgbFull, dryRun, skipSupportCheck, strictDesktopDepth) || changedAny;
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  error on " + DisplayLabel(d) + ": " + ex.Message);
                }
            }

            return changedAny;
        }
    }
}
'@

try {
    if (-not ('WinDisplayConfig' -as [type]) -or -not ('NvApiColorControl' -as [type])) {
        Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
    }
}
catch {
    Write-Error "Failed to compile embedded C# interop code: $($_.Exception.Message)"
    exit 1
}

$selectedDisplayNames = @()
try {
    $selectedDisplayNames = [NvApiColorControl]::ResolveDisplayNames([string]$Display, [bool]$AllDisplays)
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

$targetBits = Get-TargetBits -RequestedBits $Bits

if ($targetBits -eq 12 -and $StrictDesktopDepth) {
    Write-Host 'Note: -StrictDesktopDepth is ignored for 12 bpc because NVAPI has no explicit 12 bpc desktop-depth enum.'
}

if ($selectedDisplayNames.Count -eq 1) {
    $resolvedDisplayFilter = [string]$selectedDisplayNames[0]
    $resolvedAllDisplays = $false
}
else {
    $resolvedDisplayFilter = ''
    $resolvedAllDisplays = $true
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'Warning: Administrator shell recommended. Some Windows color-state or registry guards may fail.'
}

if ($VerboseDetails -or $DryRun) {
    [WinDisplayConfig]::PrintAdvancedColorSnapshot('before', [string[]]$selectedDisplayNames)
}

if (-not $NoRegistryGuard -and -not $DryRun) {
    [void](Set-AcmDeveloperPreviewOff -ShowDetails ([bool]$VerboseDetails))
}

if (-not $NoWindowsAcmGuard -and -not $DryRun) {
    try {
        $guard = [WinDisplayConfig]::DisableAdvancedColorOnce([bool]$VerboseDetails, [string[]]$selectedDisplayNames)
        Write-Host "Pre-change Windows Advanced Color guard: $($guard[0]) disable calls succeeded, $($guard[1]) ignored."
    }
    catch {
        Write-Host "Pre-change Windows Advanced Color guard failed: $($_.Exception.Message)"
    }
}

$changedAny = $false
try {
    $changedAny = [NvApiColorControl]::Apply(
        [int]$targetBits,
        [string]$resolvedDisplayFilter,
        [bool]$resolvedAllDisplays,
        [bool]$ForceRgbFull,
        [bool]$DryRun,
        [bool]$SkipSupportCheck,
        [bool]$StrictDesktopDepth
    )
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

if (-not $NoWindowsAcmGuard -and -not $DryRun) {
    $passes = [Math]::Max(0, $GuardPasses)
    $delayMs = [int]([Math]::Max(0, $GuardDelaySeconds) * 1000)

    for ($i = 0; $i -lt $passes; $i++) {
        if ($i -gt 0 -or $changedAny) {
            Start-Sleep -Milliseconds $delayMs
        }

        try {
            $guard = [WinDisplayConfig]::DisableAdvancedColorOnce([bool]$VerboseDetails, [string[]]$selectedDisplayNames)
            if ($VerboseDetails) {
                Write-Host "Post-change Windows Advanced Color guard pass $($i + 1): $($guard[0]) disable calls succeeded, $($guard[1]) ignored."
            }
        }
        catch {
            Write-Host "Post-change Windows Advanced Color guard pass $($i + 1) failed: $($_.Exception.Message)"
        }
    }
}

if ($VerboseDetails -or $DryRun) {
    [WinDisplayConfig]::PrintAdvancedColorSnapshot('after', [string[]]$selectedDisplayNames)
}

if (-not $DryRun) {
    Write-Host ''
    Write-Host 'Done. Verify in NVIDIA Control Panel and Windows Settings > System > Display > Advanced display.'
    Write-Host 'If Windows re-enables Advanced Color later, rerun this script or disable the Windows ACM toggle manually.'
}
