<#
.SYNOPSIS
  File Explorer and Desktop registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Reset-DevConfigExplorerDisplay {
    param(
        # The registry-explorer settings to reset; the others are neither read nor written.
        [string[]] $Settings = @('ShowFileExtensions', 'ShowHiddenFiles', 'FullPathTitlebar'),
        [switch] $CheckOnly
    )
    if (-not ('DevConfigExplorerSettings' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DevConfigExplorerSettings
{
    [StructLayout(LayoutKind.Sequential)]
    public struct CabinetState
    {
        public ushort Length;
        public ushort Version;
        public uint Flags;
        public uint MenuEnumFilter;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ShellState
    {
        public uint Flags1;
        public uint Win95Unused;
        public uint Win95Unused2;
        public int SortParameter;
        public int SortDirection;
        public uint Version;
        public uint NotUsed;
        public uint Flags2;
    }

    [DllImport("shell32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadCabinetState(ref CabinetState state, int length);

    [DllImport("shell32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WriteCabinetState(ref CabinetState state);

    [DllImport("shell32.dll", ExactSpelling = true)]
    public static extern void SHGetSetSettings(
        ref ShellState state, uint mask, [MarshalAs(UnmanagedType.Bool)] bool set);
}
'@
    }

    $fullPathTitleMask = [uint32]1
    # SSF_SHOWALLOBJECTS and SSF_SHOWEXTENSIONS match the first two SHELLSTATE Flags1 bits.
    $fileVisibilityMask = [uint32]0
    if ($Settings -contains 'ShowHiddenFiles') { $fileVisibilityMask = $fileVisibilityMask -bor 1 }
    if ($Settings -contains 'ShowFileExtensions') { $fileVisibilityMask = $fileVisibilityMask -bor 2 }
    $resetFullPath = $Settings -contains 'FullPathTitlebar'

    $cabinet = [DevConfigExplorerSettings+CabinetState]::new()
    if ($resetFullPath) {
        $cabinet.Length = [Runtime.InteropServices.Marshal]::SizeOf([type][DevConfigExplorerSettings+CabinetState])
        # A false result supplies defaults when no cabinet settings have been saved.
        [void][DevConfigExplorerSettings]::ReadCabinetState([ref]$cabinet, $cabinet.Length)
    }

    $shell = [DevConfigExplorerSettings+ShellState]::new()
    if ($fileVisibilityMask -ne 0) {
        # The mask limits the call to the selected file-visibility preferences.
        [DevConfigExplorerSettings]::SHGetSetSettings([ref]$shell, $fileVisibilityMask, $false)
    }
    if ($CheckOnly) {
        return ($cabinet.Flags -band $fullPathTitleMask) -eq 0 -and
            ($shell.Flags1 -band $fileVisibilityMask) -eq 0
    }

    if ($resetFullPath) {
        $cabinet.Flags = $cabinet.Flags -band (-bnot $fullPathTitleMask)
        if (-not [DevConfigExplorerSettings]::WriteCabinetState([ref]$cabinet)) {
            throw 'Could not reset the Explorer cabinet settings.'
        }
    }
    if ($fileVisibilityMask -ne 0) {
        $shell.Flags1 = $shell.Flags1 -band (-bnot $fileVisibilityMask)
        [DevConfigExplorerSettings]::SHGetSetSettings([ref]$shell, $fileVisibilityMask, $true)
    }
}

function Invoke-RegistryExplorerPhase {
    $advanced = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $explorer = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    $cabinet = "$explorer\CabinetState"

    $tweaks = @(
        @{
            Name        = 'ShowFileExtensions'
            KeyPath     = $advanced
            ValueName   = 'HideFileExt'
            Value       = 0
            ResetValue  = 1
            Description = 'Show file extensions in Explorer'
        }
        @{
            Name        = 'ShowHiddenFiles'
            KeyPath     = $advanced
            ValueName   = 'Hidden'
            Value       = 1
            ResetValue  = 2
            Description = 'Show hidden files in Explorer'
        }
        @{
            Name        = 'FullPathTitlebar'
            KeyPath     = $cabinet
            ValueName   = 'FullPath'
            Value       = 1
            ResetValue  = 0
            Description = 'Show full path in Explorer titlebar'
        }
        @{
            Name        = 'OpenThisPC'
            KeyPath     = $advanced
            ValueName   = 'LaunchTo'
            Value       = 1
            Description = 'Open File Explorer to This PC'
        }
        @{
            Name        = 'FrequentFolders'
            KeyPath     = $explorer
            ValueName   = 'ShowFrequent'
            Value       = 0
            Description = 'Disable frequent folders in Quick Access'
        }
        @{
            Name        = 'FrequentFiles'
            KeyPath     = $explorer
            ValueName   = 'ShowRecent'
            Value       = 0
            Description = 'Disable frequent files in Quick Access'
        }
        @{
            Name        = 'RecommendedFiles'
            KeyPath     = $explorer
            ValueName   = 'ShowCloudFilesInQuickAccess'
            Value       = 0
            Description = 'Disable recommended/cloud files in Quick Access'
        }
        @{
            Name        = 'TipsOff'
            KeyPath     = $advanced
            ValueName   = 'ShowSyncProviderNotifications'
            Value       = 0
            Description = 'Disable sync provider notifications (tips)'
        }
        @{
            Name        = 'DetailsContainer'
            KeyPath     = "$explorer\Modules\GlobalSettings\DetailsContainer"
            ValueName   = 'DetailsContainer'
            Value       = [byte[]](0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00)
            Type        = 'Binary'
            Description = 'Configure Explorer Details pane state'
        }
    )

    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -ne 'RecommendedFiles' })
    }

    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak -Reset:($Script:DevConfigAction -eq 'Uninstall')
    }
    if ($Script:DevConfigAction -eq 'Uninstall') {
        # ExplorerDisplayReset leaves a skipped display setting as it is; with all three skipped it is skipped too.
        $displayNames = @('ShowFileExtensions', 'ShowHiddenFiles', 'FullPathTitlebar')
        $displayIds = @($displayNames | ForEach-Object { Get-DevConfigSkipId -Name $_ })
        $displaySettings = @($displayNames | Where-Object { -not (Test-DevConfigSkipped -Id (Get-DevConfigSkipId -Name $_)) })
        $displaySkipIds = if ($displaySettings.Count -gt 0) {
            @(Get-DevConfigSkipId -Name 'ExplorerDisplayReset')
        } else {
            @(Get-DevConfigSkipId -Name 'ExplorerDisplayReset') + $displayIds
        }
        $steps += New-DevConfigStep -Name 'ExplorerDisplayReset' -Description 'Reset hidden files, file extensions, and full-path titles' -BestEffort `
            -SkipIds $displaySkipIds -SettingIds $displayIds `
            -Check { param($Settings) Reset-DevConfigExplorerDisplay -Settings $Settings -CheckOnly } `
            -Apply { param($Settings) Reset-DevConfigExplorerDisplay -Settings $Settings } `
            -ArgumentList @(, $displaySettings)
    }

    Invoke-DevConfigSteps -Steps $steps
}
