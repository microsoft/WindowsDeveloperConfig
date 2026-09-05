<#
.SYNOPSIS
  Configures a Windows developer workstation and resumes after the WSL reboot.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Resumed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 defaults to ANSI; force UTF-8 for console symbols.
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
. (Join-Path $stepsDir '_terminal.ps1')
. (Join-Path $stepsDir '_winget.ps1')
. (Join-Path $stepsDir '_pwsh-bootstrap.ps1')

# TLS is configured before any download step runs.
Enable-DevConfigModernTls

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate -Resumed:$Resumed

# WinGet module behavior is more consistent in PowerShell 7 than in Windows PowerShell 5.1.
Invoke-DevConfigEnsurePwsh -ScriptPath $PSCommandPath -Resumed:$Resumed

# The lock starts after relaunches so the worker process owns the log file.
if (-not (Enter-DevConfigSingleInstance)) {
    Write-Host ''
    Write-Host 'Calm OS setup is already running in another window.' -ForegroundColor Yellow
    Write-Host 'Switch to it rather than starting a second copy -- they would fight over the same installs.' -ForegroundColor DarkGray
    Wait-DevConfigKeyPress
    exit 1
}

Start-DevConfigLog -Path (Join-Path $PSScriptRoot 'devconfig-log.txt') -Append:$Resumed

# Any prior resume task is stale once this run starts.
Clear-DevConfigResume

$Script:DevConfigResumed = [bool]$Resumed
if ($Script:DevConfigResumed) {
    # Restore the pre-reboot tally so the final summary covers the whole run.
    Restore-DevConfigTally -Path (Join-Path $PSScriptRoot 'devconfig-tally.json')
}
Write-Host ''
if ($Script:DevConfigResumed) {
    Write-Host 'Welcome back. Resuming Calm OS setup after the reboot...' -ForegroundColor Cyan
} else {
    Write-Host 'Calm OS setup -- 11 phases, one reboot along the way (expected, not an error)' -ForegroundColor Cyan
}

# WSL stays last so its required reboot happens after other phases.
$phases = @(
    @{ File = 'prerequisites.ps1';           Function = 'Invoke-PrerequisitesPhase';          Title = 'Getting ready' }
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

$failure = $null
try {
    # Every phase file is loaded before any of them runs, so the elevated process is not still reading new code off disk minutes in.
    $loadedPhases = @()
    foreach ($phase in $phases) {
        $path = Join-Path $stepsDir $phase.File
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host "-- $($phase.File) not written yet, skipping" -ForegroundColor DarkGray
            continue
        }
        . $path
        $loadedPhases += $phase
    }

    $phaseIndex = 0
    foreach ($phase in $loadedPhases) {
        $phaseIndex++

        # Script-scoped phase metadata avoids passing header state through every phase file.
        $Script:DevConfigPhaseIndex       = $phaseIndex
        $Script:DevConfigPhaseTotal       = $loadedPhases.Count
        $Script:DevConfigPhaseTitle       = $phase.Title
        $Script:DevConfigPhaseHeaderShown = $false

        if ($phase.File -eq 'wsl.ps1') {
            # The WSL phase registers resume using this orchestrator path.
            Invoke-WslPhase -OrchestratorPath $PSCommandPath
        } else {
            & $phase.Function
        }

        if ($phase.File -eq 'packages.ps1') {
            # New package locations are visible in this process only after PATH is refreshed.
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
    # Names are shown because the detailed flags may have scrolled off screen.
    if ($tally.Warned -gt 0) {
        Write-Host "  Flagged: $($Script:DevConfigWarnedSteps -join ', ')" -ForegroundColor Yellow
        Write-Host '  These were skipped or could not be confirmed. Running this again retries just those.' -ForegroundColor DarkGray
    }
    Write-Host '  A few Explorer and taskbar changes appear once you sign out and back in.' -ForegroundColor DarkGray
} catch {
    $failure = $_
}

if ($failure) {
    Write-Host ''
    Write-Host 'Calm OS setup stopped early.' -ForegroundColor Red
    Write-Host "  $($failure.Exception.Message)" -ForegroundColor Red
    $origin = $failure.InvocationInfo
    if ($origin -and $origin.ScriptName) {
        Write-Host "  ($(Split-Path -Leaf $origin.ScriptName) line $($origin.ScriptLineNumber))" -ForegroundColor DarkGray
    }
    Write-Host '  Nothing already applied was undone -- running this again picks up where it left off.' -ForegroundColor DarkGray
}

$logPath = Get-DevConfigLogPath
if ($logPath) {
    Write-Host "  Full log: $logPath" -ForegroundColor DarkGray
}

# Release the run lock before the final pause so a completed run does not block the next start.
Exit-DevConfigSingleInstance

# The elevated window owns the final pause on both the initial and resumed runs.
Wait-DevConfigKeyPress

Stop-DevConfigLog
if ($failure) {
    exit 1
}
