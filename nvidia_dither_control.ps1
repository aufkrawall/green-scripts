<#
.SYNOPSIS
    Control NVIDIA per-display dithering settings from PowerShell.

.DESCRIPTION
    Spin-off of the NVIDIA bit-depth script. This version does not change output color depth
    and does not touch Windows Advanced Color / HDR / ACM state.

    It uses embedded C# interop to call NVIDIA NVAPI:
      - NvAPI_EnumNvidiaDisplayHandle
      - NvAPI_GetAssociatedNvidiaDisplayName
      - NvAPI_DISP_GetDisplayIdByDisplayName
      - NvAPI_GetPhysicalGPUsFromDisplay
      - NvAPI_GPU_GetDitherControl
      - NvAPI_GPU_SetDitherControl

    Interactive flow:
      1. Choose display from identified NVIDIA displays
      2. Choose dithering state: Auto, Enabled, Disabled
      3. If Enabled, choose dither target depth: 6-bit, 8-bit, or 10-bit
      4. If Enabled, choose dither mode: Spatial/Temporal variants

.NOTES
    Requirements:
      - Windows 10/11
      - NVIDIA driver with NVAPI installed
      - 64-bit PowerShell is recommended

    This applies the NVIDIA driver setting directly. Some driver/display paths may not keep it
    across driver restarts, display sleep/wake, refresh-rate changes, HDR state changes, or reboot.
#>

[CmdletBinding()]
param(
    [string]$Display,

    [switch]$AllDisplays,

    [ValidateSet('', 'Auto', 'On', 'Off', 'Enabled', 'Disabled')]
    [string]$State = '',

    [ValidateSet(0, 6, 8, 10)]
    [int]$DitherBits = 0,

    [ValidateSet('', 'SpatialDynamic', 'SpatialStatic', 'SpatialDynamic2x2', 'SpatialStatic2x2', 'Temporal')]
    [string]$Mode = '',

    [switch]$DryRun,

    [switch]$VerboseDetails
)

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Error 'This script must be run on Windows.'
    exit 2
}

function Get-DitherStateCode {
    param([string]$RequestedState)

    switch -Regex ($RequestedState) {
        '^(Auto)$' { return 0 }
        '^(On|Enabled)$' { return 1 }
        '^(Off|Disabled)$' { return 2 }
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Choose NVIDIA dithering state:'
        Write-Host '  1) Auto - let the NVIDIA driver decide'
        Write-Host '  2) Enabled - force dithering on'
        Write-Host '  3) Disabled - force dithering off'
        $answer = Read-Host 'Selection [1-3]'
        switch ($answer.Trim().ToUpperInvariant()) {
            '1' { return 0 }
            'A' { return 0 }
            'AUTO' { return 0 }
            '2' { return 1 }
            'ON' { return 1 }
            'ENABLED' { return 1 }
            'ENABLE' { return 1 }
            '3' { return 2 }
            'OFF' { return 2 }
            'DISABLED' { return 2 }
            'DISABLE' { return 2 }
            default { Write-Host 'Enter 1, 2, 3, Auto, On, or Off.' }
        }
    }
}

function Get-DitherBitsCode {
    param([int]$RequestedBits)

    switch ($RequestedBits) {
        6 { return 0 }
        8 { return 1 }
        10 { return 2 }
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Choose dither target bit depth:'
        Write-Host '  1) 6-bit'
        Write-Host '  2) 8-bit'
        Write-Host '  3) 10-bit'
        $answer = Read-Host 'Selection [1-3]'
        switch ($answer.Trim()) {
            '1' { return 0 }
            '6' { return 0 }
            '2' { return 1 }
            '8' { return 1 }
            '3' { return 2 }
            '10' { return 2 }
            default { Write-Host 'Enter 1, 2, 3, 6, 8, or 10.' }
        }
    }
}

