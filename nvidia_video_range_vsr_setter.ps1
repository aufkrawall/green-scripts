<#
.SYNOPSIS
  Sets NVIDIA video-player range and RTX Video Super Resolution values captured from local NVIDIA Control Panel changes.

.DESCRIPTION
  Confirmed mappings from captures:
    - Video player range: App controlled = 0x00000000
    - Video player range: PC / full range = 0x80000001
    - RTX Video Super Resolution: Off = 0x00000000
    - RTX Video Super Resolution: Auto = 0x00000005

  This version only writes the confirmed persistent registry values.
  It does not restart NVIDIA services, kill NVIDIA UI processes, or restart the display driver.

  NVIDIA Control Panel / NVIDIA App may continue to show stale values until Windows is rebooted,
  but after reboot the UI should mirror these registry-backed settings.

  These captured settings live under HKLM display-driver registry mirrors, so this script requires Administrator rights.
#>

[CmdletBinding()]
param(
    [ValidateSet('Interactive','AppControlled','PCFull')]
    [string]$VideoRange = 'Interactive',

    [ValidateSet('Interactive','Off','Auto')]
    [string]$RtxVsr = 'Interactive',

    [switch]$DryRun,

    [switch]$ListOnly,

    [switch]$NoDebugLog,

    [string]$DebugDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ThisScriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.PSCommandPath) { $MyInvocation.PSCommandPath } else { '<unknown>' }

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Error "This script requires Administrator / UAC elevation because the captured NVIDIA video settings are stored under HKLM display-driver registry keys. Start PowerShell as Administrator and run it again."
    exit 1
}

$script:DebugEnabled = -not $NoDebugLog
$script:DebugRoot = $null
$script:DebugLog = $null

function Initialize-DebugLog {
    if (-not $script:DebugEnabled) { return }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    if ([string]::IsNullOrWhiteSpace($DebugDirectory)) {
        $script:DebugRoot = Join-Path (Get-Location) "nvidia_video_range_vsr_debug_$stamp"
    } else {
        $script:DebugRoot = $DebugDirectory
    }

    New-Item -ItemType Directory -Force -Path $script:DebugRoot | Out-Null
    $script:DebugLog = Join-Path $script:DebugRoot 'debug.log'

    $metadata = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        script = $script:ThisScriptPath
        powershell = $PSVersionTable.PSVersion.ToString()
        edition = $PSVersionTable.PSEdition
        elevated = (Test-IsAdministrator)
        registry_access = 'Microsoft.Win32.RegistryKey, HKLM, Default registry view'
        parameters = [ordered]@{
            VideoRange = $VideoRange
            RtxVsr = $RtxVsr
            DryRun = [bool]$DryRun
            ListOnly = [bool]$ListOnly
            NoDebugLog = [bool]$NoDebugLog
        }
    }

    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:DebugRoot 'metadata.json') -Encoding UTF8
    "NVIDIA video range / RTX VSR persistent setter v16 debug log - $((Get-Date).ToString('o'))" | Set-Content -LiteralPath $script:DebugLog -Encoding UTF8
}

function Write-DebugLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
    if ($script:DebugEnabled -and $script:DebugLog) {
        Add-Content -LiteralPath $script:DebugLog -Value $line -Encoding UTF8
    }
}

function Compress-DebugFolder {
    if (-not $script:DebugEnabled) { return }
    try {
        if ([string]::IsNullOrWhiteSpace($script:DebugRoot) -or -not (Test-Path -LiteralPath $script:DebugRoot -PathType Container)) {
            Write-Warning "Could not create debug ZIP: debug directory does not exist: $script:DebugRoot"
            return
        }

        $zipPath = "$script:DebugRoot.zip"
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

        $items = Get-ChildItem -LiteralPath $script:DebugRoot -Force -ErrorAction SilentlyContinue
        if (-not $items -or $items.Count -eq 0) {
            Write-Warning "Could not create debug ZIP: debug directory is empty: $script:DebugRoot"
            return
        }

        Compress-Archive -Path (Join-Path $script:DebugRoot '*') -DestinationPath $zipPath -Force
        Write-Host ''
        Write-Host "Debug log written to: $script:DebugRoot"
        Write-Host "Debug ZIP written to: $zipPath"
    } catch {
        Write-Warning "Could not create debug ZIP: $($_.Exception.Message)"
    }
}

