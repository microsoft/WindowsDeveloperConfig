<#
.SYNOPSIS
  Prepares PowerShell 7 and WinGet before later phases run.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PowerShell 7 bootstrap replaces the process before logging; retry here if Windows PowerShell remains.
function Confirm-DevConfigPwshInUse {
    if (-not (Test-DevConfigHasPwsh)) {
        Install-DevConfigPwshBootstrap
    }

    if (Test-DevConfigHasPwsh) {
        Set-DevConfigStepUnverified -Reason 'PowerShell 7 is installed now, but this run had already started without it. Run this again and it will use PowerShell 7.'
        return
    }

    Set-DevConfigStepUnverified -Reason 'PowerShell 7 could not be installed, so this run is using Windows PowerShell. Everything below still runs; PowerShell 7 is simply the more reliable host for it.'
}

function Invoke-PrerequisitesPhase {
    # Show the header before WinGet setup; skip it when a resumed run summarizes this phase.
    if (-not $Script:DevConfigResumed) {
        Show-DevConfigPhaseHeader
    }
    Initialize-DevConfigWinGet

    # BestEffort allows later package checks to run even if one prerequisite remains unverified.
    $steps = @(
        New-DevConfigStep -Name 'PowerShell7' -Description 'Install PowerShell 7' -BestEffort `
            -Check { $PSVersionTable.PSEdition -eq 'Core' } `
            -Apply { Confirm-DevConfigPwshInUse }
        New-DevConfigStep -Name 'WinGet' -Description 'Update WinGet to a version this script can drive' -BestEffort `
            -Check { Test-DevConfigWinGetReady } `
            -Apply { Repair-DevConfigWinget }
    )

    Invoke-DevConfigSteps -Steps $steps
}
