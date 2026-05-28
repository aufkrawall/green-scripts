# MIT License
# Copyright (c) 2026 aufkrawall
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Select a display and configure NVIDIA G-SYNC / G-SYNC Compatible mode, including the selected-display checkbox. Adds display-profile DRS override support, automatic DisplayDatabase key selection, admin-required NVIDIA driver reinit, and optional debug logging, enabled with --debug.

.DESCRIPTION
    This script follows the same pattern as the previous NVIDIA scripts:
      - embedded C# interop
      - display selection with monitor names where Windows exposes them
      - current status shown before changes
      - NVIDIA NVAPI DRS/profile settings for global G-SYNC/VRR mode
      - optional timestamped debug transcript and registry snapshots
      - automatic NvAPI_RestartDisplayDriver after applying selected-display G-SYNC changes

    It controls:
      1. Global G-SYNC mode: disabled, fullscreen only, or fullscreen + windowed/borderless
      2. The driver VRR control flag used by NVIDIA's G-SYNC path. When global mode is disabled,
         this flag is forced disabled and is not offered interactively.

    In addition to the global NVIDIA DRS VRR settings, this version also writes the per-display
    NVIDIA DRS profile override observed in the DRS database when toggling NVIDIA Control Panel's
    "Enable settings for the selected display model" checkbox, and still writes the mirrored
    MonitorDataRegistryKey flag. The last DWORD of that binary value is recomputed as a simple
    checksum over the first 16 bytes.

.NOTES
    Requirements:
      - Windows 10/11
      - NVIDIA driver with NVAPI installed
      - 64-bit PowerShell recommended
      - Administrator / UAC-elevated PowerShell is required

    Debug logging is disabled by default. Use --debug to enable debug logging.
#>

[CmdletBinding()]
param(
    [string]$Display,

    [switch]$AllDisplays,

    [ValidateSet('', 'Disabled', 'None', 'Off', 'Fullscreen', 'FullscreenOnly', 'FullscreenAndWindowed', 'Windowed', 'Borderless')]
    [string]$Mode = '',

    [ValidateSet('', 'Enable', 'Enabled', 'On', 'Disable', 'Disabled', 'Off', 'Keep')]
    [string]$DisplayGSync = '',

    [switch]$NoDisplayReset,

    # Optional exact/substring DisplayDatabase key override. If omitted, the script auto-selects the active-looking key.
    # Example: -DisplayDbKey DEL428B2WY36H3_04_07E6_9E or -DisplayDbKey _9E
    [string]$DisplayDbKey = '',

    # Apply the selected-display flag to all matching DisplayDatabase keys instead of auto-selecting one.
    [switch]$AllMatchingDisplayDbKeys,

    # Stronger reload path. This calls NVIDIA's private NvAPI_RestartDisplayDriver after writing the flag.
    # Administrator / UAC elevation is required; the script exits before doing any work if not elevated.
    [switch]$RestartNvidiaDriver,

    # Keep the old weaker Windows same-mode reset instead of restarting the NVIDIA display driver.
    # Use this only for diagnostics; it usually does not cause the same reinit as NVIDIA Control Panel.
    [switch]$NoDriverRestart,

    # Writes a timestamped transcript and registry snapshots. Disabled by default.
    [switch]$DebugLog,

    # Optional debug output folder. Used only with --debug / -DebugLog. Default: .\nvidia_gsync_debug_yyyyMMdd_HHmmss
    [string]$DebugDirectory = '',

    # Skip before/after registry exports of NVIDIA's DisplayDatabase tree.
    [switch]$NoDebugRegistryExport,

    [switch]$DryRun
)

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Error 'This script must be run on Windows.'
    exit 2
}

