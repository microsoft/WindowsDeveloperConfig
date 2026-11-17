<#
.SYNOPSIS
  Restart handling. Setup finishes everything that doesn't need a restart first. Then, when a restart is
  needed, it asks "Restart now? [Y/n]" if someone is at the console, and otherwise exits with 3010.
  -NoRestart never restarts or asks. -RestartWhenNeeded registers a resume task and restarts by itself.
  Running the same command again after a restart is the resume.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The Windows Installer code for "succeeded, restart required", so callers can tell it from a failure.
$Script:DevConfigRestartExitCode = 3010
$Script:DevConfigRestartCountdownSeconds = 60
# Matches the final pause, so a window nobody answers closes as it would without the question.
$Script:DevConfigRestartQuestionSeconds = 900
$Script:DevConfigRestartQuestionAsked = $false

# Each workload has its own task so one workload's run never cancels another's pending resume.
function Get-DevConfigResumeTaskName {
    if ($Script:DevConfigWorkload -eq 'devconfig') {
        return 'WindowsDevConfigResume'
    }
    return "WindowsDevConfigResume-$Script:DevConfigWorkload"
}

function Clear-DevConfigResume {
    # SilentlyContinue allows cleanup when no resume task is registered.
    Unregister-ScheduledTask -TaskName (Get-DevConfigResumeTaskName) -Confirm:$false -ErrorAction SilentlyContinue
}

# A rerun reads this to tell whether Windows restarted since a run asked for it.
function Get-DevConfigRestartRequestPath {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )
    return (Join-Path $Directory "$Script:DevConfigWorkload-restart.json")
}

function Get-DevConfigBootTimeUtc {
    return (Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime).LastBootUpTime.ToUniversalTime()
}

# State is None (no request), Pending (Windows hasn't restarted since), Restarted, or Unknown (the saved request or
# Windows' boot time could not be read; Reason says which). Waiting lists the steps that waited for the restart.
function Get-DevConfigRestartRequest {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )
    $path = Get-DevConfigRestartRequestPath -Directory $Directory
    $request = [pscustomobject]@{ State = 'None'; Waiting = @(); Reason = $null; Path = $path }
    if (-not (Test-Path -LiteralPath $path)) {
        return $request
    }
    try {
        # Ticks, not a date string: ConvertFrom-Json turns date strings into local DateTime values in PowerShell 7.
        # Types are checked before any conversion, since PowerShell would happily turn true into 1 tick.
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($saved -isnot [Management.Automation.PSCustomObject]) {
            throw 'It is not a JSON object.'
        }
        $ticks = $saved.PSObject.Properties['RequestedAtUtcTicks']
        if (-not $ticks -or -not ($ticks.Value -is [long] -or $ticks.Value -is [int])) {
            throw 'RequestedAtUtcTicks is missing or not a whole number.'
        }
        # Setup didn't exist before 2020, and a request can't come from the future (a day allows for clock changes).
        if ($ticks.Value -lt [DateTime]::new(2020, 1, 1).Ticks -or $ticks.Value -gt [DateTime]::UtcNow.AddDays(1).Ticks) {
            throw "RequestedAtUtcTicks is out of range ($($ticks.Value))."
        }
        $requestedAt = [DateTime]::new([long]$ticks.Value, [DateTimeKind]::Utc)
        $waitingProperty = $saved.PSObject.Properties['Waiting']
        if (-not $waitingProperty) {
            throw 'Waiting is missing.'
        }
        $waiting = @($waitingProperty.Value | ForEach-Object { $_ })
        if (@($waiting | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'Waiting must list step names.'
        }
    } catch {
        $request.State = 'Unknown'
        $request.Reason = "the saved restart request in $path could not be read ($($_.Exception.Message))"
        return $request
    }
    try {
        $bootTime = Get-DevConfigBootTimeUtc
    } catch {
        $request.State = 'Unknown'
        $request.Reason = "Windows' last boot time could not be read ($($_.Exception.Message))"
        return $request
    }
    $request.Waiting = $waiting
    $request.State = if ($bootTime -gt $requestedAt) { 'Restarted' } else { 'Pending' }
    return $request
}