function Get-DitherModeCode {
    param([string]$RequestedMode)

    switch ($RequestedMode) {
        'SpatialDynamic' { return 0 }
        'SpatialStatic' { return 1 }
        'SpatialDynamic2x2' { return 2 }
        'SpatialStatic2x2' { return 3 }
        'Temporal' { return 4 }
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Choose dither mode:'
        Write-Host '  1) Spatial Dynamic'
        Write-Host '  2) Spatial Static'
        Write-Host '  3) Spatial Dynamic 2x2'
        Write-Host '  4) Spatial Static 2x2'
        Write-Host '  5) Temporal'
        $answer = Read-Host 'Selection [1-5]'
        switch ($answer.Trim().ToUpperInvariant()) {
            '1' { return 0 }
            'SPATIALDYNAMIC' { return 0 }
            'SPATIAL DYNAMIC' { return 0 }
            '2' { return 1 }
            'SPATIALSTATIC' { return 1 }
            'SPATIAL STATIC' { return 1 }
            '3' { return 2 }
            'SPATIALDYNAMIC2X2' { return 2 }
            'SPATIAL DYNAMIC 2X2' { return 2 }
            '4' { return 3 }
            'SPATIALSTATIC2X2' { return 3 }
            'SPATIAL STATIC 2X2' { return 3 }
            '5' { return 4 }
            'TEMPORAL' { return 4 }
            default { Write-Host 'Enter a menu number from 1 to 5.' }
        }
    }
}

$csharp = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class WinDisplayConfigDither
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



public static class NvApiDitherControl
{
    private const int NVAPI_OK = 0;
    private const int NVAPI_END_ENUMERATION = -7;

    private const uint ID_NvAPI_Initialize = 0x0150E828;
    private const uint ID_NvAPI_Unload = 0xD22BDD7E;
    private const uint ID_NvAPI_GetErrorMessage = 0x6C2D048C;
    private const uint ID_NvAPI_EnumNvidiaDisplayHandle = 0x9ABDD40D;
    private const uint ID_NvAPI_GetAssociatedNvidiaDisplayName = 0x22A78B05;
    private const uint ID_NvAPI_DISP_GetDisplayIdByDisplayName = 0xAE457190;
    private const uint ID_NvAPI_GetPhysicalGPUsFromDisplay = 0x34EF9506;
    private const uint ID_NvAPI_GPU_GetDitherControl = 0x932AC8FB;
    private const uint ID_NvAPI_GPU_SetDitherControl = 0x0DF0DFCDD;

    private const int NV_DITHER_STATE_AUTO = 0;
    private const int NV_DITHER_STATE_ENABLED = 1;
    private const int NV_DITHER_STATE_DISABLED = 2;

    private const int NV_DITHER_BITS_6 = 0;
    private const int NV_DITHER_BITS_8 = 1;
    private const int NV_DITHER_BITS_10 = 2;

    private const int NV_DITHER_MODE_SPATIAL_DYNAMIC = 0;
    private const int NV_DITHER_MODE_SPATIAL_STATIC = 1;
    private const int NV_DITHER_MODE_SPATIAL_DYNAMIC_2X2 = 2;
    private const int NV_DITHER_MODE_SPATIAL_STATIC_2X2 = 3;
    private const int NV_DITHER_MODE_TEMPORAL = 4;

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_GPU_DITHER_CONTROL_V1
    {
        public uint version;
        public int state;
        public int bits;
        public int mode;
        public uint bitsCaps;
        public uint modeCaps;
    }

