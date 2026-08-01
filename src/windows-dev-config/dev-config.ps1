<#
.SYNOPSIS
  Calm OS developer workstation setup, in plain PowerShell.

.DESCRIPTION
  Configures apps, desktop/taskbar tweaks, the PowerShell profile, and WSL + Ubuntu.
  Safe to re-run: each phase skips work that's already done. The WSL phase runs
  last on purpose, so the one disruptive reboot it needs happens after everything
  else is configured; it resumes automatically after you log back in.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Resumed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 defaults to the ANSI code page; force UTF-8 so glyphs render correctly.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

$stepsDir = Join-Path $PSScriptRoot 'steps'
. (Join-Path $stepsDir '_console.ps1')
. (Join-Path $stepsDir '_step-runner.ps1')
. (Join-Path $stepsDir '_elevation.ps1')
. (Join-Path $stepsDir '_reboot-resume.ps1')
. (Join-Path $stepsDir '_registry.ps1')
. (Join-Path $stepsDir '_environment.ps1')
. (Join-Path $stepsDir '_retry.ps1')

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate

# Whether this is a fresh start or the post-reboot resume, any leftover task is done with.
Clear-DevConfigResume

$Script:DevConfigResumed = [bool]$Resumed
if ($Script:DevConfigResumed) {
    # Brings back the tally from before the reboot so the final summary covers the whole run.
    Restore-DevConfigTally -Path (Join-Path $PSScriptRoot 'devconfig-tally.json')
}
Write-Host ''
if ($Script:DevConfigResumed) {
    Write-Host 'Welcome back. Resuming Calm OS setup after the reboot...' -ForegroundColor Cyan
} else {
    Write-Host 'Calm OS setup -- 10 phases, one reboot along the way (expected, not an error)' -ForegroundColor Cyan
}

# WSL is last on purpose -- see the file header.
$phases = @(
    @{ File = 'packages.ps1';               Function = 'Invoke-PackagesPhase';               Title = 'Packages' }
    @{ File = 'registry-system.ps1';         Function = 'Invoke-RegistrySystemPhase';         Title = 'System settings' }
    @{ File = 'registry-explorer.ps1';       Function = 'Invoke-RegistryExplorerPhase';       Title = 'File Explorer tweaks' }
    @{ File = 'registry-taskbar-search.ps1'; Function = 'Invoke-RegistryTaskbarSearchPhase';  Title = 'Taskbar, search & start tweaks' }
    @{ File = 'edge.ps1';                    Function = 'Invoke-EdgePhase';                   Title = 'Microsoft Edge tweaks' }
    @{ File = 'fonts.ps1';                   Function = 'Invoke-FontsPhase';                  Title = 'Fonts' }
    @{ File = 'terminal.ps1';                Function = 'Invoke-TerminalPhase';               Title = 'Windows Terminal' }
    @{ File = 'powershell-profile.ps1';      Function = 'Invoke-PowerShellProfilePhase';      Title = 'PowerShell profile' }
    @{ File = 'copilot.ps1';                 Function = 'Invoke-CopilotPhase';                Title = 'GitHub Copilot' }
    @{ File = 'wsl.ps1';                     Function = 'Invoke-WslPhase';                    Title = 'WSL + Ubuntu' }
)

$phaseIndex = 0
foreach ($phase in $phases) {
    $phaseIndex++
    $path = Join-Path $stepsDir $phase.File
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "-- $($phase.File) not written yet, skipping" -ForegroundColor DarkGray
        continue
    }

    # Read by Invoke-DevConfigSteps to print this phase's header, without threading params through every phase file.
    $Script:DevConfigPhaseIndex       = $phaseIndex
    $Script:DevConfigPhaseTotal       = $phases.Count
    $Script:DevConfigPhaseTitle       = $phase.Title
    $Script:DevConfigPhaseHeaderShown = $false

    . $path
    if ($phase.File -eq 'wsl.ps1') {
        # The WSL phase needs the orchestrator's own path to register the reboot-resume task.
        Invoke-WslPhase -OrchestratorPath $PSCommandPath
    } else {
        & $phase.Function
    }

    if ($phase.File -eq 'packages.ps1') {
        # Packages installed above (pwsh, dotnet, git, ...) won't resolve on PATH until this refreshes.
        Update-DevConfigSessionPath
    }
}

Show-DevConfigSilentSkipSummary
Write-Host ''
Write-Host 'Calm OS setup complete.' -ForegroundColor Green
$tally = $Script:DevConfigTally
$summaryParts = @("$($tally.Done) changed", "$($tally.AlreadyOk) already up to date")
if ($tally.Warned -gt 0) {
    $summaryParts += "$($tally.Warned) flagged"
}
Write-Host "  $($summaryParts -join ', ')" -ForegroundColor DarkGray

if (-not $Script:DevConfigResumed) {
    # When resumed, the wrapper's own window owns the final pause instead (see _resume-wrapper.ps1).
    Wait-DevConfigKeyPress
}
