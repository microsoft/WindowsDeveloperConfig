<#
.SYNOPSIS
  Shared helpers for locating, reading, and safely writing Windows Terminal settings.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Terminal settings are deeply nested, so ConvertTo-Json needs a depth that preserves custom files.
$Script:DevConfigTerminalJsonDepth = 32

# The settings schema accepts a profile name for defaultProfile when a GUID is not available.
$Script:DevConfigPs7ProfileName = 'PowerShell'
$Script:CopilotFragmentGuid = '{b1a4d2c8-6f3e-4a7b-9e2d-1c8f5a3b7d91}'

# Paths backed up in this operation; null means resume could not recover the backup state.
$Script:DevConfigTerminalBackedUp = @()

function Get-DevConfigCopilotFragmentDir {
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\DevConfig'
}

# Stable Terminal is preferred over Preview because it is the profile users launch by default.
function Get-DevConfigTerminalPackagedSettingsPath {
    $packagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
    foreach ($pattern in 'Microsoft.WindowsTerminal_*', 'Microsoft.WindowsTerminalPreview_*') {
        $dir = Get-ChildItem -Path $packagesDir -Filter $pattern -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($dir) {
            return Join-Path $dir.FullName 'LocalState\settings.json'
        }
    }
    return $null
}

function Get-DevConfigTerminalUnpackagedSettingsPath {
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
}

function Get-DevConfigTerminalSettingsPath {
    $candidates = @(
        Get-DevConfigTerminalPackagedSettingsPath
        Get-DevConfigTerminalUnpackagedSettingsPath
    )
    return $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# A null target means Terminal is not installed, so configuration can be skipped.
function Get-DevConfigTerminalSettingsTarget {
    $existing = Get-DevConfigTerminalSettingsPath
    if ($existing) {
        return $existing
    }
    return Get-DevConfigTerminalPackagedSettingsPath
}

# An empty object lets first-run Terminal settings merge with Terminal defaults.
function Read-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{}
    }

    # A zero-byte settings file is treated like an unwritten first-run file.
    $raw = Read-DevConfigTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }

    # Invalid JSON stops the run so a hand-edited settings file is not overwritten.
    try {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            # Windows PowerShell needs JSONC comments and trailing commas removed without changing strings.
            $raw = [regex]::Replace($raw, '("(?:\\.|[^"\\])*")|//[^\r\n]*|/\*[\s\S]*?\*/', {
                param($match)
                if ($match.Groups[1].Success) { $match.Value } else { ' ' }
            })
            # A trailing comma must follow a value, not an opening delimiter or another comma.
            $raw = [regex]::Replace($raw, '("(?:\\.|[^"\\])*")|(?<=[}\]"0-9el])\s*,\s*(?=[}\]])', '$1')
        }
        $settings = $raw | ConvertFrom-Json
        if ($null -eq $settings) {
            return [pscustomobject]@{}
        }
        return $settings
    } catch {
        throw "Windows Terminal's settings file couldn't be read as JSON, so it was left untouched. Fix or rename $Path and run this again."
    }
}

# Backup preserves the original JSONC because JSON conversion drops comments.
function Save-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Settings
    )
    if ($null -eq $Script:DevConfigTerminalBackedUp) {
        throw 'The Terminal backup state could not be restored; settings were left unchanged to preserve the original backup.'
    }
    if ((Test-Path -LiteralPath $Path) -and ($Script:DevConfigTerminalBackedUp -notcontains $Path)) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
        $Script:DevConfigTerminalBackedUp += $Path
    }
    $json = $Settings | ConvertTo-Json -Depth $Script:DevConfigTerminalJsonDepth
    Write-DevConfigTextFile -Path $Path -Content $json
}

function Resolve-DevConfigJsonBranch {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string[]] $Path
    )
    $node = $Object
    foreach ($name in $Path) {
        if (-not $node.PSObject.Properties[$name]) {
            $node | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{})
        }
        $node = $node.PSObject.Properties[$name].Value
    }
    return $node
}

# Add-Member cannot update existing properties, so creation and assignment are handled separately.
function Set-DevConfigJsonProperty {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Value
    )
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

# Strict mode requires defensive reads when any nested setting may be absent.
function Get-DevConfigJsonValue {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string[]] $Path
    )
    $node = $Object
    foreach ($name in $Path) {
        if ($null -eq $node) {
            return $null
        }
        $property = $node.PSObject.Properties[$name]
        if (-not $property) {
            return $null
        }
        $node = $property.Value
    }
    return $node
}

# Built-in profiles may omit source, so profile fields are read defensively.
function Find-DevConfigPs7Profile {
    param(
        [Parameter(Mandatory)] [object] $Settings
    )
    $list = Get-DevConfigJsonValue -Object $Settings -Path 'profiles', 'list'
    if (-not $list) {
        return $null
    }
    return $list | Where-Object {
        (Get-DevConfigJsonValue -Object $_ -Path 'source') -eq 'Windows.Terminal.PowershellCore' -or
        (Get-DevConfigJsonValue -Object $_ -Path 'name')   -eq $Script:DevConfigPs7ProfileName
    } | Select-Object -First 1
}

function Reset-DevConfigTerminal {
    param(
        [Parameter(Mandatory)] [string] $DistributionName,
        [switch] $CheckOnly
    )
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        return $true
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $changed = $false
    if ($settings.PSObject.Properties['defaultProfile']) {
        $settings.PSObject.Properties.Remove('defaultProfile')
        $changed = $true
    }

    $profiles = Get-DevConfigJsonValue -Object $settings -Path 'profiles'
    if ($null -ne $profiles -and $profiles.PSObject.Properties['defaults']) {
        $profiles.PSObject.Properties.Remove('defaults')
        $changed = $true
    }

    $list = Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'list'
    if ($null -ne $list) {
        $profileGuids = @(
            '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
            '{463c642a-294e-5f7d-87c0-3061fde7adfd}'
            $Script:CopilotFragmentGuid
            '{2c4de342-38b7-51cf-b940-2309a097f518}'
            '{08c3a759-e9c2-5cd9-a652-37191c8995ca}'
        )
        $remaining = @($list | Where-Object {
            $guid = Get-DevConfigJsonValue -Object $_ -Path 'guid'
            $name = Get-DevConfigJsonValue -Object $_ -Path 'name'
            $source = Get-DevConfigJsonValue -Object $_ -Path 'source'
            $guid -notin $profileGuids -and $name -ne $DistributionName -and
                $source -ne 'Windows.Terminal.PowershellCore'
        })
        if ($remaining.Count -ne @($list).Count) {
            $profiles.PSObject.Properties['list'].Value = $remaining
            $changed = $true
        }
    }

    if ($CheckOnly) {
        return -not $changed
    }
    if ($changed) {
        Save-DevConfigTerminalSettings -Path $path -Settings $settings
    }
}