# Writes the request atomically and reads it back. Returns $true only when it reads back as Pending,
# which is the evidence a resumed run needs, so callers must not restart Windows on $false.
function Save-DevConfigRestartRequest {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )
    $path = Get-DevConfigRestartRequestPath -Directory $Directory
    $temp = "$path.new"
    $state = [pscustomobject]@{
        RequestedAtUtcTicks = [DateTime]::UtcNow.Ticks
        Waiting             = @($Script:DevConfigRestartPendingSteps)
    }
    try {
        [IO.File]::WriteAllText($temp, ($state | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        # Replace swaps the file in one step, so a reader sees the old request or the new one, never neither.
        # NullString: PowerShell would pass $null to a string parameter as '', which Replace rejects as a backup path.
        if ([IO.File]::Exists($path)) {
            [IO.File]::Replace($temp, $path, [Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($temp, $path)
        }
        $saved = Get-DevConfigRestartRequest -Directory $Directory
        if ($saved.State -ne 'Pending') {
            $why = if ($saved.Reason) { $saved.Reason } else { "it reads back as $($saved.State)" }
            throw "the saved request could not be confirmed: $why"
        }
        return $true
    } catch {
        Write-Host "  Setup could not record that a restart is needed: $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Clear-DevConfigRestartRequest {
    param(
        [Parameter(Mandatory)] [string] $Directory
    )
    Remove-Item -LiteralPath (Get-DevConfigRestartRequestPath -Directory $Directory) -Force -ErrorAction SilentlyContinue
}

function Test-DevConfigConsoleInput {
    try {
        return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and ($null -ne [Console]::KeyAvailable)
    } catch {
        # No console to read from, as when input is redirected.
        return $false
    }
}

# Returns $true to restart now, or $false when someone pressed a key.
function Wait-DevConfigRestartCountdown {
    param(
        [Parameter(Mandatory)] [int] $Seconds
    )
    for ($remaining = $Seconds; $remaining -gt 0; $remaining--) {
        Write-Host -NoNewline "`r  Restarting in $remaining seconds. Press any key to cancel.   " -ForegroundColor Yellow
        for ($tick = 0; $tick -lt 10; $tick++) {
            if ([Console]::KeyAvailable) {
                [void][Console]::ReadKey($true)
                Write-Host ''
                return $false
            }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ''
    return $true
}

# The name of the next key pressed, such as Y or Enter, or $null when none is waiting.
function Read-DevConfigKey {
    if ([Console]::KeyAvailable) {
        return "$([Console]::ReadKey($true).Key)"
    }
    return $null
}

# Returns Yes, No, or NoAnswer. Enter counts as yes, as [Y/n] says; other keys are ignored.
function Read-DevConfigRestartAnswer {
    param(
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )
    # Drop keys pressed earlier, such as Enter during the run, before showing the question, so they can't answer it.
    while ($null -ne (Read-DevConfigKey)) { }
    Write-Host -NoNewline 'Restart now? [Y/n] ' -ForegroundColor Yellow
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $key = Read-DevConfigKey
        if ($key -in @('Y', 'Enter')) {
            Write-Host 'Y'
            return 'Yes'
        }
        if ($key -in @('N', 'Escape')) {
            Write-Host 'N'
            return 'No'
        }
        if ($null -eq $key) {
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ''
    return 'NoAnswer'
}

# shutdown.exe is used instead of Restart-Computer because the latter goes through WMI even for the local
# machine, and that call can time out and report failure mid-restart. Without /f, apps with unsaved work
# can still ask before Windows restarts. Returns $true when the restart is under way.
function Restart-DevConfigWindows {
    param(
        [Parameter(Mandatory)] [string] $RefusedMessage
    )
    $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $result = Invoke-DevConfigNativeCommand -FilePath $shutdown -Arguments @('/r', '/t', '0')

    # 1115 means a restart is already under way, which is the outcome this wants either way.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1115) {
        Write-Host ''
        Write-Host "Windows would not let setup restart this machine (shutdown.exe returned $($result.ExitCode))." -ForegroundColor Yellow
        Write-Host $RefusedMessage -ForegroundColor Yellow
        return $false
    }
    return $true
}

# The default when someone is at the console: ask, with no countdown, and restart only on yes. No answer means no.
# Nothing is scheduled; after the restart, running the same command again finishes setup.
# Returns $true when Windows is restarting.
function Request-DevConfigRestart {
    param(
        [int] $TimeoutSeconds = $Script:DevConfigRestartQuestionSeconds
    )
    # Without a console nobody can answer, so setup never restarts; the summary already said what to do.
    if (-not (Test-DevConfigConsoleInput)) {
        return $false
    }
    Write-Host ''
    Write-Host 'Windows needs to restart to finish setup. Save your work first.' -ForegroundColor Yellow
    Write-Host "After it restarts, run the same command again; it picks up where it left off. No answer in $([Math]::Max(1, [Math]::Round($TimeoutSeconds / 60))) minutes means no." -ForegroundColor DarkGray
    # The question takes the place of the final pause, so the window doesn't wait twice.
    $Script:DevConfigRestartQuestionAsked = $true
    $answer = Read-DevConfigRestartAnswer -TimeoutSeconds $TimeoutSeconds
    if ($answer -eq 'Yes') {
        return (Restart-DevConfigWindows -RefusedMessage 'Restart when convenient, then run the same command again; it picks up where it left off.')
    }
    if ($answer -eq 'NoAnswer') {
        Write-Host "There was no answer, so setup didn't restart Windows." -ForegroundColor Yellow
    }
    Write-Host 'Restart Windows when you are ready, then run the same command again; it picks up where it left off.' -ForegroundColor Yellow
    return $false
}

# Opt-in only (-RestartWhenNeeded), for VMs and labs: registers the resume task, then restarts by itself.
# With a console it shows a countdown that can be cancelled; without one it restarts right away.
# Returns $true when Windows is restarting, or $false when the restart was cancelled or refused.
function Suspend-DevConfigForReboot {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [int] $CountdownSeconds = $Script:DevConfigRestartCountdownSeconds
    )

    $shell = Get-DevConfigTaskShellExe
    # The limited task requires fresh UAC consent before any resumed code runs elevated.
    # -Skip is kept so items left out before the reboot stay untouched afterward.
    $arguments = (Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed -AllowUnsigned:$Script:DevConfigAllowUnsigned -RequestElevation -Action $Script:DevConfigAction -Workload $Script:DevConfigWorkload -Skip $Script:DevConfigSkip -RestartWhenNeeded) -join ' '
    $action = New-ScheduledTaskAction -Execute $shell -Argument $arguments

    # Scheduled task logon matching requires the DOMAIN\User or MACHINE\User account name.
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger     = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal   = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

    # A short delay lets desktop and network initialization complete before package checks resume.
    try {
        $trigger.Delay = 'PT30S'
    } catch {
        Write-Verbose "Could not delay the resume trigger: $($_.Exception.Message)"
    }

    # The resumed run continues only once the saved request shows Windows restarted, so without a readable
    # pending request there is nothing safe to resume: register nothing and restart nothing.
    $request = Get-DevConfigRestartRequest -Directory (Split-Path -Path $ScriptPath -Parent)
    if ($request.State -ne 'Pending') {
        $why = if ($request.Reason) { $request.Reason } else { "the saved restart request reads as $($request.State)" }
        Write-Host "Setup won't restart Windows by itself: $why." -ForegroundColor Yellow
        Write-Host 'Restart Windows, then run the same command again; it picks up where it left off.' -ForegroundColor Yellow
        return $false
    }

    Clear-DevConfigResume
    Save-DevConfigTally -Path (Get-DevConfigTallyPath -Directory (Split-Path -Path $ScriptPath -Parent)) `
        -TerminalBackedUp $Script:DevConfigTerminalBackedUp
    Register-ScheduledTask -TaskName (Get-DevConfigResumeTaskName) -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    Write-Host ''
    Write-Host 'Windows needs to restart to finish setup. Save your work now.' -ForegroundColor Yellow
    Write-Host 'Setup continues after you sign back in and accept one more UAC prompt.' -ForegroundColor Yellow

    # Without a console there is nobody to cancel a countdown, as in a VM or lab run, so restart now.
    # shutdown's own countdown isn't used: any delay makes it imply /f, which closes apps without saving.
    if (-not (Test-DevConfigConsoleInput)) {
        Write-Host 'There is no console to show a countdown, so Windows restarts now.' -ForegroundColor Yellow
    } elseif (-not (Wait-DevConfigRestartCountdown -Seconds $CountdownSeconds)) {
        Write-Host 'Restart cancelled. Setup continues after your next restart and sign-in,' -ForegroundColor Yellow
        Write-Host 'or restart and run the same command again.' -ForegroundColor Yellow
        return $false
    }
    return (Restart-DevConfigWindows -RefusedMessage 'Restart when convenient -- setup carries on by itself once you sign back in.')
}
