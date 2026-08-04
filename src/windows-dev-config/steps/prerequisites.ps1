<#
.SYNOPSIS
  Brings the two things everything else leans on -- PowerShell 7 and WinGet -- to a known state
  before any real work starts.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The switch to PowerShell 7 happens before this phase, before the log is even open, because it
# replaces the running process. Arriving here on Windows PowerShell therefore means that bootstrap
# could not install it. Try once more, then say plainly which shell this run is using: the WinGet
# module is documented as unreliable on Windows PowerShell, so it is worth being clear about.
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
    # Only ahead of the checks, and only on a fresh run: it puts the WinGet module setup message
    # under a header, but on the resumed leg an unconditional header would print with nothing under
    # it and break the collapsed "re-checked N earlier steps" summary.
    if (-not $Script:DevConfigResumed) {
        Show-DevConfigPhaseHeader
    }
    Initialize-DevConfigWinGet

    # BestEffort on both: neither is worth abandoning the run over, and each explains what it could
    # not do. The package steps behind them check for what they need anyway.
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
