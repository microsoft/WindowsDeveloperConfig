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

function Get-DevConfigTerminalSettingsPath {
    # Packaged (MSIX) Terminal first, then the unpackaged/portable location.
    $candidates = @(
        Get-ChildItem "$env:LOCALAPPDATA\Packages" -Filter 'Microsoft.WindowsTerminal*' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    return $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Get-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    # Terminal's settings.json is JSONC; strip block and line comments before parsing.
    $raw   = Get-Content -LiteralPath $Path -Raw
    $clean = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
    $clean = [regex]::Replace($clean, '(?m)^\s*//.*$', '')
    return $clean | ConvertFrom-Json
}

function Find-DevConfigPs7Profile {
    param(
        [Parameter(Mandatory)] [object] $Settings
    )
    # Some built-in profiles (e.g. "Windows PowerShell") have no 'source' property at all;
    # index into PSObject.Properties instead of dotting into it so strict mode doesn't throw.
    return $Settings.profiles.list | Where-Object {
        $sourceProp = $_.PSObject.Properties['source']
        (($sourceProp) -and ($sourceProp.Value -eq 'Windows.Terminal.PowershellCore')) -or ($_.name -eq 'PowerShell')
    } | Select-Object -First 1
}

function Test-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        return $true
    }
    $settings = Get-DevConfigTerminalSettings -Path $path
    $ps7 = Find-DevConfigPs7Profile -Settings $settings
    if (-not $ps7) {
        return $true
    }
    return ($settings.defaultProfile -eq $ps7.guid)
}

function Set-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        return
    }
    $settings = Get-DevConfigTerminalSettings -Path $path
    $ps7 = Find-DevConfigPs7Profile -Settings $settings
    if ($ps7 -and $settings.defaultProfile -ne $ps7.guid) {
        $settings.defaultProfile = $ps7.guid
        $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    }
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
