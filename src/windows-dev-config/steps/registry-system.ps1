<#
.SYNOPSIS
  System-level developer settings: Sudo, Developer Mode, long path support, Remote Desktop.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistrySystemPhase {
    $tweaks = @(
        @{
            Name        = 'Sudo'
            KeyPath     = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'
            ValueName   = 'Enabled'
            Value       = 3
            Description = 'Enable Sudo in inline mode'
        }
        @{
            Name        = 'DeveloperMode'
            KeyPath     = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
            ValueName   = 'AllowDevelopmentWithoutDevLicense'
            Value       = 1
            Description = 'Enable Developer Mode (sideload + dev features)'
        }
        @{
            Name             = 'LongPaths'
            KeyPath          = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'
            ValueName        = 'LongPathsEnabled'
            Value            = 1
            Description      = 'Enable Win32 long path support'
            ResetOnUninstall = $true
        }
        @{
            Name        = 'RemoteDesktop'
            KeyPath     = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'
            ValueName   = 'fDenyTSConnections'
            Value       = 0
            Description = 'Enable Remote Desktop (firewall rule still needs separate enable)'
        }
    )

    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps = @($tweaks | Where-Object { $_['ResetOnUninstall'] } | ForEach-Object {
            New-DevConfigRegistryStep -Setting $_ -Reset
        })
        if ($steps.Count -gt 0) {
            Invoke-DevConfigSteps -Steps $steps
        }
        return
    }

    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -eq 'LongPaths' })
    }

    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak
    }

    Invoke-DevConfigSteps -Steps $steps
}
