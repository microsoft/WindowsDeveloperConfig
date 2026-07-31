<#
.SYNOPSIS
  System-level developer settings: Sudo, Developer Mode, long path support, Remote Desktop.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-RegistrySystemPhase {
    $tweaks = @(
        @{ Name = 'Sudo';          KeyPath = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo';           ValueName = 'Enabled';                        Value = 3; Description = 'Enable Sudo in inline mode' }
        @{ Name = 'DeveloperMode'; KeyPath = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'; ValueName = 'AllowDevelopmentWithoutDevLicense'; Value = 1; Description = 'Enable Developer Mode (sideload + dev features)' }
        @{ Name = 'LongPaths';     KeyPath = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem';              ValueName = 'LongPathsEnabled';               Value = 1; Description = 'Enable Win32 long path support' }
        @{ Name = 'RemoteDesktop'; KeyPath = 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server';         ValueName = 'fDenyTSConnections';             Value = 0; Description = 'Enable Remote Desktop (firewall rule still needs separate enable)' }
    )

    # ArgumentList binds each tweak's values at call time instead of relying on closure capture.
    $steps = foreach ($tweak in $tweaks) {
        New-DevConfigStep -Name $tweak.Name -Description $tweak.Description `
            -Check { param($KeyPath, $ValueName, $Value) Test-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -Apply { param($KeyPath, $ValueName, $Value) Set-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value } `
            -ArgumentList @($tweak.KeyPath, $tweak.ValueName, $tweak.Value)
    }

    Invoke-DevConfigSteps -Steps $steps
}
