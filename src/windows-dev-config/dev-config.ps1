<#
.SYNOPSIS
  Configures or cleans up a Windows developer workstation, or applies one developer workload.

.DESCRIPTION
  -Workload picks a definition from workloads\. The default, devconfig, is the complete
  Windows Dev Config setup; other workloads, such as winui, reuse the same phases, helpers,
  elevation, logging, and summary.

  -Skip leaves out settings, steps, and packages by id, such as registry-system/Sudo,
  fonts/CascadiaDefaultFont, or Microsoft.AzureCLI. Skipped items are never checked or changed.
  Ids can be passed as an array or as one comma-separated string. An unknown id stops the run
  before anything changes.

  Setup finishes everything that doesn't need a restart first. When something, such as WSL, still
  needs one, it asks "Restart now? [Y/n]" if someone is at the console; otherwise it exits with 3010.
  Either way, after the restart run the same command again; it picks up where it left off.
  -NoRestart never restarts or asks, for callers that handle the restart themselves.
  -RestartWhenNeeded restarts by itself and registers a task that resumes setup after the restart.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Resumed,
    [switch] $AllowUnsigned,
    [switch] $ApplyTerminalFont,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
    [string[]] $Skip,
    [switch] $RestartWhenNeeded,
    [switch] $NoRestart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A child shell can inherit incompatible built-in modules from another PowerShell edition.
$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

$stepsDir = Join-Path $PSScriptRoot 'steps'
$securityCode = [IO.File]::ReadAllText((Join-Path $stepsDir '_security.ps1'))
if (-not $AllowUnsigned) {
    # Verify and execute the same text to avoid a file-swap race.
    $signature = Get-AuthenticodeSignature -Content ([Text.Encoding]::Unicode.GetBytes($securityCode)) -SourcePathOrExtension '.ps1'
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
        throw 'The setup security helper failed Microsoft signature verification. Run bootstrap.ps1 to reinstall; use -AllowUnsigned only for development.'
    }
}
. ([scriptblock]::Create($securityCode))
if (-not $AllowUnsigned) {
    Assert-DevConfigProtectedTree -Directory $PSScriptRoot
    Assert-DevConfigMicrosoftSigned -Directory $PSScriptRoot
}

# Windows PowerShell 5.1 defaults to ANSI; force UTF-8 for console symbols.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

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
. (Join-Path $stepsDir '_workload.ps1')

$Script:DevConfigAllowUnsigned = [bool]$AllowUnsigned
# Checked before anything else runs, -ApplyTerminalFont included.
if ($NoRestart -and $RestartWhenNeeded) {
    Write-Host '-NoRestart and -RestartWhenNeeded contradict each other; pass one or neither.' -ForegroundColor Red
    Wait-DevConfigKeyPress
    exit 1
}
if ($ApplyTerminalFont) {
    . (Join-Path $stepsDir 'fonts.ps1')
    $pendingPath = Get-DevConfigPendingTerminalFontPath
    if (-not (Test-Path -LiteralPath $pendingPath)) {
        Write-Host 'No Terminal font update is pending.'
        exit 0
    }
    $logPath = [IO.Path]::ChangeExtension($pendingPath, '.log')
    Start-DevConfigLog -Path $logPath
    $failure = $null
    try {
        Invoke-DevConfigPendingTerminalFont
    } catch {
        $failure = $_
        Write-Host "The Terminal font update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Full log: $logPath" -ForegroundColor DarkGray
    } finally {
        Stop-DevConfigLog
    }
    if ($failure) {
        Wait-DevConfigKeyPress -TimeoutSeconds 60
        exit 1
    }
    exit 0
}

