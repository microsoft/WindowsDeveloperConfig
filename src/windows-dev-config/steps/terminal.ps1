<#
.SYNOPSIS
  Dark theme and Windows Terminal profile defaults.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigDarkThemeSet {
    $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $apps    = Get-ItemPropertyValue $regPath -Name AppsUseLightTheme    -ErrorAction SilentlyContinue
    $system  = Get-ItemPropertyValue $regPath -Name SystemUsesLightTheme -ErrorAction SilentlyContinue
    return ($apps -eq 0 -and $system -eq 0)
}

function Set-DevConfigDarkTheme {
    $regPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Set-ItemProperty -Path $regPath -Name 'AppsUseLightTheme' -Value 0
    Set-ItemProperty -Path $regPath -Name 'SystemUsesLightTheme' -Value 0
}

function Test-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        # Terminal writes settings.json on its first launch. Installed-but-never-opened still has work
        # to do -- answering "already OK" here is what made this step silently do nothing on a fresh machine.
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

    # Terminal only lists its PowerShell 7 profile once it has run since PowerShell 7 was installed.
    # Until then the documented name form still resolves, and keeps working after Terminal fills the list in.
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
    $steps = @(
        New-DevConfigStep -Name 'DarkTheme' -Description 'Force dark app/system theme' `
            -Check { Test-DevConfigDarkThemeSet } `
            -Apply { Set-DevConfigDarkTheme }
        New-DevConfigStep -Name 'Ps7DefaultProfile' -Description 'Set PowerShell 7 as the default Windows Terminal profile' `
            -Check { Test-DevConfigPs7DefaultProfile } `
            -Apply { Set-DevConfigPs7DefaultProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}
