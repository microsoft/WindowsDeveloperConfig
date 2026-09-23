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
            ResetValue  = 0
            Description = 'Enable Sudo in inline mode'
        }
        @{
            Name        = 'DeveloperMode'
            KeyPath     = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
            ValueName   = 'AllowDevelopmentWithoutDevLicense'
            Value       = 1
            ResetValue  = 0
            Description = 'Enable Developer Mode (sideload + dev features)'
        }
        @{
            Name        = 'LongPaths'
            KeyPath     = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'
            ValueName   = 'LongPathsEnabled'
            Value       = 1
            Description = 'Enable Win32 long path support'
        }
        @{
            Name        = 'RemoteDesktop'
            KeyPath     = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'
            ValueName   = 'fDenyTSConnections'
            Value       = 0
            ResetValue  = 1
            Description = 'Enable Remote Desktop (firewall rule still needs separate enable)'
        }
    )

    if ($Script:DevConfigAction -eq 'Partial') {
        $tweaks = @($tweaks | Where-Object { $_.Name -eq 'LongPaths' })
    }

    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigRegistryStep -Setting $tweak -Reset:($Script:DevConfigAction -eq 'Uninstall')
    }

    Invoke-DevConfigSteps -Steps $steps
}