# The workload decides which phases run; everything else in this script is shared by every workload.
$Workload = $Workload.ToLowerInvariant()
$Script:DevConfigWorkload = $Workload
try {
    $Skip = @(ConvertTo-DevConfigSkipIds -Skip $Skip)
    $definition = Get-DevConfigWorkload -Directory (Join-Path $PSScriptRoot 'workloads') -Workload $Workload -Action $Action
    if ($Skip.Count -gt 0) {
        Assert-DevConfigWorkloadSkipIds -Skip $Skip -Directory (Join-Path $PSScriptRoot 'workloads') -Workload $Workload `
            -Actions @($definition['Actions']) -OrchestratorPath $PSCommandPath
    }
} catch {
    # Pause so the reason stays readable when this runs in a window that closes on exit.
    Write-Host $_.Exception.Message -ForegroundColor Red
    Wait-DevConfigKeyPress
    exit 1
}
$Script:DevConfigSkip = $Skip
$workloadName = $definition['Name']

# A resume task runs at every sign-in, unattended. It continues only when the saved request shows Windows restarted
# since; otherwise it exits at once, without UAC or a pause, and a manual run picks up instead.
if ($Resumed -and $Action -ne 'Uninstall') {
    $resumeRequest = Get-DevConfigRestartRequest -Directory $PSScriptRoot
    if ($resumeRequest.State -eq 'Pending') {
        Write-Host "Windows hasn't restarted yet, so $workloadName setup continues after the restart." -ForegroundColor Yellow
        exit $Script:DevConfigRestartExitCode
    }
    if ($resumeRequest.State -ne 'Restarted') {
        $why = if ($resumeRequest.Reason) { $resumeRequest.Reason } else { 'no restart request was saved' }
        Write-Host "Setup could not confirm that Windows restarted, so it didn't continue on its own: $why." -ForegroundColor Yellow
        Write-Host 'Run the same command again to finish; it picks up where it left off.' -ForegroundColor Yellow
        exit 1
    }
}

# TLS is configured before any download step runs.
Enable-DevConfigModernTls

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload -Skip $Skip -RestartWhenNeeded:$RestartWhenNeeded -NoRestart:$NoRestart

if ($Action -eq 'Uninstall') {
    Invoke-DevConfigEnsureCleanupShell -ScriptPath $PSCommandPath -AllowUnsigned:$AllowUnsigned -Workload $Workload -Skip $Skip -RestartWhenNeeded:$RestartWhenNeeded -NoRestart:$NoRestart
} else {
    # WinGet module behavior is more consistent in PowerShell 7 than in Windows PowerShell 5.1.
    Invoke-DevConfigEnsurePwsh -ScriptPath $PSCommandPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload -Skip $Skip -RestartWhenNeeded:$RestartWhenNeeded -NoRestart:$NoRestart
}

# The lock starts after relaunches so the worker process owns the log file.
# Workloads share one lock because they install through the same WinGet and registry paths.
if (-not (Enter-DevConfigSingleInstance)) {
    Write-Host ''
    Write-Host 'Setup is already running in another window.' -ForegroundColor Yellow
    Write-Host 'Switch to it rather than starting a second copy -- they would fight over the same installs.' -ForegroundColor DarkGray
    Wait-DevConfigKeyPress
    exit 1
}

Start-DevConfigLog -Path (Join-Path $PSScriptRoot "$Workload-log.txt") -Append:$Resumed

# Any prior resume task for this workload is stale once this run starts.
Clear-DevConfigResume

$Script:DevConfigResumed = [bool]$Resumed -and $Action -ne 'Uninstall'
$Script:DevConfigAction = $Action
if ($Script:DevConfigResumed) {
    # Restore the pre-reboot tally so the final summary covers the whole run.
    Restore-DevConfigTally -Path (Get-DevConfigTallyPath -Directory $PSScriptRoot)
}
# Running the same command again is the resume; the saved request tells it whether Windows restarted in between.
# Only that saved evidence counts: -Resumed alone doesn't prove a restart happened.
$restartRequest = [pscustomobject]@{ State = 'None'; Waiting = @(); Reason = $null; Path = $null }
if ($Action -ne 'Uninstall') {
    $restartRequest = Get-DevConfigRestartRequest -Directory $PSScriptRoot
}
$Script:DevConfigAfterRestart = $restartRequest.State -eq 'Restarted'
$Script:DevConfigRestartRequestPending = $restartRequest.State -eq 'Pending'
$phases = @($definition['Phases'])

$operation = if ($Action -eq 'Uninstall') { 'cleanup' } else { 'setup' }
Write-Host ''
if ($Action -eq 'Uninstall') {
    Write-Host "$workloadName cleanup -- resetting settings and removing developer tools" -ForegroundColor Cyan
    if ($definition['UninstallWarning']) {
        Write-Host $definition['UninstallWarning'] -ForegroundColor Yellow
    }
    Write-Host 'Some uninstallers may request Administrator approval.' -ForegroundColor DarkGray
} elseif ($Script:DevConfigResumed) {
    Write-Host "Welcome back. Resuming $workloadName setup ($Action) after the reboot..." -ForegroundColor Cyan
} elseif ($restartRequest.State -eq 'Restarted') {
    Write-Host "Welcome back. $workloadName setup ($Action) picks up where it left off before the restart." -ForegroundColor Cyan
} else {
    $setupNote = if ($definition['SetupNote']) { ", $($definition['SetupNote'])" } else { '' }
    Write-Host "$workloadName setup ($Action) -- $($phases.Count) phases$setupNote" -ForegroundColor Cyan
}
if ($Skip.Count -gt 0) {
    Write-Host "Leaving out (-Skip): $($Skip -join ', ')" -ForegroundColor DarkGray
}
if ($restartRequest.State -eq 'Unknown') {
    Write-Host "Setup can't tell whether Windows restarted since an earlier run asked for it: $($restartRequest.Reason)." -ForegroundColor Yellow
    Write-Host "  $($restartRequest.Path) is left as it is, and setup won't restart Windows by itself this run. Delete it after restarting if this keeps appearing." -ForegroundColor DarkGray
}

$failure = $null
try {
    # Load phase files and check function and parameter names before running any phase.
    foreach ($phase in $phases) {
        $path = Join-Path $stepsDir $phase.File
        if (-not (Test-Path -LiteralPath $path)) {
            $rerun = "bootstrap.ps1 -Action $Action"
            if ($Workload -ne 'devconfig') { $rerun += " -Workload $Workload" }
            if ($Skip.Count -gt 0) { $rerun += " -Skip $($Skip -join ',')" }
            if ($RestartWhenNeeded) { $rerun += ' -RestartWhenNeeded' }
            if ($NoRestart) { $rerun += ' -NoRestart' }
            throw "The $operation script is missing: $path. Run $rerun to reinstall it."
        }
        . $path
        $null = Resolve-DevConfigWorkloadPhase -Phase $phase -OrchestratorPath $PSCommandPath
    }

    $phaseIndex = 0
    foreach ($phase in $phases) {
        $phaseIndex++

        # Script-scoped phase metadata avoids passing header state through every phase file.
        $Script:DevConfigPhaseIndex       = $phaseIndex
        $Script:DevConfigPhaseTotal       = $phases.Count
        $Script:DevConfigPhaseTitle       = $phase.Title
        $Script:DevConfigPhaseHeaderShown = $false

        Invoke-DevConfigWorkloadPhase -Phase $phase -OrchestratorPath $PSCommandPath

        # New tool locations are visible in this process only after PATH is refreshed.
        Update-DevConfigSessionPath
    }

    Show-DevConfigSilentSkipSummary
    Write-Host ''
    if ($Script:DevConfigRestartRequired) {
        Write-Host "$workloadName $operation needs a restart to finish." -ForegroundColor Yellow
    } else {
        Write-Host "$workloadName $operation complete." -ForegroundColor Green
    }
    $tally = $Script:DevConfigTally
    $summaryParts = @("$($tally.Done) changed", "$($tally.AlreadyOk) already up to date")
    if ($tally.Warned -gt 0) {
        $summaryParts += "$($tally.Warned) flagged"
    }
    if ($Script:DevConfigRestartPendingSteps.Count -gt 0) {
        $summaryParts += "$($Script:DevConfigRestartPendingSteps.Count) waiting for a restart"
    }
    Write-Host "  $($summaryParts -join ', ')" -ForegroundColor DarkGray
    # Names are shown because the detailed flags may have scrolled off screen.
    if ($tally.Warned -gt 0) {
        Write-Host "  Flagged: $($Script:DevConfigWarnedSteps -join ', ')" -ForegroundColor Yellow
        Write-Host '  These were skipped or could not be confirmed. Running this again retries just those.' -ForegroundColor DarkGray
    }
    if ($Script:DevConfigRestartRequired) {
        Write-Host "  Waiting for a restart: $($Script:DevConfigRestartPendingSteps -join ', ')" -ForegroundColor Yellow
        if (-not $RestartWhenNeeded) {
            Write-Host '  Restart Windows, then run the same command again; it picks up where it left off.' -ForegroundColor Yellow
        }
    }
    # Notes raised by steps come before the workload's standing notes.
    foreach ($note in $Script:DevConfigNotes) {
        $color = if ($note.Warning) { 'Yellow' } else { 'DarkGray' }
        Write-Host "  $($note.Message)" -ForegroundColor $color
    }
    foreach ($note in @($definition['Notes'] | Where-Object { $_ })) {
        Write-Host "  $note" -ForegroundColor DarkGray
    }
} catch {
    $failure = $_
}

if ($failure) {
    Write-Host ''
    Write-Host "$workloadName $operation stopped early." -ForegroundColor Red
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

# A failed run keeps any earlier request. So does a run that didn't verify every step that waited for the restart,
# whether it was flagged, skipped, or not part of this action, so a later run can't forget that Windows already
# restarted for it and ask for another restart.
$restartRequired = -not $failure -and $Script:DevConfigRestartRequired
# Only a request that saved and read back is evidence a resumed run can trust, so it gates the automatic restart.
$restartRecorded = $false
# An unreadable request is left in place for diagnosis; this run neither overwrites nor deletes it.
if (-not $failure -and $Action -ne 'Uninstall' -and $restartRequest.State -ne 'Unknown') {
    if ($restartRequired) {
        $restartRecorded = Save-DevConfigRestartRequest -Directory $PSScriptRoot -PreviousWaiting $restartRequest.Waiting
    } elseif (@($restartRequest.Waiting | Where-Object { -not $Script:DevConfigTalliedSteps.ContainsKey($_) }).Count -eq 0) {
        Clear-DevConfigRestartRequest -Directory $PSScriptRoot
    }
}
if ($restartRequired -and -not $NoRestart -and -not $restartRecorded) {
    Write-Host "  Setup won't restart Windows by itself without a saved restart request." -ForegroundColor Yellow
    Write-Host '  Restart Windows, then run the same command again; it picks up where it left off.' -ForegroundColor Yellow
}

Stop-DevConfigLog

# -NoRestart never restarts. -RestartWhenNeeded restarts by itself, after a countdown when there's a console;
# otherwise setup asks first, and only when someone is at the console to answer.
$restarting = $false
if ($restartRequired -and $restartRecorded -and -not $NoRestart) {
    try {
        if ($RestartWhenNeeded) {
            $restarting = Suspend-DevConfigForReboot -ScriptPath $PSCommandPath
        } else {
            $restarting = Request-DevConfigRestart
        }
    } catch {
        Write-Host "Setup could not arrange the restart: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Restart Windows, then run the same command again; it picks up where it left off.' -ForegroundColor Yellow
    }
}
# The lock is held through the question or countdown so a second run can't remove the resume task or start
# installing while Windows restarts. It is released before the final pause so another run can start while this window waits.
Exit-DevConfigSingleInstance
if ($restarting) {
    exit $Script:DevConfigRestartExitCode
}

# The elevated window owns the final pause on both the initial and resumed runs. A restart question already
# waited for an answer, so the window doesn't wait again.
if (-not $Script:DevConfigRestartQuestionAsked) {
    Wait-DevConfigKeyPress
}

if ($failure) {
    exit 1
}
# 3010 is "succeeded, restart required", so callers can tell a needed restart from a failure.
if ($restartRequired) {
    exit $Script:DevConfigRestartExitCode
}
