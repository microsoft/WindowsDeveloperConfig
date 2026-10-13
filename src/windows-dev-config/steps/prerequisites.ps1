<#
.SYNOPSIS
  Prepares PowerShell 7 and WinGet before later phases run.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PowerShell 7 bootstrap replaces the process before logging; retry here if Windows PowerShell remains.
function Confirm-DevConfigPwshInUse {
    if ((Get-DevConfigScope) -eq 'Machine') {
        # As SYSTEM, WinGet works only through its module in PowerShell 7, so fail this try; the retry starts in PowerShell 7.
        if (-not (Test-DevConfigHasPwsh)) {
            $null = Install-DevConfigPwshMsi
        }
        throw 'The machine part needs PowerShell 7 to install packages as SYSTEM. This try stops so the next one starts in PowerShell 7.'
    }
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
    $runScope = Get-DevConfigScope
    # BestEffort allows later package checks to run even if one prerequisite remains unverified.
    # The machine part's WinGet module needs PowerShell 7, so there a missing PowerShell 7 fails the run.
    $steps = @(
        New-DevConfigStep -Name 'PowerShell7' -Scope Machine -Description 'Install PowerShell 7' -BestEffort:($runScope -ne 'Machine') `
            -Check { $PSVersionTable.PSEdition -eq 'Core' } `
            -Apply { Confirm-DevConfigPwshInUse }
        # Add-AppxPackage can't update App Installer as SYSTEM or without elevation, so only full runs include this.
        New-DevConfigStep -Name 'WinGet' -Scope All -Description 'Update WinGet to the pinned release' -BestEffort `
            -Check { Test-DevConfigWinGetTargetVersion } `
            -Apply { Update-DevConfigWinget }
    )
    if ($runScope -ne 'All' -and -not @($steps | Where-Object { $_.Scope -eq $runScope })) { return }

    # Show the header before WinGet setup; skip it when a resumed run summarizes this phase.
    if (-not $Script:DevConfigResumed) {
        Show-DevConfigPhaseHeader
    }
    Initialize-DevConfigWinGet

    Invoke-DevConfigSteps -Steps $steps
}
