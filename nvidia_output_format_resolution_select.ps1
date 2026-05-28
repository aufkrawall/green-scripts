# MIT License
# Copyright (c) 2026 aufkrawall
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Select a display, resolution, NVIDIA RGB/YCbCr output format, chroma subsampling, and PC/TV range.

.DESCRIPTION
    This script follows the same pattern as the previous NVIDIA scripts:
      - embedded C# interop
      - display selection with monitor names where Windows exposes them
      - current status shown before changes
      - NVIDIA NVAPI ColorControl for output format/range
      - Windows EnumDisplaySettings/ChangeDisplaySettingsEx for resolution/refresh mode

    It does not intentionally change output bit depth, dithering, HDR, or Windows Advanced Color/ACM.

.NOTES
    Requirements:
      - Windows 10/11
      - NVIDIA driver with NVAPI installed
      - 64-bit PowerShell recommended
#>

[CmdletBinding()]
param(
    [string]$Display,

    [switch]$AllDisplays,

    [ValidateSet('', 'RGB', 'YCbCr444', 'YCbCr422', 'YCbCr420', 'YUV444', 'YUV422', 'YUV420', 'Auto', 'Default', 'Keep')]
    [string]$OutputFormat = '',

    [ValidateSet('', 'PC', 'Full', 'VESA', 'TV', 'Limited', 'CEA', 'Auto', 'Keep')]
    [string]$Range = '',

    [string]$Resolution = '',

    [uint32]$RefreshRate = 0,

    [switch]$DryRun,

    [switch]$SkipSupportCheck
)

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Error 'This script must be run on Windows.'
    exit 2
}

$csharp = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
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

