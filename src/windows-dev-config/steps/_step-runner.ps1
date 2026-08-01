<#
.SYNOPSIS
  Runs a named list of steps; each step checks first, and only applies itself if needed.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# [char] avoids embedding a literal multi-byte glyph in the source file, which Windows PowerShell
# 5.1 can misread without a BOM.
$Script:DevConfigCheckMark = [char]0x2713

# dev-config.ps1 sets these; defaults here cover the fresh-run case.
$Script:DevConfigResumed     = $false
$Script:DevConfigTally       = @{ Done = 0; AlreadyOk = 0; Warned = 0 }
# Names of steps ever flagged, so a permanently-blocked step doesn't count twice across the reboot.
$Script:DevConfigWarnedSteps      = @()
$Script:DevConfigSilentSkips      = 0
$Script:DevConfigPhaseIndex       = 0
$Script:DevConfigPhaseTotal       = 0
$Script:DevConfigPhaseTitle       = ''
$Script:DevConfigPhaseHeaderShown = $false

function Write-DevConfigPhaseHeader {
    param(
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [string] $Title
    )
    Write-Host ''
    Write-Host "Phase $Index/$Total -- $Title" -ForegroundColor Cyan
}

# Guarded so a phase that does work before its step list even starts (e.g. Packages' WinGet bootstrap)
# can show the header up front without Invoke-DevConfigSteps printing it a second time afterwards.
function Show-DevConfigPhaseHeader {
    if ($Script:DevConfigPhaseHeaderShown -or -not $Script:DevConfigPhaseTitle) {
        return
    }
    Write-DevConfigPhaseHeader -Index $Script:DevConfigPhaseIndex -Total $Script:DevConfigPhaseTotal -Title $Script:DevConfigPhaseTitle
    $Script:DevConfigPhaseHeaderShown = $true
}

# Hands the tally across the reboot so the final summary covers the whole run, not just the resumed leg.
function Save-DevConfigTally {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    try {
        $state = [pscustomobject]@{
            Done        = $Script:DevConfigTally.Done
            AlreadyOk   = $Script:DevConfigTally.AlreadyOk
            WarnedSteps = ($Script:DevConfigWarnedSteps -join ',')
        }
        $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Write-Verbose "Could not save the tally before reboot: $($_.Exception.Message)"
    }
}

# Best-effort: a missing or unreadable file just means the summary covers only this leg.
function Restore-DevConfigTally {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $Script:DevConfigTally.Done      += [int]$saved.Done
        $Script:DevConfigTally.AlreadyOk += [int]$saved.AlreadyOk
        if ($saved.WarnedSteps) {
            foreach ($name in ($saved.WarnedSteps -split ',')) {
                if ($Script:DevConfigWarnedSteps -notcontains $name) {
                    $Script:DevConfigWarnedSteps += $name
                }
            }
        }
        $Script:DevConfigTally.Warned = $Script:DevConfigWarnedSteps.Count
    } catch {
        Write-Verbose "Could not restore the pre-reboot tally: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    }
}

# Flushes the running count of steps collapsed during resume, right before anything else prints.
function Show-DevConfigSilentSkipSummary {
    if ($Script:DevConfigSilentSkips -gt 0) {
        Write-Host ''
        Write-Host "Re-checked $($Script:DevConfigSilentSkips) earlier steps -- all already OK." -ForegroundColor DarkGray
        $Script:DevConfigSilentSkips = 0
    }
}

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

    # Check first (cheap by design) so a fully-idle resumed phase can collapse before printing anything.
    $checked = foreach ($step in $Steps) {
        $alreadyDone = $false
        try {
            # Splat (@) needs a plain variable, not a property-access expression.
            $stepArgs = $step.ArgumentList
            $alreadyDone = [bool](& $step.Check @stepArgs)
        } catch {
            Write-Warning "$($step.Name): Check threw ($($_.Exception.Message)); applying anyway."
        }
        # Tallied here (not in the print loop below) so a collapsed/silent-skipped phase still counts correctly.
        if ($alreadyDone) {
            $Script:DevConfigTally.AlreadyOk++
        }
        [pscustomobject]@{ Step = $step; AlreadyDone = $alreadyDone }
    }

    # After a reboot, collapse a fully no-op phase into a running count instead of repeating every step.
    $allAlreadyOk = -not ($checked | Where-Object { -not $_.AlreadyDone })
    if ($Script:DevConfigResumed -and $allAlreadyOk) {
        $Script:DevConfigSilentSkips += $checked.Count
        return
    }

    Show-DevConfigSilentSkipSummary
    Show-DevConfigPhaseHeader

    foreach ($item in $checked) {
        $step     = $item.Step
        $stepArgs = $step.ArgumentList
        $label    = $step.Name.PadRight(22)

        if ($item.AlreadyDone) {
            Write-Host "  $Script:DevConfigCheckMark $label already OK" -ForegroundColor DarkGray
            continue
        }

        # Printed live, right before the (possibly slow) Apply runs, so the console never sits silent unexplained.
        $what = if ($step.Description) { $step.Description } else { $step.Name }
        Write-Host "  -> $what..." -ForegroundColor DarkCyan

        # BestEffort steps warn and move on instead of blocking the whole run (e.g. OS-blocked registry values).
        try {
            & $step.Apply @stepArgs
            if (-not [bool](& $step.Check @stepArgs)) {
                throw "ran, but the follow-up check still says it isn't done."
            }
            $Script:DevConfigTally.Done++
            Write-Host "  $Script:DevConfigCheckMark $label done" -ForegroundColor Green
        } catch {
            if ($step.BestEffort) {
                # Dedup by name: a permanently-blocked step would otherwise flag again every leg, forever.
                if ($Script:DevConfigWarnedSteps -notcontains $step.Name) {
                    $Script:DevConfigWarnedSteps += $step.Name
                }
                $Script:DevConfigTally.Warned = $Script:DevConfigWarnedSteps.Count
                Write-Warning "$($step.Name): $($_.Exception.Message) (best-effort step, continuing)"
                Write-Host "  ! $label flagged (see warning above)" -ForegroundColor Yellow
            } else {
                throw
            }
        }
    }
}
