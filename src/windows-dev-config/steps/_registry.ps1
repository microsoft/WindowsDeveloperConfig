<#
.SYNOPSIS
  Shared registry read/write helpers used by every registry-based phase.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-DevConfigRegistryPath {
    param(
        [Parameter(Mandatory)] [string] $KeyPath
    )
    # Source data uses paths with no drive colon (HKCU\...); the registry PS provider needs one (HKCU:\...).
    return $KeyPath -replace '^(HKCU|HKLM|HKCR|HKU|HKCC)\\', '$1:\'
}

function Test-DevConfigRegistryValue {
    param(
        [Parameter(Mandatory)] [string] $KeyPath,
        [Parameter(Mandatory)] [string] $ValueName,
        [Parameter(Mandatory)] $Value
    )
    $psPath  = Convert-DevConfigRegistryPath -KeyPath $KeyPath
    $current = Get-ItemProperty -Path $psPath -Name $ValueName -ErrorAction SilentlyContinue
    if (-not $current) {
        return $false
    }
    $prop = $current.PSObject.Properties[$ValueName]
    return ($prop) -and ($prop.Value -eq $Value)
}

function Set-DevConfigRegistryValue {
    param(
        [Parameter(Mandatory)] [string] $KeyPath,
        [Parameter(Mandatory)] [string] $ValueName,
        [Parameter(Mandatory)] $Value,
        [string] $Type = 'DWord'
    )
    $psPath = Convert-DevConfigRegistryPath -KeyPath $KeyPath
    if (-not (Test-Path -LiteralPath $psPath)) {
        New-Item -Path $psPath -Force | Out-Null
    }
    New-ItemProperty -Path $psPath -Name $ValueName -Value $Value -PropertyType $Type -Force | Out-Null
}
