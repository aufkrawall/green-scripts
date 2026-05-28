# Green Scripts

Small PowerShell utilities for changing selected NVIDIA display and video settings from the command line.

These scripts are intended for users who want repeatable, scriptable control over NVIDIA settings that are otherwise spread across NVIDIA Control Panel, NVIDIA App, Windows display settings, or undocumented driver registry values.

This project is unofficial and is not affiliated with, sponsored by, or endorsed by NVIDIA.

## Features

The repository contains separate scripts for separate tasks:

| Script                                                     | Purpose                                                                                                              |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `nvidia_bpc_no_acm.ps1`                                    | Change NVIDIA output color depth, for example 8/10/12 bpc, while avoiding Windows Advanced Color / ACM side effects. |
| `nvidia_dither_control.ps1`                                | Control NVIDIA dithering state, mode, and target dither depth.                                                       |
| `nvidia_output_format_resolution_select.ps1`               | Select display resolution, output format, chroma subsampling, and output range.                                      |
| `nvidia_gsync_control_display_select_profile_override.ps1` | Configure global G-SYNC / G-SYNC Compatible mode and selected-display G-SYNC Compatible state.                       |
| `nvidia_video_range_vsr_setter.ps1`                        | Persist NVIDIA video-player range override and RTX Video Super Resolution settings.                                  |

The scripts are intentionally split by topic so they can be used independently.

## Requirements

* Windows 10 or Windows 11
* NVIDIA GPU and NVIDIA display driver
* PowerShell 5.1 or newer
* 64-bit PowerShell recommended
* Administrator rights for scripts that write system-level display-driver settings

Some scripts use embedded C# interop through PowerShell `Add-Type`. This does not require Visual Studio or the .NET SDK on a normal Windows installation.

## Usage

Open PowerShell in the folder containing the scripts.

Example:

```powershell
.\nvidia_bpc_no_acm.ps1
```

Most scripts can be used interactively. They will show detected displays or current settings and then ask what to change.

Some scripts also support non-interactive parameters. Example:

```powershell
.\nvidia_video_range_vsr_setter.ps1 -VideoRange PCFull -RtxVsr Auto
```

## Debug logging

Debug logging is off by default.

Enable it with:

```powershell
--debug
```

Example:

```powershell
.\nvidia_video_range_vsr_setter.ps1 --debug
```

When enabled, scripts may write a timestamped debug folder or ZIP archive next to the script. These logs are intended for troubleshooting only.

## Administrator rights

Some settings are stored under system registry paths or require NVIDIA driver-level access. Those scripts require Administrator rights and will refuse to run without elevation.

Scripts that only use user-level or NVAPI settings may not require elevation.

When in doubt, run from an Administrator PowerShell window.

## Notes on NVIDIA Control Panel / NVIDIA App

Some settings are persisted immediately but NVIDIA Control Panel or NVIDIA App may not visually mirror the new value until Windows is rebooted or NVIDIA’s own UI/runtime reloads the setting.

This is known for the video-player range / RTX Video Super Resolution script. The script writes the persistent driver values, but the NVIDIA UI may continue to show the previous value until after a reboot.

The scripts intentionally avoid unnecessary heavy-handed refresh actions such as restarting the display driver unless a specific script clearly states otherwise.

## Scope and limitations

These tools use a mix of:

* Windows display APIs
* NVIDIA NVAPI entry points available on the installed driver
* NVIDIA driver registry values observed from NVIDIA Control Panel / NVIDIA App behavior

Some NVIDIA settings are undocumented and may change between driver versions. A script that works on one driver version may need adjustment on another.

The scripts are designed to report what they are doing and avoid silent changes where possible.

## Safety notes

Before using these scripts:

* Read the script you intend to run.
* Keep a copy of your current settings.
* Prefer the interactive mode for first use.
* Use `--debug` if you want troubleshooting logs.
* Reboot if NVIDIA Control Panel / NVIDIA App does not immediately reflect a persistent change.

These scripts do not include or redistribute NVIDIA binaries, Microsoft Sysinternals tools, or third-party executables.

## ProcMon helper

If included, any ProcMon helper script downloads Process Monitor directly from Microsoft Sysinternals instead of bundling the executable in this repository.

Process Monitor is a Microsoft Sysinternals tool. Check Microsoft’s license terms before redistributing Sysinternals binaries.

## License

MIT License

Copyright (c) 2026 aufkrawall

See [`LICENSE`](LICENSE) for the full license text.

## Disclaimer

This is an unofficial utility collection for advanced users. It is provided as-is, without warranty. Use it at your own discretion.
