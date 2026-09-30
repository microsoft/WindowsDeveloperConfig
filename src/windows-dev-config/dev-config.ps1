<#
.SYNOPSIS
  Configures or cleans up a Windows developer workstation, or applies one developer workload.

.DESCRIPTION
  -Workload picks a definition from workloads\. The default, devconfig, is the complete
  Windows Dev Config setup; other workloads, such as winui, reuse the same phases, helpers,
  elevation, logging, and summary.
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Resumed,
    [switch] $AllowUnsigned,
    [switch] $ApplyTerminalFont,
    [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
    $definition = Get-DevConfigWorkload -Directory (Join-Path $PSScriptRoot 'workloads') -Workload $Workload -Action $Action
} catch {
    # Pause so the reason stays readable when this runs in a window that closes on exit.
    Write-Host $_.Exception.Message -ForegroundColor Red
    Wait-DevConfigKeyPress
    exit 1
}
$workloadName = $definition['Name']

# TLS is configured before any download step runs.
Enable-DevConfigModernTls

Invoke-DevConfigElevate -ScriptPath $PSCommandPath -NoElevate:$NoElevate -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload

if ($Action -eq 'Uninstall') {
    Invoke-DevConfigEnsureCleanupShell -ScriptPath $PSCommandPath -AllowUnsigned:$AllowUnsigned -Workload $Workload
} else {
    # WinGet module behavior is more consistent in PowerShell 7 than in Windows PowerShell 5.1.
    Invoke-DevConfigEnsurePwsh -ScriptPath $PSCommandPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload
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
} else {
    $setupNote = if ($definition['SetupNote']) { ", $($definition['SetupNote'])" } else { '' }
    Write-Host "$workloadName setup ($Action) -- $($phases.Count) phases$setupNote" -ForegroundColor Cyan
}

$failure = $null
try {
    # Every phase is loaded and checked before any runs, so a bad definition changes nothing and no code is read off disk minutes in.
    foreach ($phase in $phases) {
        $path = Join-Path $stepsDir $phase.File
        if (-not (Test-Path -LiteralPath $path)) {
            $rerun = "bootstrap.ps1 -Action $Action"
            if ($Workload -ne 'devconfig') { $rerun += " -Workload $Workload" }
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
    Write-Host "$workloadName $operation complete." -ForegroundColor Green
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

# Close the log before releasing the lock so another run can start while this window waits.
Stop-DevConfigLog
Exit-DevConfigSingleInstance

# The elevated window owns the final pause on both the initial and resumed runs.
Wait-DevConfigKeyPress

if ($failure) {
    exit 1
}
