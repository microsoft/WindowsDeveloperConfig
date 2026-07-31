<#
.SYNOPSIS
  Runs a named list of steps; each step checks first, and only applies itself if needed.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function New-DevConfigStep {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Check,
        [Parameter(Mandatory)] [scriptblock] $Apply,
        [string] $Description = '',
        [object[]] $ArgumentList = @(),
        [switch] $BestEffort
    )
    # ArgumentList is passed positionally to Check/Apply at call time, not captured by closure.
    [pscustomobject]@{
        Name         = $Name
        Description  = $Description
        Check        = $Check
        Apply        = $Apply
        ArgumentList = $ArgumentList
        BestEffort   = [bool]$BestEffort
    }
}

function Invoke-DevConfigSteps {
    param(
        [Parameter(Mandatory)] [object[]] $Steps
    )
    foreach ($step in $Steps) {
        Write-Host "==> $($step.Name)" -ForegroundColor Cyan
        if ($step.Description) {
            Write-Host "    $($step.Description)" -ForegroundColor DarkGray
        }

        # Splat (@) needs a plain variable, not a property-access expression.
        $stepArgs = $step.ArgumentList

        $alreadyDone = $false
        try {
            $alreadyDone = [bool](& $step.Check @stepArgs)
        } catch {
            Write-Warning "$($step.Name): Check threw ($($_.Exception.Message)); applying anyway."
        }

        if ($alreadyDone) {
            Write-Host '    already OK' -ForegroundColor DarkGray
            continue
        }

        # BestEffort steps warn and move on instead of blocking the whole run (e.g. OS-blocked registry values).
        try {
            & $step.Apply @stepArgs
            if (-not [bool](& $step.Check @stepArgs)) {
                throw "ran, but the follow-up check still says it isn't done."
            }
            Write-Host '    done' -ForegroundColor Green
        } catch {
            if ($step.BestEffort) {
                Write-Warning "$($step.Name): $($_.Exception.Message) (best-effort step, continuing)"
            } else {
                throw
            }
        }
    }
}