public static class NvApiOutputControl
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
    private const byte NV_COLOR_FORMAT_YUV422 = 1;
    private const byte NV_COLOR_FORMAT_YUV444 = 2;
    private const byte NV_COLOR_FORMAT_YUV420 = 3;
    private const byte NV_COLOR_FORMAT_DEFAULT = 0xFE;
    private const byte NV_COLOR_FORMAT_AUTO = 0xFF;

    private const byte NV_COLOR_COLORIMETRY_RGB = 0;
    private const byte NV_COLOR_COLORIMETRY_YCC601 = 1;
    private const byte NV_COLOR_COLORIMETRY_YCC709 = 2;
    private const byte NV_COLOR_COLORIMETRY_BT2020RGB = 8;
    private const byte NV_COLOR_COLORIMETRY_BT2020YCC = 9;
    private const byte NV_COLOR_COLORIMETRY_DEFAULT = 0xFE;
    private const byte NV_COLOR_COLORIMETRY_AUTO = 0xFF;

    private const byte NV_COLOR_DYNAMIC_RANGE_VESA = 0; // PC/full range
    private const byte NV_COLOR_DYNAMIC_RANGE_CEA = 1;  // TV/limited range
    private const byte NV_COLOR_DYNAMIC_RANGE_AUTO = 2;

    private const uint NV_BPC_DEFAULT = 0;
    private const uint NV_BPC_6 = 1;
    private const uint NV_BPC_8 = 2;
    private const uint NV_BPC_10 = 3;
    private const uint NV_BPC_12 = 4;
    private const uint NV_BPC_16 = 5;

    private const uint NV_COLOR_SELECTION_POLICY_USER = 0;
    private const uint NV_COLOR_SELECTION_POLICY_DEFAULT = 1;

    private const uint NV_DESKTOP_COLOR_DEPTH_DEFAULT = 0;
    private const uint NV_DESKTOP_COLOR_DEPTH_8BPC = 1;
    private const uint NV_DESKTOP_COLOR_DEPTH_10BPC = 2;
    private const uint NV_DESKTOP_COLOR_DEPTH_16BPC_FLOAT = 3;

    private const int ENUM_CURRENT_SETTINGS = -1;
    private const int ENUM_REGISTRY_SETTINGS = -2;
    private const int DISP_CHANGE_SUCCESSFUL = 0;
    private const int DISP_CHANGE_RESTART = 1;
    private const int DISP_CHANGE_FAILED = -1;
    private const int DISP_CHANGE_BADMODE = -2;
    private const int DISP_CHANGE_NOTUPDATED = -3;
    private const int DISP_CHANGE_BADFLAGS = -4;
    private const int DISP_CHANGE_BADPARAM = -5;
    private const int DISP_CHANGE_BADDUALVIEW = -6;

    private const uint DM_BITSPERPEL = 0x00040000;
    private const uint DM_PELSWIDTH = 0x00080000;
    private const uint DM_PELSHEIGHT = 0x00100000;
    private const uint DM_DISPLAYFREQUENCY = 0x00400000;
    private const uint CDS_UPDATEREGISTRY = 0x00000001;
    private const uint CDS_TEST = 0x00000002;

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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;
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

    private class ModeEntry
    {
        public DEVMODE DevMode;
        public uint Width;
        public uint Height;
        public uint Hertz;
        public uint BitsPerPel;

        public string Label()
        {
            string hz = Hertz == 0 ? "default Hz" : Hertz.ToString() + " Hz";
            return Width + "x" + Height + " @ " + hz + ", " + BitsPerPel + " bpp";
        }
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true)]
    private static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr hModule);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

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

    private static DEVMODE NewDevMode()
    {
        DEVMODE dm = new DEVMODE();
        dm.dmDeviceName = new string(new char[32]);
        dm.dmFormName = new string(new char[32]);
        dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        return dm;
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
        if (!String.IsNullOrWhiteSpace(d.FriendlyName)) parts.Add(d.FriendlyName.Trim());
        parts.Add(String.IsNullOrWhiteSpace(d.Name) ? "unknown display" : d.Name.Trim());
        if (!String.IsNullOrWhiteSpace(d.ConnectionType)) parts.Add(d.ConnectionType.Trim());
        if (!String.IsNullOrWhiteSpace(d.EdidText)) parts.Add(d.EdidText.Trim());
        parts.Add("displayId=0x" + d.DisplayId.ToString("X8"));
        return String.Join(" - ", parts.ToArray());
    }

    private static int DisplayNumberFromName(string name)
    {
        string n = NormalizeDisplayName(name);
        int pos = n.IndexOf("DISPLAY");
        if (pos < 0) return -1;
        string digits = "";
        for (int i = pos + 7; i < n.Length; i++)
        {
            if (n[i] >= '0' && n[i] <= '9') digits += n[i];
            else if (digits.Length > 0) break;
        }
        int value;
        if (digits.Length > 0 && Int32.TryParse(digits, out value)) return value;
        return -1;
    }

    private static bool MatchesDisplayFilter(DisplayInfo display, string displayFilter)
    {
        if (display == null || String.IsNullOrWhiteSpace(displayFilter)) return false;

        string f = displayFilter.Trim();
        string normalizedFilter = NormalizeDisplayName(f);
        string normalizedName = NormalizeDisplayName(display.Name);
        string normalizedFriendly = NormalizeDisplayName(display.FriendlyName);
        string normalizedLabel = NormalizeDisplayName(DisplayLabel(display));
        string normalizedDevicePath = NormalizeDisplayName(display.MonitorDevicePath);

        if (normalizedName == normalizedFilter || normalizedFriendly == normalizedFilter || normalizedLabel == normalizedFilter) return true;
        if (normalizedFilter.StartsWith("DISPLAY", StringComparison.OrdinalIgnoreCase)) return normalizedName == normalizedFilter;

        if (f.StartsWith("index:", StringComparison.OrdinalIgnoreCase))
        {
            uint requestedIndex;
            if (UInt32.TryParse(f.Substring(6).Trim(), out requestedIndex)) return display.Index == requestedIndex;
            return false;
        }

        if (f.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                uint requestedDisplayId = Convert.ToUInt32(f.Substring(2), 16);
                return display.DisplayId == requestedDisplayId;
            }
            catch { return false; }
        }

        uint requestedNumber;
        if (UInt32.TryParse(f, out requestedNumber))
        {
            int displayNumber = DisplayNumberFromName(display.Name);
            if (displayNumber == (int)requestedNumber) return true;
            if (display.Index + 1 == requestedNumber) return true;
            return false;
        }

        return normalizedName.Contains(normalizedFilter) || normalizedFriendly.Contains(normalizedFilter) || normalizedLabel.Contains(normalizedFilter) || normalizedDevicePath.Contains(normalizedFilter);
    }

    private static List<DisplayInfo> PromptForDisplaySelection(List<DisplayInfo> displays)
    {
        if (displays == null || displays.Count == 0) throw new InvalidOperationException("No active NVIDIA displays were found.");

        Console.WriteLine();
        Console.WriteLine("Choose NVIDIA display to change:");
        for (int i = 0; i < displays.Count; i++)
        {
            Console.WriteLine("  " + (i + 1) + ") " + DisplayLabel(displays[i]));
        }
        Console.WriteLine("  A) All displays");

        while (true)
        {
            Console.Write("Selection [1-" + displays.Count + ", A]: ");
            string answer = Console.ReadLine();
            if (answer == null) throw new InvalidOperationException("Display selection was cancelled.");
            answer = answer.Trim();
            if (answer.Equals("A", StringComparison.OrdinalIgnoreCase) || answer.Equals("ALL", StringComparison.OrdinalIgnoreCase)) return new List<DisplayInfo>(displays);

            int menuIndex;
            if (Int32.TryParse(answer, out menuIndex) && menuIndex >= 1 && menuIndex <= displays.Count) return new List<DisplayInfo> { displays[menuIndex - 1] };

            List<DisplayInfo> matched = new List<DisplayInfo>();
            foreach (DisplayInfo d in displays) if (MatchesDisplayFilter(d, answer)) matched.Add(d);
            if (matched.Count == 1) return matched;
            if (matched.Count > 1) Console.WriteLine("That selection matched more than one display. Use the menu number, DISPLAYn, monitor name, index:n, or displayId.");
            else Console.WriteLine("Enter a menu number, A/all, DISPLAYn, monitor name, index:n, or a displayId such as 0x80061086.");
        }
    }

    private static string FormatName(byte value)
    {
        if (value == NV_COLOR_FORMAT_RGB) return "RGB";
        if (value == NV_COLOR_FORMAT_YUV422) return "YCbCr/YUV 4:2:2";
        if (value == NV_COLOR_FORMAT_YUV444) return "YCbCr/YUV 4:4:4";
        if (value == NV_COLOR_FORMAT_YUV420) return "YCbCr/YUV 4:2:0";
        if (value == NV_COLOR_FORMAT_DEFAULT) return "default";
        if (value == NV_COLOR_FORMAT_AUTO) return "auto";
        return value.ToString();
    }

    private static string ChromaName(byte value)
    {
        if (value == NV_COLOR_FORMAT_RGB) return "none/RGB";
        if (value == NV_COLOR_FORMAT_YUV422) return "4:2:2";
        if (value == NV_COLOR_FORMAT_YUV444) return "4:4:4";
        if (value == NV_COLOR_FORMAT_YUV420) return "4:2:0";
        if (value == NV_COLOR_FORMAT_DEFAULT) return "default";
        if (value == NV_COLOR_FORMAT_AUTO) return "auto";
        return value.ToString();
    }

    private static string ColorimetryName(byte value)
    {
        if (value == 0) return "RGB";
        if (value == 1) return "YCC601";
        if (value == 2) return "YCC709";
        if (value == 8) return "BT2020RGB";
        if (value == 9) return "BT2020YCC";
        if (value == NV_COLOR_COLORIMETRY_DEFAULT) return "default";
        if (value == NV_COLOR_COLORIMETRY_AUTO) return "auto";
        return value.ToString();
    }

    private static string RangeName(byte value)
    {
        if (value == NV_COLOR_DYNAMIC_RANGE_VESA) return "PC/full";
        if (value == NV_COLOR_DYNAMIC_RANGE_CEA) return "TV/limited";
        if (value == NV_COLOR_DYNAMIC_RANGE_AUTO) return "auto";
        return value.ToString();
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

    private static string DescribeColorData(NV_COLOR_DATA_V5 data)
    {
        return "format=" + FormatName(data.data.colorFormat) +
            ", chroma=" + ChromaName(data.data.colorFormat) +
            ", range=" + RangeName(data.data.dynamicRange) +
            ", colorimetry=" + ColorimetryName(data.data.colorimetry) +
            ", bpc=" + BpcName(data.data.bpc) +
            ", desktop_depth=" + DepthName(data.data.depth) +
            ", policy=" + data.data.colorSelectionPolicy;
    }

    private static byte? ParseFormat(string value)
    {
        if (String.IsNullOrWhiteSpace(value)) return null;
        string v = value.Trim().ToUpperInvariant().Replace(" ", "").Replace("-", "").Replace(":", "").Replace("_", "");
        if (v == "K" || v == "KEEP" || v == "CURRENT") return null;
        if (v == "RGB") return NV_COLOR_FORMAT_RGB;
        if (v == "YCBCR444" || v == "YUV444" || v == "444" || v == "YCBCr444".ToUpperInvariant()) return NV_COLOR_FORMAT_YUV444;
        if (v == "YCBCR422" || v == "YUV422" || v == "422") return NV_COLOR_FORMAT_YUV422;
        if (v == "YCBCR420" || v == "YUV420" || v == "420") return NV_COLOR_FORMAT_YUV420;
        if (v == "AUTO") return NV_COLOR_FORMAT_AUTO;
        if (v == "DEFAULT") return NV_COLOR_FORMAT_DEFAULT;
        throw new ArgumentException("Unknown output format '" + value + "'. Use RGB, YCbCr444, YCbCr422, YCbCr420, Auto, or Keep.");
    }

    private static byte? ParseRange(string value)
    {
        if (String.IsNullOrWhiteSpace(value)) return null;
        string v = value.Trim().ToUpperInvariant().Replace(" ", "").Replace("-", "").Replace("_", "");
        if (v == "K" || v == "KEEP" || v == "CURRENT") return null;
        if (v == "PC" || v == "FULL" || v == "VESA" || v == "0") return NV_COLOR_DYNAMIC_RANGE_VESA;
        if (v == "TV" || v == "LIMITED" || v == "CEA" || v == "1") return NV_COLOR_DYNAMIC_RANGE_CEA;
        if (v == "AUTO" || v == "2") return NV_COLOR_DYNAMIC_RANGE_AUTO;
        throw new ArgumentException("Unknown range '" + value + "'. Use PC/Full, TV/Limited, Auto, or Keep.");
    }

    private static byte PromptForFormat(NV_COLOR_DATA_V5 current)
    {
        Console.WriteLine();
        Console.WriteLine("Choose NVIDIA output format / chroma subsampling:");
        Console.WriteLine("  K) Keep current - " + FormatName(current.data.colorFormat));
        Console.WriteLine("  1) RGB - no chroma subsampling");
        Console.WriteLine("  2) YCbCr 4:4:4");
        Console.WriteLine("  3) YCbCr 4:2:2");
        Console.WriteLine("  4) YCbCr 4:2:0");
        Console.WriteLine("  5) Auto");

        while (true)
        {
            Console.Write("Selection [K, 1-5]: ");
            string a = Console.ReadLine();
            if (a == null) throw new InvalidOperationException("Output format selection was cancelled.");
            a = a.Trim();
            if (a.Equals("K", StringComparison.OrdinalIgnoreCase) || a.Equals("KEEP", StringComparison.OrdinalIgnoreCase) || a == "") return current.data.colorFormat;
            if (a == "1") return NV_COLOR_FORMAT_RGB;
            if (a == "2") return NV_COLOR_FORMAT_YUV444;
            if (a == "3") return NV_COLOR_FORMAT_YUV422;
            if (a == "4") return NV_COLOR_FORMAT_YUV420;
            if (a == "5" || a.Equals("AUTO", StringComparison.OrdinalIgnoreCase)) return NV_COLOR_FORMAT_AUTO;
            try { return ParseFormat(a).Value; } catch { Console.WriteLine("Enter K, 1, 2, 3, 4, 5, RGB, YCbCr444, YCbCr422, or YCbCr420."); }
        }
    }

    private static byte PromptForRange(NV_COLOR_DATA_V5 current)
    {
        Console.WriteLine();
        Console.WriteLine("Choose output dynamic range:");
        Console.WriteLine("  K) Keep current - " + RangeName(current.data.dynamicRange));
        Console.WriteLine("  1) PC / Full range");
        Console.WriteLine("  2) TV / Limited range");
        Console.WriteLine("  3) Auto");

        while (true)
        {
            Console.Write("Selection [K, 1-3]: ");
            string a = Console.ReadLine();
            if (a == null) throw new InvalidOperationException("Range selection was cancelled.");
            a = a.Trim();
            if (a.Equals("K", StringComparison.OrdinalIgnoreCase) || a.Equals("KEEP", StringComparison.OrdinalIgnoreCase) || a == "") return current.data.dynamicRange;
            if (a == "1") return NV_COLOR_DYNAMIC_RANGE_VESA;
            if (a == "2") return NV_COLOR_DYNAMIC_RANGE_CEA;
            if (a == "3" || a.Equals("AUTO", StringComparison.OrdinalIgnoreCase)) return NV_COLOR_DYNAMIC_RANGE_AUTO;
            try { return ParseRange(a).Value; } catch { Console.WriteLine("Enter K, 1, 2, 3, PC, Full, TV, Limited, or Auto."); }
        }
    }

    private static List<ModeEntry> GetDisplayModes(string displayName)
    {
        List<ModeEntry> modes = new List<ModeEntry>();
        HashSet<string> seen = new HashSet<string>();

        for (int i = 0; ; i++)
        {
            DEVMODE dm = NewDevMode();
            if (!EnumDisplaySettings(displayName, i, ref dm)) break;
            if (dm.dmPelsWidth < 640 || dm.dmPelsHeight < 480) continue;
            string key = dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency + "x" + dm.dmBitsPerPel;
            if (seen.Contains(key)) continue;
            seen.Add(key);
            ModeEntry e = new ModeEntry();
            e.DevMode = dm;
            e.Width = dm.dmPelsWidth;
            e.Height = dm.dmPelsHeight;
            e.Hertz = dm.dmDisplayFrequency;
            e.BitsPerPel = dm.dmBitsPerPel;
            modes.Add(e);
        }

        modes.Sort(delegate(ModeEntry a, ModeEntry b)
        {
            int c = b.Width.CompareTo(a.Width); if (c != 0) return c;
            c = b.Height.CompareTo(a.Height); if (c != 0) return c;
            c = b.Hertz.CompareTo(a.Hertz); if (c != 0) return c;
            return b.BitsPerPel.CompareTo(a.BitsPerPel);
        });
        return modes;
    }

    private static ModeEntry GetCurrentMode(string displayName)
    {
        DEVMODE dm = NewDevMode();
        if (!EnumDisplaySettings(displayName, ENUM_CURRENT_SETTINGS, ref dm)) return null;
        ModeEntry e = new ModeEntry();
        e.DevMode = dm;
        e.Width = dm.dmPelsWidth;
        e.Height = dm.dmPelsHeight;
        e.Hertz = dm.dmDisplayFrequency;
        e.BitsPerPel = dm.dmBitsPerPel;
        return e;
    }

    private static bool SameMode(ModeEntry a, ModeEntry b)
    {
        if (a == null || b == null) return false;
        return a.Width == b.Width && a.Height == b.Height && a.Hertz == b.Hertz && a.BitsPerPel == b.BitsPerPel;
    }

    private static ModeEntry FindModeBySpec(List<ModeEntry> modes, ModeEntry current, string spec, uint refreshRate)
    {
        if (String.IsNullOrWhiteSpace(spec) || spec.Equals("keep", StringComparison.OrdinalIgnoreCase) || spec.Equals("current", StringComparison.OrdinalIgnoreCase)) return null;
        string s = spec.Trim().ToLowerInvariant().Replace(" ", "");
        s = s.Replace("hz", "");
        uint w = 0, h = 0, hz = refreshRate;
        int at = s.IndexOf('@');
        string res = at >= 0 ? s.Substring(0, at) : s;
        if (at >= 0)
        {
            UInt32.TryParse(s.Substring(at + 1), out hz);
        }
        string[] parts = res.Split(new char[] { 'x', '*' });
        if (parts.Length != 2 || !UInt32.TryParse(parts[0], out w) || !UInt32.TryParse(parts[1], out h))
        {
            throw new ArgumentException("Resolution must look like 3840x2160 or 3840x2160@144.");
        }

        List<ModeEntry> candidates = new List<ModeEntry>();
        foreach (ModeEntry m in modes)
        {
            if (m.Width == w && m.Height == h)
            {
                if (hz == 0 || m.Hertz == hz) candidates.Add(m);
            }
        }
        if (candidates.Count == 0) throw new InvalidOperationException("Requested mode " + spec + " was not found for this display.");

        if (current != null)
        {
            foreach (ModeEntry m in candidates) if (m.Hertz == current.Hertz && m.BitsPerPel == current.BitsPerPel) return m;
        }

        candidates.Sort(delegate(ModeEntry a, ModeEntry b)
        {
            int c = b.Hertz.CompareTo(a.Hertz); if (c != 0) return c;
            return b.BitsPerPel.CompareTo(a.BitsPerPel);
        });
        return candidates[0];
    }

    private static ModeEntry PromptForResolution(string displayName, ModeEntry current)
    {
        List<ModeEntry> modes = GetDisplayModes(displayName);
        if (modes.Count == 0)
        {
            Console.WriteLine("No modes returned by EnumDisplaySettings; keeping current resolution.");
            return null;
        }

        Console.WriteLine();
        Console.WriteLine("Choose Windows resolution / refresh rate:");
        Console.WriteLine("  K) Keep current - " + (current == null ? "unknown" : current.Label()));
        for (int i = 0; i < modes.Count; i++)
        {
            string marker = SameMode(modes[i], current) ? "  [current]" : "";
            Console.WriteLine("  " + (i + 1) + ") " + modes[i].Label() + marker);
        }

        while (true)
        {
            Console.Write("Selection [K, 1-" + modes.Count + ", or WxH[@Hz]]: ");
            string a = Console.ReadLine();
            if (a == null) throw new InvalidOperationException("Resolution selection was cancelled.");
            a = a.Trim();
            if (a == "" || a.Equals("K", StringComparison.OrdinalIgnoreCase) || a.Equals("KEEP", StringComparison.OrdinalIgnoreCase)) return null;
            int index;
            if (Int32.TryParse(a, out index) && index >= 1 && index <= modes.Count) return modes[index - 1];
            try { return FindModeBySpec(modes, current, a, 0); } catch (Exception ex) { Console.WriteLine(ex.Message); }
        }
    }

    private static string DispChangeText(int value)
    {
        if (value == DISP_CHANGE_SUCCESSFUL) return "success";
        if (value == DISP_CHANGE_RESTART) return "restart required";
        if (value == DISP_CHANGE_FAILED) return "failed";
        if (value == DISP_CHANGE_BADMODE) return "bad mode";
        if (value == DISP_CHANGE_NOTUPDATED) return "registry not updated";
        if (value == DISP_CHANGE_BADFLAGS) return "bad flags";
        if (value == DISP_CHANGE_BADPARAM) return "bad parameter";
        if (value == DISP_CHANGE_BADDUALVIEW) return "bad dual-view";
        return value.ToString();
    }

    private static void ApplyResolution(string displayName, ModeEntry mode, bool dryRun)
    {
        if (mode == null)
        {
            Console.WriteLine("  resolution: keep current");
            return;
        }
        DEVMODE dm = mode.DevMode;
        dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        dm.dmFields = dm.dmFields | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;

        Console.WriteLine("  desired resolution: " + mode.Label());
        if (dryRun)
        {
            Console.WriteLine("  dry-run: no Windows resolution change applied");
            return;
        }

        int test = ChangeDisplaySettingsEx(displayName, ref dm, IntPtr.Zero, CDS_TEST, IntPtr.Zero);
        if (test != DISP_CHANGE_SUCCESSFUL)
        {
            Console.WriteLine("  skipped resolution: test failed: " + DispChangeText(test) + " (" + test + ")");
            return;
        }

        int ret = ChangeDisplaySettingsEx(displayName, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
        if (ret == DISP_CHANGE_SUCCESSFUL)
        {
            Console.WriteLine("  resolution applied");
        }
        else if (ret == DISP_CHANGE_RESTART)
        {
            Console.WriteLine("  resolution applied, but Windows reports restart required");
        }
        else
        {
            Console.WriteLine("  resolution failed: " + DispChangeText(ret) + " (" + ret + ")");
        }
    }

    private static NV_COLOR_DATA_V5 BuildCandidate(NV_COLOR_DATA_V5 current, byte format, byte range)
    {
        NV_COLOR_DATA_V5 candidate = current;
        candidate.cmd = NV_COLOR_CMD_SET;
        candidate.data.colorFormat = format;
        candidate.data.dynamicRange = range;
        candidate.data.colorSelectionPolicy = NV_COLOR_SELECTION_POLICY_USER;

        if (format == NV_COLOR_FORMAT_RGB)
        {
            candidate.data.colorimetry = NV_COLOR_COLORIMETRY_RGB;
        }
        else if (format == NV_COLOR_FORMAT_AUTO || format == NV_COLOR_FORMAT_DEFAULT)
        {
            candidate.data.colorimetry = NV_COLOR_COLORIMETRY_AUTO;
        }
        else
        {
            candidate.data.colorimetry = NV_COLOR_COLORIMETRY_AUTO;
        }

        return candidate;
    }

    private static bool ColorEquivalent(NV_COLOR_DATA_V5 current, NV_COLOR_DATA_V5 desired)
    {
        return current.data.colorFormat == desired.data.colorFormat &&
            current.data.dynamicRange == desired.data.dynamicRange &&
            current.data.colorimetry == desired.data.colorimetry;
    }

    private static void ApplyColor(NvApi nv, DisplayInfo d, NV_COLOR_DATA_V5 current, byte format, byte range, bool dryRun, bool skipSupportCheck)
    {
        NV_COLOR_DATA_V5 desired = BuildCandidate(current, format, range);
        Console.WriteLine("  desired output: " + DescribeColorData(desired));

        if (ColorEquivalent(current, desired))
        {
            Console.WriteLine("  NVIDIA output format/range already matches request");
            return;
        }

        if (!skipSupportCheck)
        {
            int status = nv.IsSupportedColor(d.DisplayId, desired);
            if (status != NVAPI_OK)
            {
                Console.WriteLine("  skipped NVIDIA output change: requested combination is not reported as supported: " + nv.StatusText(status) + " (" + status + ")");
                return;
            }
        }

        if (dryRun)
        {
            Console.WriteLine("  dry-run: no NVIDIA output format/range change applied");
            return;
        }

        nv.SetColor(d.DisplayId, desired);
        NV_COLOR_DATA_V5 after = nv.GetColor(d.DisplayId);
        Console.WriteLine("  after NVIDIA output: " + DescribeColorData(after));
    }

    private static List<DisplayInfo> ResolveDisplays(NvApi nv, string displayFilter, bool allDisplays)
    {
        List<DisplayInfo> displays = nv.EnumerateDisplays();
        if (displays.Count == 0) throw new InvalidOperationException("No active NVIDIA displays were found.");

        if (!String.IsNullOrWhiteSpace(displayFilter))
        {
            List<DisplayInfo> filtered = new List<DisplayInfo>();
            foreach (DisplayInfo d in displays) if (MatchesDisplayFilter(d, displayFilter)) filtered.Add(d);
            if (filtered.Count == 0) throw new InvalidOperationException("No NVIDIA display matched '" + displayFilter + "'. Use DISPLAY1, a monitor name, a menu number like 1, index:0, or a displayId like 0x80061086.");
            return filtered;
        }

        if (allDisplays) return displays;
        return PromptForDisplaySelection(displays);
    }

    public static void Run(string displayFilter, bool allDisplays, string outputFormat, string range, string resolution, uint refreshRate, bool dryRun, bool skipSupportCheck)
    {
        using (NvApi nv = new NvApi())
        {
            nv.Initialize();
            List<DisplayInfo> selected = ResolveDisplays(nv, displayFilter, allDisplays);

            Console.WriteLine();
            Console.WriteLine("NVIDIA displays to process:");
            foreach (DisplayInfo d in selected) Console.WriteLine("  " + DisplayLabel(d));

            byte? nonInteractiveFormat = ParseFormat(outputFormat);
            byte? nonInteractiveRange = ParseRange(range);

            foreach (DisplayInfo d in selected)
            {
                Console.WriteLine();
                Console.WriteLine(DisplayLabel(d));

                ModeEntry currentMode = GetCurrentMode(d.Name);
                Console.WriteLine("  current Windows mode: " + (currentMode == null ? "unknown" : currentMode.Label()));

                NV_COLOR_DATA_V5 currentColor = nv.GetColor(d.DisplayId);
                Console.WriteLine("  current NVIDIA output: " + DescribeColorData(currentColor));

                ModeEntry targetMode = null;
                if (!String.IsNullOrWhiteSpace(resolution))
                {
                    targetMode = FindModeBySpec(GetDisplayModes(d.Name), currentMode, resolution, refreshRate);
                }
                else
                {
                    targetMode = PromptForResolution(d.Name, currentMode);
                }

                byte targetFormat = nonInteractiveFormat.HasValue ? nonInteractiveFormat.Value : PromptForFormat(currentColor);
                byte targetRange = nonInteractiveRange.HasValue ? nonInteractiveRange.Value : PromptForRange(currentColor);

                ApplyResolution(d.Name, targetMode, dryRun);

                // Re-read color after resolution change; the driver may change valid color choices with a new timing.
                currentColor = nv.GetColor(d.DisplayId);
                ApplyColor(nv, d, currentColor, targetFormat, targetRange, dryRun, skipSupportCheck);
            }
        }
    }
}

'@

try {
    if (-not ('WinDisplayConfig' -as [type]) -or -not ('NvApiOutputControl' -as [type])) {
        Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
    }
}
catch {
    Write-Error "Failed to compile embedded C# interop code: $($_.Exception.Message)"
    exit 1
}

try {
    [NvApiOutputControl]::Run(
        [string]$Display,
        [bool]$AllDisplays,
        [string]$OutputFormat,
        [string]$Range,
        [string]$Resolution,
        [uint32]$RefreshRate,
        [bool]$DryRun,
        [bool]$SkipSupportCheck
    )
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

Write-Host ''
Write-Host 'Done. Verify in NVIDIA Control Panel and Windows Settings > System > Display > Advanced display.'