    private class DisplayInfo
    {
        public uint Index;
        public IntPtr Handle;
        public IntPtr PhysicalGpu;
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
    private delegate int NvAPI_GetPhysicalGPUsFromDisplayDelegate(IntPtr displayHandle, [Out] IntPtr[] gpuHandles, ref uint gpuCount);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_GPU_GetDitherControlDelegate(uint displayId, ref NV_GPU_DITHER_CONTROL_V1 ditherControl);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_GPU_SetDitherControlDelegate(IntPtr physicalGpu, uint outputId, uint state, uint bits, uint mode);

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
        private NvAPI_GetPhysicalGPUsFromDisplayDelegate getPhysicalGPUsFromDisplay;
        private NvAPI_GPU_GetDitherControlDelegate getDitherControl;
        private NvAPI_GPU_SetDitherControlDelegate setDitherControl;

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
            getPhysicalGPUsFromDisplay = GetFunction<NvAPI_GetPhysicalGPUsFromDisplayDelegate>(ID_NvAPI_GetPhysicalGPUsFromDisplay);
            getDitherControl = GetFunction<NvAPI_GPU_GetDitherControlDelegate>(ID_NvAPI_GPU_GetDitherControl);
            setDitherControl = GetFunction<NvAPI_GPU_SetDitherControlDelegate>(ID_NvAPI_GPU_SetDitherControl);
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

                IntPtr[] gpuHandles = new IntPtr[64];
                uint gpuCount = 0;
                status = getPhysicalGPUsFromDisplay(handle, gpuHandles, ref gpuCount);
                Check(status, "NvAPI_GetPhysicalGPUsFromDisplay(" + name.ToString() + ")");
                if (gpuCount == 0 || gpuHandles[0] == IntPtr.Zero)
                {
                    throw new InvalidOperationException("No physical GPU handle was returned for " + name.ToString() + ".");
                }

                DisplayInfo info = new DisplayInfo();
                info.Index = index;
                info.Handle = handle;
                info.PhysicalGpu = gpuHandles[0];
                info.Name = name.ToString();
                info.DisplayId = displayId;

                string[] details = WinDisplayConfigDither.GetDisplayDetailsForSourceName(info.Name);
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

        public NV_GPU_DITHER_CONTROL_V1 GetDither(uint displayId)
        {
            NV_GPU_DITHER_CONTROL_V1 dither = NewDitherData();
            Check(getDitherControl(displayId, ref dither), "NvAPI_GPU_GetDitherControl(GET)");
            return dither;
        }

        public void SetDither(IntPtr physicalGpu, uint displayId, uint state, uint bits, uint mode)
        {
            Check(setDitherControl(physicalGpu, displayId, state, bits, mode), "NvAPI_GPU_SetDitherControl(SET)");
        }
    }

    private static uint MakeNvApiVersion(Type structType, uint version)
    {
        return (uint)Marshal.SizeOf(structType) | (version << 16);
    }

    private static NV_GPU_DITHER_CONTROL_V1 NewDitherData()
    {
        NV_GPU_DITHER_CONTROL_V1 data = new NV_GPU_DITHER_CONTROL_V1();
        data.version = MakeNvApiVersion(typeof(NV_GPU_DITHER_CONTROL_V1), 1);
        return data;
    }

