<#
.SYNOPSIS
  File Explorer and Desktop registry tweaks.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Reset-DevConfigExplorerDisplay {
    param(
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
    $fileVisibilityMask = [uint32]3
    $cabinet = [DevConfigExplorerSettings+CabinetState]::new()
    $cabinet.Length = [Runtime.InteropServices.Marshal]::SizeOf([type][DevConfigExplorerSettings+CabinetState])
    # A false result supplies defaults when no cabinet settings have been saved.
    [void][DevConfigExplorerSettings]::ReadCabinetState([ref]$cabinet, $cabinet.Length)

    $shell = [DevConfigExplorerSettings+ShellState]::new()
    # The mask covers hidden files and file extensions, not other Explorer preferences.
    [DevConfigExplorerSettings]::SHGetSetSettings([ref]$shell, $fileVisibilityMask, $false)
    if ($CheckOnly) {
        return ($cabinet.Flags -band $fullPathTitleMask) -eq 0 -and
            ($shell.Flags1 -band $fileVisibilityMask) -eq 0
    }

    $cabinet.Flags = $cabinet.Flags -band (-bnot $fullPathTitleMask)
    if (-not [DevConfigExplorerSettings]::WriteCabinetState([ref]$cabinet)) {
        throw 'Could not reset the Explorer cabinet settings.'
    }
    $shell.Flags1 = $shell.Flags1 -band (-bnot $fileVisibilityMask)
    [DevConfigExplorerSettings]::SHGetSetSettings([ref]$shell, $fileVisibilityMask, $true)
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
            Description = 'Show file extensions in Explorer'
        }
        @{
            Name        = 'ShowHiddenFiles'
            KeyPath     = $advanced
            ValueName   = 'Hidden'
            Value       = 1
            Description = 'Show hidden files in Explorer'
        }
        @{
            Name        = 'FullPathTitlebar'
            KeyPath     = $cabinet
            ValueName   = 'FullPath'
            Value       = 1
            Description = 'Show full path in Explorer titlebar'
        }
        @{
            Name             = 'OpenThisPC'
            KeyPath          = $advanced
            ValueName        = 'LaunchTo'
            Value            = 1
            Description      = 'Open File Explorer to This PC'
            ResetOnUninstall = $true
        }
        @{
            Name             = 'FrequentFolders'
            KeyPath          = $explorer
            ValueName        = 'ShowFrequent'
            Value            = 0
            Description      = 'Disable frequent folders in Quick Access'
            ResetOnUninstall = $true
        }
        @{
            Name             = 'FrequentFiles'
            KeyPath          = $explorer
            ValueName        = 'ShowRecent'
            Value            = 0
            Description      = 'Disable frequent files in Quick Access'
            ResetOnUninstall = $true
        }
        @{
            Name        = 'RecommendedFiles'
            KeyPath     = $explorer
            ValueName   = 'ShowCloudFilesInQuickAccess'
            Value       = 0
            Description = 'Disable recommended/cloud files in Quick Access'
        }
        @{
            Name             = 'TipsOff'
            KeyPath          = $advanced
            ValueName        = 'ShowSyncProviderNotifications'
            Value            = 0
            Description      = 'Disable sync provider notifications (tips)'
            ResetOnUninstall = $true
        }
        @{
            Name             = 'DetailsContainer'
            KeyPath          = "$explorer\Modules\GlobalSettings\DetailsContainer"
            ValueName        = 'DetailsContainer'
            Value            = [byte[]](0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00)
            Type             = 'Binary'
            Description      = 'Configure Explorer Details pane state'
            ResetOnUninstall = $true
        }
    )

    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps = @($tweaks | Where-Object { $_['ResetOnUninstall'] } | ForEach-Object {
            New-DevConfigRegistryStep -Setting $_ -Reset
        })
        $steps += New-DevConfigStep -Name 'ExplorerDisplayReset' -Description 'Reset hidden files, file extensions, and full-path titles' -BestEffort `
            -Check { Reset-DevConfigExplorerDisplay -CheckOnly } `
            -Apply { Reset-DevConfigExplorerDisplay }
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -ne 'RecommendedFiles' })
    }

    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak
    }

    Invoke-DevConfigSteps -Steps $steps
}