Initialize-DebugLog
Write-DebugLog 'Started.'

$script:ClassRootRel = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$script:ControlVideoRootRel = 'SYSTEM\CurrentControlSet\Control\Video'
$script:SearchRootRelPaths = @($script:ClassRootRel, $script:ControlVideoRootRel)

$script:XenSuffixes = @(
    'XEN_Brightness',
    'XEN_Color_Range',
    'XEN_Contrast',
    'XEN_Hue',
    'XEN_RGB_Gamma_B',
    'XEN_RGB_Gamma_G',
    'XEN_RGB_Gamma_R',
    'XEN_Saturation'
)

function Open-HklmBaseKey {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)
}

function Convert-ToUInt32Dword {
    param($Value)
    if ($null -eq $Value) { return $null }

    if ($Value -is [byte[]]) {
        if ($Value.Length -ge 4) { return [BitConverter]::ToUInt32($Value, 0) }
        return [uint32]0
    }

    if ($Value -is [int]) {
        return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Value), 0)
    }

    if ($Value -is [uint32]) {
        return [uint32]$Value
    }

    if ($Value -is [long]) {
        if ($Value -lt 0) {
            return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Value), 0)
        }
        return [uint32]$Value
    }

    try { return [uint32]$Value } catch { return $null }
}

function Convert-UInt32ToRegistryDwordObject {
    param([uint32]$Value)
    # RegistryKey.SetValue writes REG_DWORD from Int32 objects. This preserves the raw 32-bit pattern.
    return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Value), 0)
}

function Format-DwordHex {
    param($Value)
    if ($null -eq $Value) { return '<missing>' }
    $u = Convert-ToUInt32Dword $Value
    if ($null -eq $u) { return [string]$Value }
    return ('0x{0:X8}' -f ([uint32]$u))
}

function Get-SubkeyRelativePathsRecursive {
    param(
        [Microsoft.Win32.RegistryKey]$BaseKey,
        [string]$RootRelPath
    )

    $paths = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($RootRelPath)

    while ($stack.Count -gt 0) {
        $rel = $stack.Pop()
        $paths.Add($rel) | Out-Null

        $key = $null
        try {
            $key = $BaseKey.OpenSubKey($rel, $false)
            if ($null -eq $key) { continue }
            foreach ($childName in $key.GetSubKeyNames()) {
                if ([string]::IsNullOrWhiteSpace($childName)) { continue }
                $stack.Push(("{0}\{1}" -f $rel, $childName))
            }
        } catch {
            Write-DebugLog "Could not enumerate HKLM\$rel : $($_.Exception.Message)"
        } finally {
            if ($null -ne $key) { $key.Dispose() }
        }
    }

    return $paths.ToArray()
}

