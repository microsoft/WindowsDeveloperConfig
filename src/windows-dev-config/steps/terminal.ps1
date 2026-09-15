<#
.SYNOPSIS
  Dark theme and Windows Terminal profile defaults.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigThemeKey = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'

function Test-DevConfigDarkThemeSet {
    return (Test-DevConfigRegistryValue -KeyPath $Script:DevConfigThemeKey -ValueName 'AppsUseLightTheme'    -Value 0) -and
           (Test-DevConfigRegistryValue -KeyPath $Script:DevConfigThemeKey -ValueName 'SystemUsesLightTheme' -Value 0)
}

function Set-DevConfigDarkTheme {
    Set-DevConfigRegistryValue -KeyPath $Script:DevConfigThemeKey -ValueName 'AppsUseLightTheme'    -Value 0
    Set-DevConfigRegistryValue -KeyPath $Script:DevConfigThemeKey -ValueName 'SystemUsesLightTheme' -Value 0
}

function Test-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        # Missing settings still need configuration when Terminal is installed but has not launched.
        return (-not (Get-DevConfigTerminalSettingsTarget))
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $current  = Get-DevConfigJsonValue -Object $settings -Path 'defaultProfile'
    if (-not $current) {
        return $false
    }
    if ($current -eq $Script:DevConfigPs7ProfileName) {
        return $true
    }

    $ps7 = Find-DevConfigPs7Profile -Settings $settings
    return [bool]($ps7 -and $current -eq (Get-DevConfigJsonValue -Object $ps7 -Path 'guid'))
}

function Set-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsTarget
    if (-not $path) {
        throw 'Windows Terminal is not installed, so its default profile cannot be set.'
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $ps7      = Find-DevConfigPs7Profile -Settings $settings

    # The documented profile name works before Terminal has listed the PowerShell 7 profile.
    $profileRef = if ($ps7) {
        Get-DevConfigJsonValue -Object $ps7 -Path 'guid'
    } else {
        $Script:DevConfigPs7ProfileName
    }

    Set-DevConfigJsonProperty -Object $settings -Name 'defaultProfile' -Value $profileRef
    Save-DevConfigTerminalSettings -Path $path -Settings $settings
    Write-Host "Set the Windows Terminal default profile to '$profileRef'."
}

function Invoke-TerminalPhase {
    # These user preferences are best-effort so later setup phases can continue.
    $steps = @(
        New-DevConfigStep -Name 'DarkTheme' -Description 'Force dark app/system theme' -BestEffort `
            -Check { Test-DevConfigDarkThemeSet } `
            -Apply { Set-DevConfigDarkTheme }
        New-DevConfigStep -Name 'Ps7DefaultProfile' -Description 'Set PowerShell 7 as the default Windows Terminal profile' -BestEffort `
            -Check { Test-DevConfigPs7DefaultProfile } `
            -Apply { Set-DevConfigPs7DefaultProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}
