<#
.SYNOPSIS
  Shared Windows Terminal settings helpers: locating settings.json, reading it as JSONC,
  writing it back safely, and the small JSON object helpers those need.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Terminal's settings nest several levels deep (profiles.list[].font.face, actions, schemes).
# Too small a depth makes ConvertTo-Json silently truncate a customized file into a string.
$Script:DevConfigTerminalJsonDepth = 32

# Terminal's name for the PowerShell 7 profile. Usable in place of a GUID: the settings schema
# documents defaultProfile as accepting "GUID or profile name as a string".
$Script:DevConfigPs7ProfileName = 'PowerShell'

# Where a packaged (MSIX) Terminal keeps its settings, whether or not the file exists yet.
# Stable before Preview, so a machine with both configures the one it actually launches.
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

# The settings file as it exists right now, or $null when Terminal has never written one.
function Get-DevConfigTerminalSettingsPath {
    $candidates = @(
        Get-DevConfigTerminalPackagedSettingsPath
        Get-DevConfigTerminalUnpackagedSettingsPath
    )
    return $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# Where the settings file belongs, whether or not it has been written yet.
# $null means Terminal isn't installed, so there is genuinely nothing to configure.
function Get-DevConfigTerminalSettingsTarget {
    $existing = Get-DevConfigTerminalSettingsPath
    if ($existing) {
        return $existing
    }
    return Get-DevConfigTerminalPackagedSettingsPath
}

# Terminal only writes settings.json on its first launch, so on a freshly installed machine the file
# is missing. An empty object lets callers treat "not written yet" like any other starting point:
# Terminal fills in everything we leave out from its own defaults.
function Read-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{}
    }

    # Get-Content -Raw hands back $null (not an empty string) for a zero-byte file, and a write
    # interrupted partway through leaves exactly that.
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }

    # settings.json is JSONC; strip block and line comments before parsing.
    $clean = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
    $clean = [regex]::Replace($clean, '(?m)^\s*//.*$', '')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return [pscustomobject]@{}
    }
    return $clean | ConvertFrom-Json
}

# Keeps a .bak alongside the file: the JSONC round-trip above drops any comments the user had written.
function Save-DevConfigTerminalSettings {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Settings
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
    }
    $Settings | ConvertTo-Json -Depth $Script:DevConfigTerminalJsonDepth |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

# Walks an object path such as profiles -> defaults -> font, creating any level that's missing,
# and hands back the leaf so a caller can set values on it.
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

# Add-Member only creates; assignment only updates. This does whichever applies.
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

# Reads a nested value without throwing under strict mode when any level along the way is absent.
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

# Terminal's PowerShell 7 entry. Built-in profiles such as "Windows PowerShell" have no 'source'
# property at all, so every level is read defensively rather than dotted into.
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
