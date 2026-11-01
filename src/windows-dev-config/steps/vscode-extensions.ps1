<#
.SYNOPSIS
  Installs or verifies requested VS Code extensions.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DevConfigInstalledVSCodeExtensions {
    $code = Get-Command code -ErrorAction Stop | Select-Object -First 1
    $result = Invoke-DevConfigNativeCommand -FilePath $code.Source -Arguments @('--list-extensions')
    if ($result.ExitCode -ne 0) {
        Write-Host $result.Output
        throw "VS Code could not list installed extensions (exit code $($result.ExitCode))."
    }
    @($result.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-DevConfigVSCodeExtensions {
    param(
        [Parameter(Mandatory)] [string[]] $Extensions
    )
    $installed = @(Get-DevConfigInstalledVSCodeExtensions)
    foreach ($extension in $Extensions) {
        if ($extension -notin $installed) {
            return $false
        }
    }
    return $true
}

function Set-DevConfigVSCodeExtensions {
    param(
        [Parameter(Mandatory)] [string[]] $Extensions
    )
    $installed = @(Get-DevConfigInstalledVSCodeExtensions)
    $code = Get-Command code -ErrorAction Stop | Select-Object -First 1
    foreach ($extension in $Extensions) {
        if ($extension -in $installed) {
            continue
        }
        $result = Invoke-DevConfigNativeCommand -FilePath $code.Source `
            -Arguments @('--install-extension', $extension)
        if ($result.ExitCode -ne 0) {
            Write-Host $result.Output
            throw "VS Code failed to install extension '$extension' (exit code $($result.ExitCode))."
        }
    }
    if (-not (Test-DevConfigVSCodeExtensions -Extensions $Extensions)) {
        throw 'VS Code reported successful extension installation, but one or more requested extensions are missing.'
    }
}

function Invoke-VSCodeExtensionsPhase {
    param(
        [Parameter(Mandatory)] [string[]] $Extensions
    )
    Show-DevConfigPhaseHeader

    $steps = @(
        New-DevConfigStep -Name 'VSCodeExtensions' -Description 'Install or verify requested VS Code extensions.' `
            -Check { Test-DevConfigVSCodeExtensions -Extensions $Extensions } `
            -Apply { Set-DevConfigVSCodeExtensions -Extensions $Extensions }
    )
    Invoke-DevConfigSteps -Steps $steps
}