    private static string NormalizeDisplayName(string name)
    {
        if (name == null) return "";
        string n = name.Trim().ToUpperInvariant();
        n = n.Replace("\\.\\", "");
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

    private static List<DisplayInfo> SelectDisplays(NvApi nv, string displayFilter, bool allDisplays)
    {
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

        return displays;
    }

    private static string StateName(int value)
    {
        if (value == NV_DITHER_STATE_AUTO) return "Auto";
        if (value == NV_DITHER_STATE_ENABLED) return "Enabled";
        if (value == NV_DITHER_STATE_DISABLED) return "Disabled";
        return value.ToString();
    }

    private static string BitsName(int value)
    {
        if (value == NV_DITHER_BITS_6) return "6-bit";
        if (value == NV_DITHER_BITS_8) return "8-bit";
        if (value == NV_DITHER_BITS_10) return "10-bit";
        return value.ToString();
    }

    private static string ModeName(int value)
    {
        if (value == NV_DITHER_MODE_SPATIAL_DYNAMIC) return "Spatial Dynamic";
        if (value == NV_DITHER_MODE_SPATIAL_STATIC) return "Spatial Static";
        if (value == NV_DITHER_MODE_SPATIAL_DYNAMIC_2X2) return "Spatial Dynamic 2x2";
        if (value == NV_DITHER_MODE_SPATIAL_STATIC_2X2) return "Spatial Static 2x2";
        if (value == NV_DITHER_MODE_TEMPORAL) return "Temporal";
        return value.ToString();
    }

    private static bool IsCapSet(uint caps, int value)
    {
        if (caps == 0) return true;
        if (value < 0 || value > 30) return false;
        return (caps & (1u << value)) != 0;
    }

    private static string CapsDescription(uint caps, bool bits)
    {
        if (caps == 0) return "unknown/all assumed";
        List<string> names = new List<string>();
        int max = bits ? 2 : 4;
        for (int i = 0; i <= max; i++)
        {
            if (IsCapSet(caps, i))
            {
                names.Add(bits ? BitsName(i) : ModeName(i));
            }
        }
        if (names.Count == 0) return "none reported, raw=0x" + caps.ToString("X");
        return String.Join(", ", names.ToArray()) + " (raw=0x" + caps.ToString("X") + ")";
    }

    private static string DescribeDither(NV_GPU_DITHER_CONTROL_V1 d)
    {
        return "state=" + StateName(d.state) +
            ", bits=" + BitsName(d.bits) +
            ", mode=" + ModeName(d.mode) +
            ", bitsCaps=" + CapsDescription(d.bitsCaps, true) +
            ", modeCaps=" + CapsDescription(d.modeCaps, false);
    }

    public static string[] ResolveDisplayNames(string displayFilter, bool allDisplays)
    {
        using (NvApi nv = new NvApi())
        {
            nv.Initialize();
            List<DisplayInfo> displays = SelectDisplays(nv, displayFilter, allDisplays);
            List<string> names = new List<string>();
            foreach (DisplayInfo d in displays)
            {
                names.Add(d.Name);
            }
            return names.ToArray();
        }
    }

    public static void PrintCurrent(string displayFilter, bool allDisplays)
    {
        using (NvApi nv = new NvApi())
        {
            nv.Initialize();
            List<DisplayInfo> displays = SelectDisplays(nv, displayFilter, allDisplays);

            Console.WriteLine();
            Console.WriteLine("Current NVIDIA dithering state:");
            foreach (DisplayInfo d in displays)
            {
                try
                {
                    NV_GPU_DITHER_CONTROL_V1 current = nv.GetDither(d.DisplayId);
                    Console.WriteLine("  " + DisplayLabel(d));
                    Console.WriteLine("    " + DescribeDither(current));
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  " + DisplayLabel(d));
                    Console.WriteLine("    error: " + ex.Message);
                }
            }
        }
    }

    private static bool ApplyToDisplay(NvApi nv, DisplayInfo display, int targetState, int targetBits, int targetMode, bool dryRun, bool verboseDetails)
    {
        NV_GPU_DITHER_CONTROL_V1 current = nv.GetDither(display.DisplayId);

        int applyState = targetState;
        int applyBits = targetBits;
        int applyMode = targetMode;

        if (applyState == NV_DITHER_STATE_AUTO)
        {
            applyBits = 0;
            applyMode = 0;
        }
        else if (applyState == NV_DITHER_STATE_DISABLED)
        {
            if (applyBits < 0) applyBits = current.bits;
            if (applyMode < 0) applyMode = current.mode;
        }
        else if (applyState == NV_DITHER_STATE_ENABLED)
        {
            if (applyBits < 0 || applyMode < 0)
            {
                throw new InvalidOperationException("Enabled dithering requires a target bit depth and mode.");
            }
        }
        else
        {
            throw new InvalidOperationException("Unknown dithering state: " + applyState);
        }

        Console.WriteLine();
        Console.WriteLine(DisplayLabel(display));
        Console.WriteLine("  current: " + DescribeDither(current));
        Console.WriteLine("  desired: state=" + StateName(applyState) + ", bits=" + BitsName(applyBits) + ", mode=" + ModeName(applyMode));

        if (applyState == current.state && applyBits == current.bits && applyMode == current.mode)
        {
            Console.WriteLine("  already OK: requested dithering state is already reported.");
            return false;
        }

        if (applyState == NV_DITHER_STATE_ENABLED)
        {
            if (!IsCapSet(current.bitsCaps, applyBits))
            {
                Console.WriteLine("  warning: requested dither bit depth is not listed in bitsCaps; attempting anyway.");
            }
            if (!IsCapSet(current.modeCaps, applyMode))
            {
                Console.WriteLine("  warning: requested dither mode is not listed in modeCaps; attempting anyway.");
            }
        }

        if (dryRun)
        {
            Console.WriteLine("  dry-run: no NVIDIA dithering change applied");
            return false;
        }

        nv.SetDither(display.PhysicalGpu, display.DisplayId, (uint)applyState, (uint)applyBits, (uint)applyMode);
        NV_GPU_DITHER_CONTROL_V1 after = nv.GetDither(display.DisplayId);
        Console.WriteLine("  after:   " + DescribeDither(after));

        if (after.state != applyState || (applyState == NV_DITHER_STATE_ENABLED && (after.bits != applyBits || after.mode != applyMode)))
        {
            Console.WriteLine("  warning: SET returned success, but GET does not exactly match the requested dithering values afterward.");
        }

        return true;
    }

    public static bool Apply(int state, int ditherBits, int mode, string displayFilter, bool allDisplays, bool dryRun, bool verboseDetails)
    {
        if (state < 0 || state > 2)
        {
            throw new ArgumentException("state must be Auto=0, Enabled=1, or Disabled=2");
        }
        if (state == NV_DITHER_STATE_ENABLED && (ditherBits < 0 || mode < 0))
        {
            throw new ArgumentException("Enabled dithering requires ditherBits and mode.");
        }

        using (NvApi nv = new NvApi())
        {
            nv.Initialize();
            List<DisplayInfo> displays = SelectDisplays(nv, displayFilter, allDisplays);

            Console.WriteLine();
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
                    changedAny = ApplyToDisplay(nv, d, state, ditherBits, mode, dryRun, verboseDetails) || changedAny;
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
    if (-not ('NvApiDitherControl' -as [type])) {
        Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
    }
}
catch {
    Write-Error "Failed to compile embedded C# interop code: $($_.Exception.Message)"
    exit 1
}

$selectedDisplayNames = @()
try {
    $selectedDisplayNames = [NvApiDitherControl]::ResolveDisplayNames([string]$Display, [bool]$AllDisplays)
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

if ($selectedDisplayNames.Count -eq 1) {
    $resolvedDisplayFilter = [string]$selectedDisplayNames[0]
    $resolvedAllDisplays = $false
}
else {
    $resolvedDisplayFilter = ''
    $resolvedAllDisplays = $true
}

try {
    [NvApiDitherControl]::PrintCurrent([string]$resolvedDisplayFilter, [bool]$resolvedAllDisplays)
}
catch {
    Write-Host "Could not read current dithering state: $($_.Exception.Message)"
}

$stateCode = Get-DitherStateCode -RequestedState $State

if ($stateCode -eq 1) {
    $bitsCode = Get-DitherBitsCode -RequestedBits $DitherBits
    $modeCode = Get-DitherModeCode -RequestedMode $Mode
}
else {
    $bitsCode = -1
    $modeCode = -1
}

$changedAny = $false
try {
    $changedAny = [NvApiDitherControl]::Apply(
        [int]$stateCode,
        [int]$bitsCode,
        [int]$modeCode,
        [string]$resolvedDisplayFilter,
        [bool]$resolvedAllDisplays,
        [bool]$DryRun,
        [bool]$VerboseDetails
    )
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

if (-not $DryRun) {
    Write-Host ''
    Write-Host 'Done. Verify with a gradient test or by rerunning this script to read the reported NVIDIA dithering state.'
    Write-Host 'If the setting is lost after reboot, display sleep/wake, refresh-rate changes, or HDR toggles, rerun the script.'
}