function Get-NvidiaVideoSettingEntries {
    $entries = New-Object System.Collections.Generic.List[object]
    $base = $null

    try {
        $base = Open-HklmBaseKey
        $allRelPaths = New-Object System.Collections.Generic.List[string]

        foreach ($rootRel in $script:SearchRootRelPaths) {
            $rootKey = $null
            try {
                $rootKey = $base.OpenSubKey($rootRel, $false)
                if ($null -eq $rootKey) {
                    Write-DebugLog "Registry root not found: HKLM\$rootRel"
                    continue
                }
            } finally {
                if ($null -ne $rootKey) { $rootKey.Dispose() }
            }

            foreach ($p in @(Get-SubkeyRelativePathsRecursive -BaseKey $base -RootRelPath $rootRel)) {
                $allRelPaths.Add($p) | Out-Null
            }
        }

        Write-DebugLog "Enumerating $($allRelPaths.Count) registry keys for NVIDIA video values."

        foreach ($relPath in $allRelPaths) {
            $key = $null
            try {
                $key = $base.OpenSubKey($relPath, $false)
                if ($null -eq $key) { continue }

                $valueNames = @($key.GetValueNames())
                if ($valueNames.Count -eq 0) { continue }

                foreach ($name in $valueNames) {
                    if ($name -like '_User_*_XEN_Color_Range') {
                        $prefix = $name.Substring(0, $name.Length - 'XEN_Color_Range'.Length)
                        foreach ($suffix in $script:XenSuffixes) {
                            $groupName = $prefix + $suffix
                            $exists = $valueNames -contains $groupName
                            $raw = $null
                            $u32 = $null
                            $kind = $null
                            if ($exists) {
                                $raw = $key.GetValue($groupName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                                $u32 = Convert-ToUInt32Dword $raw
                                try { $kind = $key.GetValueKind($groupName).ToString() } catch { $kind = '<unknown>' }
                            }

                            $entries.Add([pscustomobject]@{
                                Kind = 'VideoRangeXenGroup'
                                RegistryView = 'Default'
                                RelPath = $relPath
                                DisplayPath = "HKLM\$relPath"
                                Prefix = $prefix
                                Name = $groupName
                                Exists = [bool]$exists
                                RawValue = $raw
                                Value = $u32
                                Hex = (Format-DwordHex $u32)
                                RegistryValueKind = $kind
                            }) | Out-Null
                        }
                    }
                }

                if ($valueNames -contains '_User_Global_VAL_SuperResolution') {
                    $raw = $key.GetValue('_User_Global_VAL_SuperResolution', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $u32 = Convert-ToUInt32Dword $raw
                    $kind = $null
                    try { $kind = $key.GetValueKind('_User_Global_VAL_SuperResolution').ToString() } catch { $kind = '<unknown>' }

                    $entries.Add([pscustomobject]@{
                        Kind = 'RtxVsr'
                        RegistryView = 'Default'
                        RelPath = $relPath
                        DisplayPath = "HKLM\$relPath"
                        Prefix = ''
                        Name = '_User_Global_VAL_SuperResolution'
                        Exists = $true
                        RawValue = $raw
                        Value = $u32
                        Hex = (Format-DwordHex $u32)
                        RegistryValueKind = $kind
                    }) | Out-Null
                }
            } catch {
                Write-DebugLog "Could not inspect HKLM\$relPath : $($_.Exception.Message)"
            } finally {
                if ($null -ne $key) { $key.Dispose() }
            }
        }
    } finally {
        if ($null -ne $base) { $base.Dispose() }
    }

    $seen = @{}
    $deduped = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $id = "$($entry.DisplayPath)`n$($entry.Name)`n$($entry.Kind)"
        if (-not $seen.ContainsKey($id)) {
            $seen[$id] = $true
            $deduped.Add($entry) | Out-Null
        }
    }

    return $deduped.ToArray()
}

function Get-StateSummary {
    param([object[]]$Entries)

    $rangeEntries = @($Entries | Where-Object { $_.Kind -eq 'VideoRangeXenGroup' -and $_.Name -like '*XEN_Color_Range' -and $_.Exists })
    $vsrEntries = @($Entries | Where-Object { $_.Kind -eq 'RtxVsr' -and $_.Exists })

    $rangeValues = @($rangeEntries | Where-Object { $null -ne $_.Value } | ForEach-Object { Convert-ToUInt32Dword $_.Value } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
    $vsrValues = @($vsrEntries | Where-Object { $null -ne $_.Value } | ForEach-Object { Convert-ToUInt32Dword $_.Value } | Where-Object { $null -ne $_ } | Sort-Object -Unique)

    $rangeState = 'Not found'
    if ($rangeValues.Count -eq 1) {
        $rv = Convert-ToUInt32Dword $rangeValues[0]
        if ($rv -eq [uint32]0) { $rangeState = 'App controlled' }
        elseif ($rv -eq [uint32]2147483649) { $rangeState = 'PC / full range override' }
        else { $rangeState = 'Unknown: ' + (Format-DwordHex $rv) }
    } elseif ($rangeValues.Count -gt 1) {
        $rangeState = 'Mixed: ' + (($rangeValues | ForEach-Object { Format-DwordHex $_ }) -join ', ')
    }

    $vsrState = 'Not found'
    if ($vsrValues.Count -eq 1) {
        $vv = Convert-ToUInt32Dword $vsrValues[0]
        if ($vv -eq [uint32]0) { $vsrState = 'Off' }
        elseif ($vv -eq [uint32]5) { $vsrState = 'Auto' }
        else { $vsrState = 'Unknown: ' + (Format-DwordHex $vv) }
    } elseif ($vsrValues.Count -gt 1) {
        $vsrState = 'Mixed: ' + (($vsrValues | ForEach-Object { Format-DwordHex $_ }) -join ', ')
    }

    return [pscustomobject]@{
        VideoRangeState = $rangeState
        RtxVsrState = $vsrState
        VideoRangeEntryCount = $rangeEntries.Count
        RtxVsrEntryCount = $vsrEntries.Count
    }
}

function Save-EntriesJson {
    param(
        [string]$FileName,
        [object[]]$Entries
    )
    if (-not $script:DebugEnabled) { return }
    $path = Join-Path $script:DebugRoot $FileName
    $Entries | Select-Object Kind,RegistryView,DisplayPath,Prefix,Name,Exists,Value,Hex,RegistryValueKind | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Prompt-VideoRange {
    Write-Host ''
    Write-Host 'Choose NVIDIA video-player dynamic range override:'
    Write-Host '  1) Leave unchanged'
    Write-Host '  2) App controlled'
    Write-Host '  3) PC / full range override'
    while ($true) {
        $choice = Read-Host 'Selection [1-3]'
        switch ($choice.Trim()) {
            '1' { return 'Unchanged' }
            '2' { return 'AppControlled' }
            '3' { return 'PCFull' }
        }
        Write-Host 'Invalid selection.'
    }
}

function Prompt-RtxVsr {
    Write-Host ''
    Write-Host 'Choose NVIDIA RTX Video Super Resolution:'
    Write-Host '  1) Leave unchanged'
    Write-Host '  2) Off'
    Write-Host '  3) Auto'
    while ($true) {
        $choice = Read-Host 'Selection [1-3]'
        switch ($choice.Trim()) {
            '1' { return 'Unchanged' }
            '2' { return 'Off' }
            '3' { return 'Auto' }
        }
        Write-Host 'Invalid selection.'
    }
}

function Set-RegistryDwordValueDirect {
    param(
        [string]$RelPath,
        [string]$Name,
        [uint32]$Value
    )

    if ($DryRun) {
        Write-DebugLog "DRY RUN: would set HKLM\$RelPath :: $Name = $(Format-DwordHex $Value)"
        return
    }

    $base = $null
    $key = $null
    try {
        $base = Open-HklmBaseKey
        $key = $base.OpenSubKey($RelPath, $true)
        if ($null -eq $key) { throw "Could not open writable registry key HKLM\$RelPath" }
        $signed = Convert-UInt32ToRegistryDwordObject $Value
        $key.SetValue($Name, $signed, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Apply-VideoRange {
    param(
        [object[]]$Entries,
        [string]$State
    )

    if ($State -eq 'Unchanged' -or $State -eq 'Interactive') { return @() }

    $value = $null
    switch ($State) {
        'AppControlled' { $value = [uint32]0 }
        'PCFull' { $value = [uint32]2147483649 }
        default { throw "Unsupported VideoRange state: $State" }
    }

    $targets = @($Entries | Where-Object { $_.Kind -eq 'VideoRangeXenGroup' -and $_.Exists })
    if ($targets.Count -eq 0) {
        Write-Warning 'No NVIDIA video-player XEN range entries were found. Nothing to write for VideoRange.'
        Write-DebugLog 'No VideoRange targets found.'
        return @()
    }

    Write-Host ''
    Write-Host "Applying NVIDIA video-player range: $State ($(Format-DwordHex $value))"
    Write-DebugLog "Applying VideoRange=$State value=$(Format-DwordHex $value) to $($targets.Count) entries."

    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $targets) {
        $old = $entry.Value
        Write-Host ("  {0} :: {1}: {2} -> {3}" -f $entry.DisplayPath, $entry.Name, (Format-DwordHex $old), (Format-DwordHex $value))
        Write-DebugLog ("Set VideoRange {0} :: {1}: {2} -> {3}" -f $entry.DisplayPath, $entry.Name, (Format-DwordHex $old), (Format-DwordHex $value))
        Set-RegistryDwordValueDirect -RelPath $entry.RelPath -Name $entry.Name -Value $value
        $changes.Add([pscustomobject]@{
            Setting = 'VideoRange'
            Path = $entry.DisplayPath
            Name = $entry.Name
            Old = $old
            OldHex = (Format-DwordHex $old)
            New = $value
            NewHex = (Format-DwordHex $value)
        }) | Out-Null
    }
    return $changes.ToArray()
}

function Apply-RtxVsr {
    param(
        [object[]]$Entries,
        [string]$State
    )

    if ($State -eq 'Unchanged' -or $State -eq 'Interactive') { return @() }

    $value = $null
    switch ($State) {
        'Off' { $value = [uint32]0 }
        'Auto' { $value = [uint32]5 }
        default { throw "Unsupported RtxVsr state: $State" }
    }

    $targets = @($Entries | Where-Object { $_.Kind -eq 'RtxVsr' -and $_.Exists })
    if ($targets.Count -eq 0) {
        Write-Warning 'No NVIDIA RTX Video Super Resolution registry entries were found. Nothing to write for RtxVsr.'
        Write-DebugLog 'No RtxVsr targets found.'
        return @()
    }

    Write-Host ''
    Write-Host "Applying NVIDIA RTX Video Super Resolution: $State ($(Format-DwordHex $value))"
    Write-DebugLog "Applying RtxVsr=$State value=$(Format-DwordHex $value) to $($targets.Count) entries."

    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $targets) {
        $old = $entry.Value
        Write-Host ("  {0} :: {1}: {2} -> {3}" -f $entry.DisplayPath, $entry.Name, (Format-DwordHex $old), (Format-DwordHex $value))
        Write-DebugLog ("Set RtxVsr {0} :: {1}: {2} -> {3}" -f $entry.DisplayPath, $entry.Name, (Format-DwordHex $old), (Format-DwordHex $value))
        Set-RegistryDwordValueDirect -RelPath $entry.RelPath -Name $entry.Name -Value $value
        $changes.Add([pscustomobject]@{
            Setting = 'RtxVsr'
            Path = $entry.DisplayPath
            Name = $entry.Name
            Old = $old
            OldHex = (Format-DwordHex $old)
            New = $value
            NewHex = (Format-DwordHex $value)
        }) | Out-Null
    }
    return $changes.ToArray()
}

try {
    Write-Host 'NVIDIA video-player range / RTX Video Super Resolution persistent setter'
    Write-Host ''
    Write-Host 'Confirmed states supported in this version:'
    Write-Host '  Video range: App controlled, PC / full range override'
    Write-Host '  RTX Video Super Resolution: Off, Auto'
    Write-Host ''
    if ($DryRun) { Write-Host 'DRY RUN: no registry values will be changed.' }

    Write-DebugLog 'Discovering existing registry entries.'
    $beforeEntries = @(Get-NvidiaVideoSettingEntries)
    Write-DebugLog "Discovery returned $($beforeEntries.Count) entries."
    Save-EntriesJson -FileName 'before_entries.json' -Entries $beforeEntries

    $summary = Get-StateSummary -Entries $beforeEntries
    Write-Host 'Current detected NVIDIA video state:'
    Write-Host ("  Video-player range:             {0} ({1} range entries)" -f $summary.VideoRangeState, $summary.VideoRangeEntryCount)
    Write-Host ("  RTX Video Super Resolution:     {0} ({1} entries)" -f $summary.RtxVsrState, $summary.RtxVsrEntryCount)
    Write-DebugLog ("Detected state: VideoRange='{0}' entries={1}; RtxVsr='{2}' entries={3}" -f $summary.VideoRangeState, $summary.VideoRangeEntryCount, $summary.RtxVsrState, $summary.RtxVsrEntryCount)

    if ($ListOnly) {
        Write-Host ''
        Write-Host 'Detected entries:'
        foreach ($entry in $beforeEntries | Sort-Object DisplayPath,Name) {
            Write-Host ("  {0} :: {1} = {2} [{3}]" -f $entry.DisplayPath, $entry.Name, $entry.Hex, $entry.RegistryValueKind)
        }
        Compress-DebugFolder
        exit 0
    }

    $requestedRange = $VideoRange
    if ($VideoRange -eq 'Interactive') {
        $requestedRange = Prompt-VideoRange
    }

    $requestedVsr = $RtxVsr
    if ($RtxVsr -eq 'Interactive') {
        $requestedVsr = Prompt-RtxVsr
    }

    Write-DebugLog "Requested: VideoRange=$requestedRange; RtxVsr=$requestedVsr"

    $allChanges = New-Object System.Collections.Generic.List[object]
    foreach ($c in @(Apply-VideoRange -Entries $beforeEntries -State $requestedRange)) { $allChanges.Add($c) | Out-Null }
    foreach ($c in @(Apply-RtxVsr -Entries $beforeEntries -State $requestedVsr)) { $allChanges.Add($c) | Out-Null }

    if ($allChanges.Count -eq 0) {
        Write-Host ''
        Write-Host 'No changes were requested or no matching registry entries were found.'
        Write-DebugLog 'No changes applied.'
    } else {
        Write-DebugLog "Applied $($allChanges.Count) registry writes."
    }

    Start-Sleep -Milliseconds 250
    $afterEntries = @(Get-NvidiaVideoSettingEntries)
    Write-DebugLog "Post-write discovery returned $($afterEntries.Count) entries."
    Save-EntriesJson -FileName 'after_entries.json' -Entries $afterEntries

    if ($script:DebugEnabled) {
        $allChanges | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:DebugRoot 'applied_changes.json') -Encoding UTF8
    }

    $afterSummary = Get-StateSummary -Entries $afterEntries
    Write-Host ''
    Write-Host 'Detected NVIDIA video state after applying:'
    Write-Host ("  Video-player range:             {0} ({1} range entries)" -f $afterSummary.VideoRangeState, $afterSummary.VideoRangeEntryCount)
    Write-Host ("  RTX Video Super Resolution:     {0} ({1} entries)" -f $afterSummary.RtxVsrState, $afterSummary.RtxVsrEntryCount)

    Write-Host ''
    Write-Host 'Done.'
    Write-Host 'Note: NVIDIA Control Panel / NVIDIA App may not mirror these changed values until Windows is rebooted.'
    Write-Host 'This script intentionally does not restart NVIDIA services, NVIDIA UI components, or the display driver.'

    Compress-DebugFolder
} catch {
    Write-DebugLog "ERROR: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-DebugLog "STACK: $($_.ScriptStackTrace)"
    Write-Error $_
    Compress-DebugFolder
    exit 1
}