$script:DebugLogStarted = $false
$script:DebugDirectoryPath = $null
$script:DebugTranscriptPath = $null
$script:DebugZipPath = $null
$script:DebugRequested = ([bool]$DebugLog -or ($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']))

function Initialize-DebugLog {
    if (-not $script:DebugRequested) {
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    if ([string]::IsNullOrWhiteSpace($DebugDirectory)) {
        $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $script:DebugDirectoryPath = Join-Path $base "nvidia_gsync_debug_$timestamp"
    }
    else {
        $script:DebugDirectoryPath = $DebugDirectory
    }

    New-Item -ItemType Directory -Path $script:DebugDirectoryPath -Force | Out-Null
    $script:DebugTranscriptPath = Join-Path $script:DebugDirectoryPath 'transcript.log'

    try {
        Start-Transcript -Path $script:DebugTranscriptPath -Force | Out-Null
        $script:DebugLogStarted = $true
    }
    catch {
        Write-Warning "Could not start transcript logging: $($_.Exception.Message)"
    }

    Write-Host "Debug log folder: $script:DebugDirectoryPath"
    Write-Host "Debug transcript: $script:DebugTranscriptPath"

    $metadataPath = Join-Path $script:DebugDirectoryPath 'metadata.txt'
    $admin = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {}

    $metadata = @()
    $metadata += "timestamp=$(Get-Date -Format o)"
    $metadata += "script=$PSCommandPath"
    $metadata += "pwd=$((Get-Location).Path)"
    $metadata += "user=$env:USERNAME"
    $metadata += "computer=$env:COMPUTERNAME"
    $metadata += "is_admin=$admin"
    $metadata += "admin_required=True"
    $metadata += "ps_version=$($PSVersionTable.PSVersion)"
    $metadata += "ps_edition=$($PSVersionTable.PSEdition)"
    $metadata += "os=$([Environment]::OSVersion.VersionString)"
    $metadata += "process_64bit=$([Environment]::Is64BitProcess)"
    $metadata += "display=$Display"
    $metadata += "all_displays=$AllDisplays"
    $metadata += "mode=$Mode"
    $metadata += "display_gsync=$DisplayGSync"
    $metadata += "display_db_key=$DisplayDbKey"
    $metadata += "all_matching_display_db_keys=$AllMatchingDisplayDbKeys"
    $metadata += "restart_nvidia_driver=$RestartNvidiaDriver"
    $metadata += "no_display_reset=$NoDisplayReset"
    $metadata += "dry_run=$DryRun"
    $metadata += "debug_log=$script:DebugRequested"
    $metadata += "no_debug_registry_export=$NoDebugRegistryExport"
    $metadata | Set-Content -Path $metadataPath -Encoding UTF8
}

function Export-DebugRegistrySnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$Name
    )

    if ((-not $script:DebugRequested) -or $NoDebugRegistryExport -or [string]::IsNullOrWhiteSpace($script:DebugDirectoryPath)) {
        return
    }

    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $displayDbPath = Join-Path $script:DebugDirectoryPath "${safeName}_nvlddmkm_displaydatabase.reg"
    $servicesStatePath = Join-Path $script:DebugDirectoryPath "${safeName}_nvlddmkm_state.reg"

    Write-Host "[debug] Exporting NVIDIA registry snapshot '$Name'..."

    try {
        & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase' $displayDbPath /y | Out-Host
    }
    catch {
        Write-Warning "Could not export DisplayDatabase registry snapshot '$Name': $($_.Exception.Message)"
    }

    # Smaller than exporting all NVIDIA software keys, but broad enough to catch adjacent nvlddmkm state changes.
    try {
        & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\State' $servicesStatePath /y | Out-Host
    }
    catch {
        Write-Warning "Could not export nvlddmkm State registry snapshot '$Name': $($_.Exception.Message)"
    }
}

function Write-DebugLogSummary {
    if ((-not $script:DebugRequested) -or [string]::IsNullOrWhiteSpace($script:DebugDirectoryPath)) {
        return
    }

    $summaryPath = Join-Path $script:DebugDirectoryPath 'debug_summary.txt'
    $lines = @()
    $lines += "Debug folder: $script:DebugDirectoryPath"
    $lines += "Transcript: $script:DebugTranscriptPath"
    $lines += "Created: $(Get-Date -Format o)"
    $lines += "Registry exports: $(-not $NoDebugRegistryExport)"
    $lines += ''
    $lines += 'Useful files:'
    $lines += '  metadata.txt'
    $lines += '  transcript.log'
    $lines += '  before_nvlddmkm_displaydatabase.reg / after_nvlddmkm_displaydatabase.reg, if registry export was enabled'
    $lines | Set-Content -Path $summaryPath -Encoding UTF8
}

function Complete-DebugLog {
    if ((-not $script:DebugRequested) -or [string]::IsNullOrWhiteSpace($script:DebugDirectoryPath)) {
        return
    }

    Write-DebugLogSummary

    if ($script:DebugLogStarted) {
        try { Stop-Transcript | Out-Null } catch {}
        $script:DebugLogStarted = $false
    }

    try {
        $parent = Split-Path -Parent $script:DebugDirectoryPath
        $leaf = Split-Path -Leaf $script:DebugDirectoryPath
        $zipPath = Join-Path $parent "$leaf.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path (Join-Path $script:DebugDirectoryPath '*') -DestinationPath $zipPath -Force
        $script:DebugZipPath = $zipPath
        Write-Host "Debug ZIP: $zipPath"
    }
    catch {
        Write-Warning "Could not create debug ZIP: $($_.Exception.Message)"
    }
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

$script:IsElevated = Test-IsAdministrator

if (-not $script:IsElevated) {
    Write-Error 'Administrator privileges are required. Start PowerShell as Administrator / UAC-elevated, then run this script again. No NVIDIA settings were changed.'
    exit 1
}

Initialize-DebugLog

$csharp = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

public static class WinDisplayConfigGSyncRegistry
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

public static class NvApiGSyncControlRegistry
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
    private const uint ID_NvAPI_RestartDisplayDriver = 0xB4B26B65;


    private const uint ID_NvAPI_DRS_CreateSession = 0x0694D52E;
    private const uint ID_NvAPI_DRS_DestroySession = 0xDAD9CFF8;
    private const uint ID_NvAPI_DRS_LoadSettings = 0x375DBD6B;
    private const uint ID_NvAPI_DRS_SaveSettings = 0xFCBC7E14;
    private const uint ID_NvAPI_DRS_GetCurrentGlobalProfile = 0x617BFF9F;
    private const uint ID_NvAPI_DRS_GetSetting = 0x73BF8338;
    private const uint ID_NvAPI_DRS_SetSetting = 0x577DD202;
    private const uint ID_NvAPI_DRS_FindProfileByName = 0x7E4A9A0B;
    private const uint ID_NvAPI_DRS_DeleteProfileSetting = 0xE4A26362;

    private const uint DRS_VRR_FEATURE_INDICATOR = 0x1094F157;
    private const uint DRS_VRR_REQUEST_STATE = 0x1094F1F7;
    private const uint DRS_VRR_MODE = 0x1194F158;
    private const uint DRS_VSYNC_VRR_CONTROL = 0x10A879CE;
    private const uint DRS_VRR_APP_OVERRIDE = 0x10A879CF;
    private const uint DRS_VRR_APP_OVERRIDE_REQUEST_STATE = 0x10A879AC;

    private const uint VRR_DISABLED = 0;
    private const uint VRR_FULLSCREEN_ONLY = 1;
    private const uint VRR_FULLSCREEN_AND_WINDOWED = 2;
    private const uint VRR_APP_ALLOW = 0;
    private const uint VSYNC_VRR_DISABLE = 0;
    private const uint VSYNC_VRR_ENABLE = 1;

    private const uint NVDRS_DWORD_TYPE = 0;
    private const uint NVDRS_CURRENT_PROFILE_LOCATION = 0;
    private const int NVAPI_SETTING_NOT_FOUND = -160;
    private const int NVAPI_PROFILE_NOT_FOUND = -163;

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


    [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Unicode, Size = 4100)]
    public struct NVDRS_SETTING_UNION
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100)]
        public byte[] rawData;

        public uint dwordValue
        {
            get
            {
                if (rawData == null || rawData.Length < 4) return 0;
                return BitConverter.ToUInt32(rawData, 0);
            }
            set
            {
                rawData = new byte[4100];
                Buffer.BlockCopy(BitConverter.GetBytes(value), 0, rawData, 0, 4);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Unicode)]
    public struct NVDRS_SETTING
    {
        public uint version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 2048)]
        public string settingName;
        public uint settingId;
        public uint settingType;
        public uint settingLocation;
        public uint isCurrentPredefined;
        public uint isPredefinedValid;
        public NVDRS_SETTING_UNION predefinedValue;
        public NVDRS_SETTING_UNION currentValue;
    }

    public class GSyncDrsState
    {
        public uint? VrrMode;
        public uint? VrrRequestState;
        public uint? VrrFeatureIndicator;
        public uint? VsyncVrrControl;
        public uint? VrrAppOverride;
        public uint? VrrAppOverrideRequestState;
    }

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

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void NvAPI_RestartDisplayDriverDelegate();


    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_CreateSessionDelegate(out IntPtr phSession);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_DestroySessionDelegate(IntPtr hSession);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_LoadSettingsDelegate(IntPtr hSession);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_SaveSettingsDelegate(IntPtr hSession);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_GetCurrentGlobalProfileDelegate(IntPtr hSession, out IntPtr phProfile);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_GetSettingDelegate(IntPtr hSession, IntPtr hProfile, uint settingId, ref NVDRS_SETTING pSetting, ref uint unknown);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_SetSettingDelegate(IntPtr hSession, IntPtr hProfile, ref NVDRS_SETTING pSetting, uint unknown1, uint unknown2);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_FindProfileByNameDelegate(IntPtr hSession, [MarshalAs(UnmanagedType.LPWStr, SizeConst = 2048)] StringBuilder profileName, out IntPtr phProfile);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvAPI_DRS_DeleteProfileSettingDelegate(IntPtr hSession, IntPtr hProfile, uint settingId);

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
        private NvAPI_RestartDisplayDriverDelegate restartDisplayDriver;


        private NvAPI_DRS_CreateSessionDelegate drsCreateSession;
        private NvAPI_DRS_DestroySessionDelegate drsDestroySession;
        private NvAPI_DRS_LoadSettingsDelegate drsLoadSettings;
        private NvAPI_DRS_SaveSettingsDelegate drsSaveSettings;
        private NvAPI_DRS_GetCurrentGlobalProfileDelegate drsGetCurrentGlobalProfile;
        private NvAPI_DRS_GetSettingDelegate drsGetSetting;
        private NvAPI_DRS_SetSettingDelegate drsSetSetting;
        private NvAPI_DRS_FindProfileByNameDelegate drsFindProfileByName;
        private NvAPI_DRS_DeleteProfileSettingDelegate drsDeleteProfileSetting;

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
            restartDisplayDriver = TryGetFunction<NvAPI_RestartDisplayDriverDelegate>(ID_NvAPI_RestartDisplayDriver);

            drsCreateSession = GetFunction<NvAPI_DRS_CreateSessionDelegate>(ID_NvAPI_DRS_CreateSession);
            drsDestroySession = GetFunction<NvAPI_DRS_DestroySessionDelegate>(ID_NvAPI_DRS_DestroySession);
            drsLoadSettings = GetFunction<NvAPI_DRS_LoadSettingsDelegate>(ID_NvAPI_DRS_LoadSettings);
            drsSaveSettings = GetFunction<NvAPI_DRS_SaveSettingsDelegate>(ID_NvAPI_DRS_SaveSettings);
            drsGetCurrentGlobalProfile = GetFunction<NvAPI_DRS_GetCurrentGlobalProfileDelegate>(ID_NvAPI_DRS_GetCurrentGlobalProfile);
            drsGetSetting = GetFunction<NvAPI_DRS_GetSettingDelegate>(ID_NvAPI_DRS_GetSetting);
            drsSetSetting = GetFunction<NvAPI_DRS_SetSettingDelegate>(ID_NvAPI_DRS_SetSetting);
            drsFindProfileByName = GetFunction<NvAPI_DRS_FindProfileByNameDelegate>(ID_NvAPI_DRS_FindProfileByName);
            drsDeleteProfileSetting = GetFunction<NvAPI_DRS_DeleteProfileSettingDelegate>(ID_NvAPI_DRS_DeleteProfileSetting);
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

        private T TryGetFunction<T>(uint id) where T : class
        {
            IntPtr ptr = query(id);
            if (ptr == IntPtr.Zero) return null;
            return Marshal.GetDelegateForFunctionPointer(ptr, typeof(T)) as T;
        }

        public void RestartDisplayDriver()
        {
            if (restartDisplayDriver == null)
            {
                Console.WriteLine("  NvAPI_RestartDisplayDriver is unavailable on this driver.");
                return;
            }
            Console.WriteLine("  calling NvAPI_RestartDisplayDriver; the display may blink or temporarily go black.");
            restartDisplayDriver();
            Console.WriteLine("  NvAPI_RestartDisplayDriver returned.");
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


        private static uint MakeNvapiVersion(Type t, int version)
        {
            return (uint)(Marshal.SizeOf(t) | (version << 16));
        }

        private static NVDRS_SETTING NewDrsSetting(uint settingId)
        {
            NVDRS_SETTING s = new NVDRS_SETTING();
            s.version = MakeNvapiVersion(typeof(NVDRS_SETTING), 1);
            s.settingName = "";
            s.settingId = settingId;
            s.settingType = NVDRS_DWORD_TYPE;
            s.settingLocation = NVDRS_CURRENT_PROFILE_LOCATION;
            s.predefinedValue = new NVDRS_SETTING_UNION { rawData = new byte[4100] };
            s.currentValue = new NVDRS_SETTING_UNION { rawData = new byte[4100] };
            return s;
        }

        private IntPtr OpenDrsSessionAndGlobalProfile(out IntPtr session)
        {
            session = IntPtr.Zero;
            Check(drsCreateSession(out session), "NvAPI_DRS_CreateSession");
            try
            {
                Check(drsLoadSettings(session), "NvAPI_DRS_LoadSettings");
                IntPtr profile;
                Check(drsGetCurrentGlobalProfile(session, out profile), "NvAPI_DRS_GetCurrentGlobalProfile");
                return profile;
            }
            catch
            {
                try { drsDestroySession(session); } catch { }
                session = IntPtr.Zero;
                throw;
            }
        }

        private uint? GetDrsDword(IntPtr session, IntPtr profile, uint settingId)
        {
            NVDRS_SETTING setting = NewDrsSetting(settingId);
            uint unknown = 0;
            int status = drsGetSetting(session, profile, settingId, ref setting, ref unknown);
            if (status == NVAPI_SETTING_NOT_FOUND || status == NVAPI_PROFILE_NOT_FOUND)
            {
                return null;
            }
            Check(status, "NvAPI_DRS_GetSetting(0x" + settingId.ToString("X8") + ")");
            return setting.currentValue.dwordValue;
        }

        private void SetDrsDword(IntPtr session, IntPtr profile, uint settingId, uint value)
        {
            NVDRS_SETTING setting = NewDrsSetting(settingId);
            setting.currentValue.dwordValue = value;
            setting.settingType = NVDRS_DWORD_TYPE;
            Check(drsSetSetting(session, profile, ref setting, 0, 0), "NvAPI_DRS_SetSetting(0x" + settingId.ToString("X8") + ")");
        }

        private void DeleteDrsSettingIfPresent(IntPtr session, IntPtr profile, uint settingId)
        {
            int status = drsDeleteProfileSetting(session, profile, settingId);
            if (status == NVAPI_OK)
            {
                Console.WriteLine("    deleted DRS setting 0x" + settingId.ToString("X8") + " from display profile");
                return;
            }
            if (status == NVAPI_SETTING_NOT_FOUND)
            {
                Console.WriteLine("    DRS setting 0x" + settingId.ToString("X8") + " was not present in display profile");
                return;
            }
            Check(status, "NvAPI_DRS_DeleteProfileSetting(0x" + settingId.ToString("X8") + ")");
        }

        private static string DisplayProfileNameFromDisplay(DisplayInfo d)
        {
            if (d == null || String.IsNullOrWhiteSpace(d.EdidText)) return "";
            string s = d.EdidText.Trim();
            if (s.StartsWith("edid=", StringComparison.OrdinalIgnoreCase))
            {
                s = s.Substring(5);
            }
            return s.Trim();
        }

        private bool TryFindDisplayDrsProfile(IntPtr session, string profileName, out IntPtr profile, out string usedProfileName)
        {
            profile = IntPtr.Zero;
            usedProfileName = "";
            if (String.IsNullOrWhiteSpace(profileName)) return false;

            string[] candidates = new string[] {
                profileName.Trim(),
                profileName.Trim().ToUpperInvariant(),
                profileName.Trim().ToLowerInvariant()
            };

            HashSet<string> tried = new HashSet<string>(StringComparer.Ordinal);
            foreach (string candidate in candidates)
            {
                if (String.IsNullOrWhiteSpace(candidate) || tried.Contains(candidate)) continue;
                tried.Add(candidate);

                StringBuilder sb = new StringBuilder(candidate);
                int status = drsFindProfileByName(session, sb, out profile);
                if (status == NVAPI_OK && profile != IntPtr.Zero)
                {
                    usedProfileName = candidate;
                    return true;
                }
                if (status != NVAPI_PROFILE_NOT_FOUND)
                {
                    Check(status, "NvAPI_DRS_FindProfileByName(" + candidate + ")");
                }
            }

            return false;
        }

        public uint? GetSelectedDisplayProfileVrrOverride(DisplayInfo d)
        {
            string desiredProfile = DisplayProfileNameFromDisplay(d);
            if (String.IsNullOrWhiteSpace(desiredProfile)) return null;

            IntPtr session = IntPtr.Zero;
            try
            {
                Check(drsCreateSession(out session), "NvAPI_DRS_CreateSession");
                Check(drsLoadSettings(session), "NvAPI_DRS_LoadSettings");

                IntPtr profile;
                string usedProfile;
                if (!TryFindDisplayDrsProfile(session, desiredProfile, out profile, out usedProfile))
                {
                    return null;
                }

                return GetDrsDword(session, profile, DRS_VRR_MODE);
            }
            finally
            {
                if (session != IntPtr.Zero) drsDestroySession(session);
            }
        }

        public void PrintSelectedDisplayProfileVrrOverride(DisplayInfo d)
        {
            string desiredProfile = DisplayProfileNameFromDisplay(d);
            Console.WriteLine("  " + DisplayLabel(d));
            if (String.IsNullOrWhiteSpace(desiredProfile))
            {
                Console.WriteLine("    display DRS profile: unavailable; no EDID vendor/product was exposed");
                return;
            }

            IntPtr session = IntPtr.Zero;
            try
            {
                Check(drsCreateSession(out session), "NvAPI_DRS_CreateSession");
                Check(drsLoadSettings(session), "NvAPI_DRS_LoadSettings");

                IntPtr profile;
                string usedProfile;
                if (!TryFindDisplayDrsProfile(session, desiredProfile, out profile, out usedProfile))
                {
                    Console.WriteLine("    display DRS profile " + desiredProfile + ": not found");
                    return;
                }

                uint? overrideValue = GetDrsDword(session, profile, DRS_VRR_MODE);
                if (!overrideValue.HasValue)
                {
                    Console.WriteLine("    display DRS profile " + usedProfile + ": no explicit VRR_MODE override (inherits enabled/global behavior)");
                }
                else
                {
                    Console.WriteLine("    display DRS profile " + usedProfile + ": VRR_MODE override=" + DescribeVrrMode(overrideValue.Value) + " (" + overrideValue.Value + ")");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("    display DRS profile status: error: " + ex.Message);
            }
            finally
            {
                if (session != IntPtr.Zero) drsDestroySession(session);
            }
        }

        public void ApplySelectedDisplayProfileVrrOverride(DisplayInfo d, bool enabled, bool dryRun)
        {
            string desiredProfile = DisplayProfileNameFromDisplay(d);
            Console.WriteLine("  display DRS profile override for " + DisplayLabel(d) + ": " + (enabled ? "Enabled" : "Disabled"));

            if (String.IsNullOrWhiteSpace(desiredProfile))
            {
                Console.WriteLine("    skipped: no EDID vendor/product profile name was exposed for this display");
                return;
            }

            IntPtr session = IntPtr.Zero;
            try
            {
                Check(drsCreateSession(out session), "NvAPI_DRS_CreateSession");
                Check(drsLoadSettings(session), "NvAPI_DRS_LoadSettings");

                IntPtr profile;
                string usedProfile;
                if (!TryFindDisplayDrsProfile(session, desiredProfile, out profile, out usedProfile))
                {
                    Console.WriteLine("    skipped: display DRS profile " + desiredProfile + " was not found");
                    return;
                }

                uint? before = GetDrsDword(session, profile, DRS_VRR_MODE);
                Console.WriteLine("    profile: " + usedProfile);
                Console.WriteLine("    current VRR_MODE override: " + (before.HasValue ? DescribeVrrMode(before.Value) + " (" + before.Value + ")" : "not present"));

                if (dryRun)
                {
                    Console.WriteLine("    dry-run: no display-profile DRS changes applied");
                    return;
                }

                if (enabled)
                {
                    // NVIDIA Control Panel's checked state removed the explicit disabled display-profile override in the capture.
                    DeleteDrsSettingIfPresent(session, profile, DRS_VRR_MODE);
                }
                else
                {
                    // NVIDIA Control Panel's unchecked state added an explicit VRR_MODE=Disabled override to the display profile.
                    SetDrsDword(session, profile, DRS_VRR_MODE, VRR_DISABLED);
                    Console.WriteLine("    set display-profile VRR_MODE override to Disabled (0)");
                }

                Check(drsSaveSettings(session), "NvAPI_DRS_SaveSettings");

                uint? after = GetDrsDword(session, profile, DRS_VRR_MODE);
                Console.WriteLine("    after VRR_MODE override: " + (after.HasValue ? DescribeVrrMode(after.Value) + " (" + after.Value + ")" : "not present"));
            }
            finally
            {
                if (session != IntPtr.Zero) drsDestroySession(session);
            }
        }

        public GSyncDrsState GetGSyncDrsState()
        {
            IntPtr session;
            IntPtr profile = OpenDrsSessionAndGlobalProfile(out session);
            try
            {
                GSyncDrsState state = new GSyncDrsState();
                state.VrrMode = GetDrsDword(session, profile, DRS_VRR_MODE);
                state.VrrRequestState = GetDrsDword(session, profile, DRS_VRR_REQUEST_STATE);
                state.VrrFeatureIndicator = GetDrsDword(session, profile, DRS_VRR_FEATURE_INDICATOR);
                state.VsyncVrrControl = GetDrsDword(session, profile, DRS_VSYNC_VRR_CONTROL);
                state.VrrAppOverride = GetDrsDword(session, profile, DRS_VRR_APP_OVERRIDE);
                state.VrrAppOverrideRequestState = GetDrsDword(session, profile, DRS_VRR_APP_OVERRIDE_REQUEST_STATE);
                return state;
            }
            finally
            {
                if (session != IntPtr.Zero) drsDestroySession(session);
            }
        }

        public void ApplyGSyncDrs(uint mode, bool selectedDisplayVrrEnabled, bool dryRun)
        {
            IntPtr session;
            IntPtr profile = OpenDrsSessionAndGlobalProfile(out session);
            try
            {
                uint feature = mode == VRR_DISABLED ? 0u : 1u;
                uint displayControl = selectedDisplayVrrEnabled && mode != VRR_DISABLED ? VSYNC_VRR_ENABLE : VSYNC_VRR_DISABLE;

                Console.WriteLine("  requested global mode: " + DescribeVrrMode(mode));
                Console.WriteLine("  requested selected-display VRR control: " + (displayControl == VSYNC_VRR_ENABLE ? "Enabled" : "Disabled"));

                if (dryRun)
                {
                    Console.WriteLine("  dry-run: no NVIDIA DRS changes applied");
                    return;
                }

                SetDrsDword(session, profile, DRS_VRR_MODE, mode);
                SetDrsDword(session, profile, DRS_VRR_REQUEST_STATE, mode);
                SetDrsDword(session, profile, DRS_VRR_FEATURE_INDICATOR, feature);
                SetDrsDword(session, profile, DRS_VSYNC_VRR_CONTROL, displayControl);

                if (mode == VRR_DISABLED)
                {
                    SetDrsDword(session, profile, DRS_VRR_APP_OVERRIDE, 1u); // force off
                    SetDrsDword(session, profile, DRS_VRR_APP_OVERRIDE_REQUEST_STATE, 1u);
                }
                else
                {
                    SetDrsDword(session, profile, DRS_VRR_APP_OVERRIDE, VRR_APP_ALLOW);
                    SetDrsDword(session, profile, DRS_VRR_APP_OVERRIDE_REQUEST_STATE, VRR_APP_ALLOW);
                }

                Check(drsSaveSettings(session), "NvAPI_DRS_SaveSettings");
            }
            finally
            {
                if (session != IntPtr.Zero) drsDestroySession(session);
            }
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

                string[] details = WinDisplayConfigGSyncRegistry.GetDisplayDetailsForSourceName(info.Name);
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

    private const string NvidiaDisplayDatabaseRegistryPath = @"SYSTEM\CurrentControlSet\Services\nvlddmkm\State\DisplayDatabase";
    private const string MonitorDataRegistryValueName = "MonitorDataRegistryKey";

    private static string ExtractHardwareIdFromMonitorPath(string monitorDevicePath)
    {
        if (String.IsNullOrWhiteSpace(monitorDevicePath)) return "";
        string upper = monitorDevicePath.ToUpperInvariant();
        string[] parts = upper.Split('#');
        for (int i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].EndsWith("DISPLAY", StringComparison.OrdinalIgnoreCase))
            {
                string candidate = parts[i + 1].Trim();
                if (candidate.Length >= 7) return candidate;
            }
        }

        int pos = upper.IndexOf("DISPLAY\\", StringComparison.OrdinalIgnoreCase);
        if (pos >= 0)
        {
            string tail = upper.Substring(pos + 8);
            int slash = tail.IndexOf('\\');
            if (slash >= 0) tail = tail.Substring(0, slash);
            if (tail.Length >= 7) return tail;
        }

        return "";
    }

    private static string ExtractProductCodeFromEdidText(string edidText)
    {
        if (String.IsNullOrWhiteSpace(edidText)) return "";
        string upper = edidText.ToUpperInvariant();
        int pos = upper.IndexOf(":0X", StringComparison.OrdinalIgnoreCase);
        if (pos < 0 || pos + 5 > upper.Length) return "";
        string code = upper.Substring(pos + 3);
        if (code.Length > 4) code = code.Substring(0, 4);
        return code;
    }

    private static List<string> FindDisplayDatabaseKeys(DisplayInfo d)
    {
        List<string> matches = new List<string>();
        string hardwareId = ExtractHardwareIdFromMonitorPath(d.MonitorDevicePath);
        string productCode = ExtractProductCodeFromEdidText(d.EdidText);

        using (RegistryKey root = Registry.LocalMachine.OpenSubKey(NvidiaDisplayDatabaseRegistryPath, false))
        {
            if (root == null) return matches;

            foreach (string subName in root.GetSubKeyNames())
            {
                byte[] value = null;
                try
                {
                    using (RegistryKey sub = root.OpenSubKey(subName, false))
                    {
                        if (sub == null) continue;
                        value = sub.GetValue(MonitorDataRegistryValueName) as byte[];
                    }
                }
                catch
                {
                    continue;
                }

                if (value == null || value.Length < 20) continue;

                string upperSubName = subName.ToUpperInvariant();
                bool match = false;

                if (!String.IsNullOrWhiteSpace(hardwareId) && upperSubName.Contains(hardwareId.ToUpperInvariant()))
                {
                    match = true;
                }
                else if (!String.IsNullOrWhiteSpace(productCode) && upperSubName.Contains(productCode.ToUpperInvariant()))
                {
                    match = true;
                }
                else if (!String.IsNullOrWhiteSpace(d.FriendlyName))
                {
                    string[] tokens = d.FriendlyName.ToUpperInvariant().Split(new char[] { ' ', '-', '_' }, StringSplitOptions.RemoveEmptyEntries);
                    foreach (string token in tokens)
                    {
                        if (token.Length >= 4 && upperSubName.Contains(token))
                        {
                            match = true;
                            break;
                        }
                    }
                }

                if (match) matches.Add(subName);
            }
        }

        return matches;
    }

    private static string DescribeMonitorDataFlag(byte[] value)
    {
        if (value == null) return "missing";
        if (value.Length < 20) return "invalid length " + value.Length;
        uint flag = BitConverter.ToUInt32(value, 12);
        uint checksum = BitConverter.ToUInt32(value, 16);
        uint expected = 0;
        for (int i = 0; i < 16 && i < value.Length; i++) expected += value[i];
        string status = checksum == expected ? "checksum ok" : ("checksum mismatch, expected " + expected);
        if (flag == 0) return "Disabled (flag=0, checksum=" + checksum + ", " + status + ")";
        if (flag == 1) return "Enabled (flag=1, checksum=" + checksum + ", " + status + ")";
        return "Unknown flag=" + flag + " (checksum=" + checksum + ", " + status + ")";
    }

    private static void PrintSelectedDisplayCheckboxState(DisplayInfo d)
    {
        List<string> keys = FindDisplayDatabaseKeys(d);
        if (keys.Count == 0)
        {
            Console.WriteLine("  " + DisplayLabel(d));
            Console.WriteLine("    selected-display checkbox: not found in NVIDIA DisplayDatabase");
            Console.WriteLine("    monitor path: " + (String.IsNullOrWhiteSpace(d.MonitorDevicePath) ? "(none)" : d.MonitorDevicePath));
            return;
        }

        using (RegistryKey root = Registry.LocalMachine.OpenSubKey(NvidiaDisplayDatabaseRegistryPath, false))
        {
            Console.WriteLine("  " + DisplayLabel(d));
            foreach (string keyName in keys)
            {
                try
                {
                    using (RegistryKey sub = root.OpenSubKey(keyName, false))
                    {
                        byte[] value = sub.GetValue(MonitorDataRegistryValueName) as byte[];
                        Console.WriteLine("    " + keyName + ": " + DescribeMonitorDataFlag(value));
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine("    " + keyName + ": read failed: " + ex.Message);
                }
            }
        }
    }

    private static int GetDisplayDatabaseSuffixScore(string keyName)
    {
        if (String.IsNullOrWhiteSpace(keyName)) return Int32.MinValue;
        int underscore = keyName.LastIndexOf('_');
        if (underscore < 0 || underscore == keyName.Length - 1) return Int32.MinValue;
        string suffix = keyName.Substring(underscore + 1);
        int score;
        if (Int32.TryParse(suffix, System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out score))
        {
            return score;
        }
        return Int32.MinValue;
    }

    private static List<string> ChooseDisplayDatabaseKeys(List<string> keys, string explicitKey, bool allMatching)
    {
        if (allMatching)
        {
            Console.WriteLine("    using all matching DisplayDatabase keys because -AllMatchingDisplayDbKeys was specified");
            return keys;
        }

        keys.Sort(StringComparer.OrdinalIgnoreCase);

        if (!String.IsNullOrWhiteSpace(explicitKey))
        {
            string needle = explicitKey.Trim();
            List<string> matches = new List<string>();
            foreach (string k in keys)
            {
                if (String.Equals(k, needle, StringComparison.OrdinalIgnoreCase) ||
                    k.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    matches.Add(k);
                }
            }
            if (matches.Count > 0)
            {
                Console.WriteLine("    selected DisplayDatabase key by -DisplayDbKey: " + matches[0]);
                return new List<string> { matches[0] };
            }
            Console.WriteLine("    warning: -DisplayDbKey '" + explicitKey + "' did not match; falling back to automatic selection.");
        }

        if (keys.Count <= 1)
        {
            if (keys.Count == 1) Console.WriteLine("    selected DisplayDatabase key: " + keys[0]);
            return keys;
        }

        // The NVIDIA Control Panel capture changed only one active per-monitor key.
        // For the captured DELL G3223Q case, that was the highest hex suffix (_9E) rather than older/stale keys (_10, _95).
        // Generalize that: choose the matching key with the highest final hex suffix. If parsing fails, use the last sorted key.
        string best = keys[keys.Count - 1];
        int bestScore = GetDisplayDatabaseSuffixScore(best);
        foreach (string k in keys)
        {
            int score = GetDisplayDatabaseSuffixScore(k);
            if (score > bestScore)
            {
                best = k;
                bestScore = score;
            }
        }

        Console.WriteLine("    multiple matching NVIDIA DisplayDatabase keys found; auto-selected: " + best);
        Console.WriteLine("    override with -DisplayDbKey <substring> or use -AllMatchingDisplayDbKeys if needed");
        return new List<string> { best };
    }

    private static void SetSelectedDisplayCheckboxState(DisplayInfo d, bool enabled, bool dryRun, string explicitDisplayDbKey, bool allMatchingDisplayDbKeys)
    {
        List<string> keys = FindDisplayDatabaseKeys(d);
        Console.WriteLine("  selected-display checkbox for " + DisplayLabel(d) + ": " + (enabled ? "Enabled" : "Disabled"));

        if (keys.Count == 0)
        {
            Console.WriteLine("    skipped: could not find matching NVIDIA DisplayDatabase key with " + MonitorDataRegistryValueName);
            Console.WriteLine("    monitor path: " + (String.IsNullOrWhiteSpace(d.MonitorDevicePath) ? "(none)" : d.MonitorDevicePath));
            return;
        }

        keys = ChooseDisplayDatabaseKeys(keys, explicitDisplayDbKey, allMatchingDisplayDbKeys);

        if (dryRun)
        {
            foreach (string keyName in keys) Console.WriteLine("    dry-run: would update " + keyName);
            return;
        }

        using (RegistryKey root = Registry.LocalMachine.OpenSubKey(NvidiaDisplayDatabaseRegistryPath, true))
        {
            if (root == null)
            {
                Console.WriteLine("    failed: NVIDIA DisplayDatabase registry path not found");
                return;
            }

            foreach (string keyName in keys)
            {
                try
                {
                    using (RegistryKey sub = root.OpenSubKey(keyName, true))
                    {
                        if (sub == null)
                        {
                            Console.WriteLine("    " + keyName + ": failed to open writable key");
                            continue;
                        }

                        byte[] value = sub.GetValue(MonitorDataRegistryValueName) as byte[];
                        if (value == null || value.Length < 20)
                        {
                            Console.WriteLine("    " + keyName + ": missing/invalid " + MonitorDataRegistryValueName);
                            continue;
                        }

                        uint beforeFlag = BitConverter.ToUInt32(value, 12);
                        uint requestedFlag = enabled ? 1u : 0u;
                        if (beforeFlag == requestedFlag)
                        {
                            Console.WriteLine("    " + keyName + ": already " + (enabled ? "Enabled" : "Disabled") + " (flag=" + beforeFlag + "); no selected-display checkbox state transition requested");
                        }

                        value[12] = (byte)requestedFlag;
                        value[13] = 0;
                        value[14] = 0;
                        value[15] = 0;

                        uint checksum = 0;
                        for (int i = 0; i < 16; i++) checksum += value[i];
                        byte[] checksumBytes = BitConverter.GetBytes(checksum);
                        Buffer.BlockCopy(checksumBytes, 0, value, 16, 4);

                        sub.SetValue(MonitorDataRegistryValueName, value, RegistryValueKind.Binary);

                        uint afterFlag = BitConverter.ToUInt32(value, 12);
                        Console.WriteLine("    " + keyName + ": flag " + beforeFlag + " -> " + afterFlag + ", checksum=" + checksum);
                    }
                }
                catch (UnauthorizedAccessException)
                {
                    Console.WriteLine("    " + keyName + ": access denied; run PowerShell as Administrator");
                }
                catch (Exception ex)
                {
                    Console.WriteLine("    " + keyName + ": failed: " + ex.Message);
                }
            }
        }
    }

    private static void ResetDisplayCurrentMode(DisplayInfo d)
    {
        if (d == null || String.IsNullOrWhiteSpace(d.Name)) return;
        DEVMODE dm = NewDevMode();
        if (!EnumDisplaySettings(d.Name, ENUM_CURRENT_SETTINGS, ref dm))
        {
            Console.WriteLine("  display reset: could not query current mode for " + d.Name);
            return;
        }

        dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        int ret = ChangeDisplaySettingsEx(d.Name, ref dm, IntPtr.Zero, 0, IntPtr.Zero);
        Console.WriteLine("  display reset for " + d.Name + ": " + DispChangeText(ret) + " (" + ret + ")");
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


    private static string DescribeNullable(uint? value, Func<uint, string> describe)
    {
        if (!value.HasValue) return "not set";
        return describe(value.Value) + " (" + value.Value + ")";
    }

    private static string DescribeVrrMode(uint value)
    {
        if (value == VRR_DISABLED) return "Disabled / none";
        if (value == VRR_FULLSCREEN_ONLY) return "Fullscreen only";
        if (value == VRR_FULLSCREEN_AND_WINDOWED) return "Fullscreen and windowed/borderless";
        return "Unknown VRR mode";
    }

    private static string DescribeEnabled(uint value)
    {
        if (value == 0) return "Disabled";
        if (value == 1) return "Enabled";
        return "Unknown";
    }

    private static string DescribeAppOverride(uint value)
    {
        if (value == 0) return "Allow";
        if (value == 1) return "Force off";
        if (value == 2) return "Disallow";
        if (value == 3) return "ULMB";
        if (value == 4) return "Fixed refresh";
        return "Unknown";
    }

    private static void PrintGSyncState(GSyncDrsState s)
    {
        Console.WriteLine("Current NVIDIA G-SYNC / VRR DRS state:");
        Console.WriteLine("  VRR_MODE:                         " + DescribeNullable(s.VrrMode, DescribeVrrMode));
        Console.WriteLine("  VRRREQUESTSTATE:                  " + DescribeNullable(s.VrrRequestState, DescribeVrrMode));
        Console.WriteLine("  VRRFEATUREINDICATOR:              " + DescribeNullable(s.VrrFeatureIndicator, DescribeEnabled));
        Console.WriteLine("  VSYNCVRRCONTROL:                  " + DescribeNullable(s.VsyncVrrControl, DescribeEnabled));
        Console.WriteLine("  VRR_APP_OVERRIDE:                 " + DescribeNullable(s.VrrAppOverride, DescribeAppOverride));
        Console.WriteLine("  VRR_APP_OVERRIDE_REQUEST_STATE:   " + DescribeNullable(s.VrrAppOverrideRequestState, DescribeAppOverride));
    }

    private static uint? ParseGSyncMode(string mode)
    {
        if (String.IsNullOrWhiteSpace(mode)) return null;
        string m = mode.Trim().ToLowerInvariant();
        if (m == "disabled" || m == "none" || m == "off") return VRR_DISABLED;
        if (m == "fullscreen" || m == "fullscreenonly") return VRR_FULLSCREEN_ONLY;
        if (m == "fullscreenandwindowed" || m == "windowed" || m == "borderless") return VRR_FULLSCREEN_AND_WINDOWED;
        throw new InvalidOperationException("Unsupported G-SYNC mode: " + mode);
    }

    private static bool? ParseDisplayGSync(string value)
    {
        if (String.IsNullOrWhiteSpace(value)) return null;
        string v = value.Trim().ToLowerInvariant();
        if (v == "enable" || v == "enabled" || v == "on") return true;
        if (v == "disable" || v == "disabled" || v == "off") return false;
        if (v == "keep") return null;
        throw new InvalidOperationException("Unsupported selected-display G-SYNC value: " + value);
    }

    private static uint PromptForGSyncMode()
    {
        while (true)
        {
            Console.WriteLine();
            Console.WriteLine("Choose global NVIDIA G-SYNC mode:");
            Console.WriteLine("  1) Disabled / none");
            Console.WriteLine("  2) Fullscreen only");
            Console.WriteLine("  3) Fullscreen and windowed/borderless");
            Console.Write("Selection [1-3]: ");
            string answer = Console.ReadLine();
            if (answer == "1") return VRR_DISABLED;
            if (answer == "2") return VRR_FULLSCREEN_ONLY;
            if (answer == "3") return VRR_FULLSCREEN_AND_WINDOWED;
            Console.WriteLine("Invalid selection.");
        }
    }

    private static bool PromptForDisplayGSync()
    {
        while (true)
        {
            Console.WriteLine();
            Console.WriteLine("Enable G-SYNC / VRR control for the selected display?");
            Console.WriteLine("  1) Enabled");
            Console.WriteLine("  2) Disabled");
            Console.Write("Selection [1-2]: ");
            string answer = Console.ReadLine();
            if (answer == "1") return true;
            if (answer == "2") return false;
            Console.WriteLine("Invalid selection.");
        }
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

    public static void RunGSync(string displayFilter, bool allDisplays, string modeOption, string displayGSyncOption, bool resetDisplay, bool dryRun, string explicitDisplayDbKey, bool allMatchingDisplayDbKeys, bool restartNvidiaDriver)
    {
        using (NvApi nv = new NvApi())
        {
            nv.Initialize();
            List<DisplayInfo> selected = ResolveDisplays(nv, displayFilter, allDisplays);

            Console.WriteLine();
            Console.WriteLine("NVIDIA displays selected:");
            foreach (DisplayInfo d in selected) Console.WriteLine("  " + DisplayLabel(d));

            Console.WriteLine();
            PrintGSyncState(nv.GetGSyncDrsState());

            Console.WriteLine();
            Console.WriteLine("Current selected-display G-SYNC DRS display-profile override:");
            foreach (DisplayInfo d in selected) nv.PrintSelectedDisplayProfileVrrOverride(d);

            Console.WriteLine();
            Console.WriteLine("Current selected-display G-SYNC registry mirror state from NVIDIA DisplayDatabase:");
            foreach (DisplayInfo d in selected) PrintSelectedDisplayCheckboxState(d);

            uint? parsedMode = ParseGSyncMode(modeOption);
            uint targetMode = parsedMode.HasValue ? parsedMode.Value : PromptForGSyncMode();

            bool targetDisplayEnabled;
            if (targetMode == VRR_DISABLED)
            {
                targetDisplayEnabled = false;
                Console.WriteLine();
                Console.WriteLine("Global G-SYNC mode is disabled, so selected-display VRR control will also be disabled.");
            }
            else
            {
                bool? parsedDisplay = ParseDisplayGSync(displayGSyncOption);
                targetDisplayEnabled = parsedDisplay.HasValue ? parsedDisplay.Value : PromptForDisplayGSync();
            }

            Console.WriteLine();
            Console.WriteLine("Applying NVIDIA G-SYNC / VRR settings:");
            nv.ApplyGSyncDrs(targetMode, targetDisplayEnabled, dryRun);

            Console.WriteLine();
            Console.WriteLine("Applying selected-display DRS profile override captured from NVIDIA Control Panel:");
            foreach (DisplayInfo d in selected) nv.ApplySelectedDisplayProfileVrrOverride(d, targetDisplayEnabled, dryRun);

            Console.WriteLine();
            Console.WriteLine("Applying selected-display registry mirror flag captured from NVIDIA Control Panel:");
            foreach (DisplayInfo d in selected) SetSelectedDisplayCheckboxState(d, targetDisplayEnabled, dryRun, explicitDisplayDbKey, allMatchingDisplayDbKeys);

            if (!dryRun && restartNvidiaDriver)
            {
                Console.WriteLine();
                Console.WriteLine("Restarting the NVIDIA display driver so the live driver reloads the selected-display flag:");
                nv.RestartDisplayDriver();
            }
            else if (!dryRun && resetDisplay)
            {
                Console.WriteLine();
                Console.WriteLine("Triggering selected-display mode reset so the driver may reload the display flag:");
                Console.WriteLine("  note: if the requested flag was already in that state, this is normally a no-op and may not visibly reinitialize the display");
                Console.WriteLine("  use -RestartNvidiaDriver for a stronger NVIDIA-side reload test");
                foreach (DisplayInfo d in selected) ResetDisplayCurrentMode(d);
            }
            else if (!dryRun)
            {
                Console.WriteLine();
                Console.WriteLine("Display reset skipped because -NoDisplayReset was specified.");
            }

            Console.WriteLine();
            PrintGSyncState(nv.GetGSyncDrsState());

            Console.WriteLine();
            Console.WriteLine("Selected-display DRS display-profile override after applying:");
            foreach (DisplayInfo d in selected) nv.PrintSelectedDisplayProfileVrrOverride(d);

            Console.WriteLine();
            Console.WriteLine("Selected-display registry mirror state after applying:");
            foreach (DisplayInfo d in selected) PrintSelectedDisplayCheckboxState(d);

            Console.WriteLine();
            Console.WriteLine("Note: this version writes both the display-specific DRS profile override and the NVIDIA DisplayDatabase registry mirror. The DRS profile override is the setting that matched NVIDIA Control Panel's checkbox behavior in the capture.");
        }
    }
}

'@

try {
    if (-not ('WinDisplayConfigGSyncRegistry' -as [type]) -or -not ('NvApiGSyncControlRegistry' -as [type])) {
        Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
    }
}
catch {
    Write-Error "Failed to compile embedded C# interop code: $($_.Exception.Message)"
    try { Complete-DebugLog } catch {}
    exit 1
}

$script:RunFailed = $false
try {
    Export-DebugRegistrySnapshot -Name 'before'

    # v9 behavior:
    # The NVIDIA Control Panel checkbox causes a real driver/display reinit.
    # A same-mode Windows reset usually does not. Therefore, use NvAPI_RestartDisplayDriver
    # automatically by default unless explicitly disabled.
    $effectiveRestartNvidiaDriver = [bool]$RestartNvidiaDriver
    if (-not $NoDisplayReset -and -not $NoDriverRestart) {
        $effectiveRestartNvidiaDriver = $true
    }


    if ($effectiveRestartNvidiaDriver -and -not $RestartNvidiaDriver) {
        Write-Host 'Auto-reinit enabled: using NvAPI_RestartDisplayDriver after applying the selected-display flag.'
    }
    elseif ($NoDriverRestart) {
        Write-Host 'Auto-reinit disabled by -NoDriverRestart; using the weaker Windows display reset path if allowed.'
    }

    [NvApiGSyncControlRegistry]::RunGSync(
        [string]$Display,
        [bool]$AllDisplays,
        [string]$Mode,
        [string]$DisplayGSync,
        [bool](-not $NoDisplayReset),
        [bool]$DryRun,
        [string]$DisplayDbKey,
        [bool]$AllMatchingDisplayDbKeys,
        [bool]$effectiveRestartNvidiaDriver
    )

    Export-DebugRegistrySnapshot -Name 'after'
}
catch {
    $script:RunFailed = $true
    Write-Error $_.Exception.Message
    try { Export-DebugRegistrySnapshot -Name 'failure' } catch {}
}
finally {
    Complete-DebugLog
}

if ($script:RunFailed) {
    exit 1
}

Write-Host ''
Write-Host 'Done. Verify in NVIDIA Control Panel and Windows Settings > System > Display > Advanced display.'
if ($script:DebugRequested -and $script:DebugZipPath) {
    Write-Host "Debug log saved to: $script:DebugZipPath"
}
