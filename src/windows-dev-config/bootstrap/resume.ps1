Set-StrictMode -Version Latest

function Get-SlipstreamTaskName {
    param([Parameter(Mandatory)] [string] $RunId)

    return "WindowsDeveloperConfig-Slipstream-$RunId"
}

function Get-SlipstreamUserTaskName {
    param([Parameter(Mandatory)] [string] $RunId)

    return "WindowsDeveloperConfig-User-$RunId"
}

function New-SlipstreamResumeTaskDefinition {
    param(
        [Parameter(Mandatory)] [object] $State,
        [switch] $AllowUnsigned,
        [switch] $NoRestart
    )

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $installPath = Join-Path $State.payloadRoot 'install.ps1'
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', $(if ($AllowUnsigned) { 'Bypass' } else { 'AllSigned' }),
        '-File', ('"{0}"' -f $installPath),
        '-Action', 'Resume',
        '-RunId', ('"{0}"' -f $State.runId),
        '-PayloadRoot', ('"{0}"' -f $State.payloadRoot)
    )
    if ($AllowUnsigned) {
        $arguments += '-AllowUnsigned'
    }
    if ($NoRestart) {
        $arguments += '-NoRestart'
    }

    $action = New-ScheduledTaskAction `
        -Execute $powershellPath `
        -Argument ($arguments -join ' ') `
        -WorkingDirectory $State.payloadRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $State.originalUserSid
    $principal = New-ScheduledTaskPrincipal `
        -UserId $State.originalUserSid `
        -LogonType Interactive `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 2)

    return New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Resume Windows Developer Config after a required restart.'
}

function Register-SlipstreamResumeTask {
    param(
        [Parameter(Mandatory)] [object] $State,
        [switch] $AllowUnsigned,
        [switch] $NoRestart
    )

    $taskName = Get-SlipstreamTaskName -RunId $State.runId
    $definition = New-SlipstreamResumeTaskDefinition `
        -State $State `
        -AllowUnsigned:$AllowUnsigned `
        -NoRestart:$NoRestart
    Register-ScheduledTask `
        -TaskName $taskName `
        -InputObject $definition `
        -Force | Out-Null
    Write-SlipstreamLog -RunId $State.runId -Message "Registered elevated resume task '$taskName'."
}

function New-SlipstreamUserTaskDefinition {
    param(
        [Parameter(Mandatory)] [object] $State,
        [ValidateSet('Configure', 'Verify')]
        [string] $Mode = 'Configure',
        [switch] $AllowUnsigned
    )

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $userScriptPath = Join-Path $State.payloadRoot 'bootstrap\user.ps1'
    $executionPolicy = if ($AllowUnsigned) { 'Bypass' } else { 'AllSigned' }
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', $executionPolicy,
        '-File', ('"{0}"' -f $userScriptPath),
        '-Action', $Mode
    )
    $taskAction = New-ScheduledTaskAction `
        -Execute $powershellPath `
        -Argument ($arguments -join ' ') `
        -WorkingDirectory $State.payloadRoot
    $principal = New-ScheduledTaskPrincipal `
        -UserId $State.originalUserSid `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -MultipleInstances IgnoreNew

    return New-ScheduledTask `
        -Action $taskAction `
        -Principal $principal `
        -Settings $settings `
        -Description 'Apply Windows Developer Config per-user settings without elevation.'
}

function Invoke-SlipstreamUserConfiguration {
    param(
        [Parameter(Mandatory)] [object] $State,
        [ValidateSet('Configure', 'Verify')]
        [string] $Mode = 'Configure',
        [switch] $AllowUnsigned
    )

    $taskName = Get-SlipstreamUserTaskName -RunId $State.runId
    $definition = New-SlipstreamUserTaskDefinition `
        -State $State `
        -Mode $Mode `
        -AllowUnsigned:$AllowUnsigned
    try {
        Register-ScheduledTask `
            -TaskName $taskName `
            -InputObject $definition `
            -Force | Out-Null
        $previousRun = (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
        Start-ScheduledTask -TaskName $taskName

        $deadline = [DateTime]::UtcNow.AddMinutes(15)
        $started = $false
        do {
            Start-Sleep -Seconds 1
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
            $started = $info.LastRunTime -gt $previousRun
            if ($started -and $task.State -ne 'Running') {
                break
            }
        } while ([DateTime]::UtcNow -lt $deadline)

        if (-not $started -or $task.State -eq 'Running') {
            throw 'Timed out waiting for the limited per-user configuration task.'
        }
        if ([int]$info.LastTaskResult -ne 0) {
            throw "Per-user configuration failed with task result $($info.LastTaskResult)."
        }
        Write-SlipstreamLog `
            -RunId $State.runId `
            -Message "Completed limited-token Copilot plugin $($Mode.ToLowerInvariant())."
    }
    finally {
        $existing = Get-ScheduledTask `
            -TaskName $taskName `
            -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $taskName
            }
            Unregister-ScheduledTask `
                -TaskName $taskName `
                -Confirm:$false
        }
    }
}

function Unregister-SlipstreamResumeTask {
    param([Parameter(Mandatory)] [string] $RunId)

    $taskName = Get-SlipstreamTaskName -RunId $RunId
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-SlipstreamLog -RunId $RunId -Message "Removed resume task '$taskName'."
    }
}

function Request-SlipstreamRestart {
    param(
        [Parameter(Mandatory)] [object] $State,
        [Parameter(Mandatory)] [string] $Reason,
        [switch] $NoRestart
    )

    if ([int]$State.rebootCount -ge 3) {
        throw "Refusing another restart after $($State.rebootCount) setup restarts. Last reason: $Reason"
    }

    $State.status = 'WaitingForReboot'
    $State.rebootCount = [int]$State.rebootCount + 1
    $State.rebootBootId = Get-SlipstreamBootId
    $State.rebootReason = $Reason
    $State.rebootHistory = @($State.rebootHistory) + $Reason
    Save-SlipstreamState -State $State

    if ($NoRestart) {
        Write-SlipstreamLog `
            -RunId $State.runId `
            -Level WARN `
            -Message "Restart required but -NoRestart was supplied. Reason: $Reason"
        return
    }

    Write-SlipstreamLog `
        -RunId $State.runId `
        -Message "Restarting in 15 seconds. Setup will resume after sign-in. Reason: $Reason"
    $result = Invoke-SlipstreamNative `
        -RunId $State.runId `
        -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') `
        -ArgumentList @('/r', '/t', '15', '/d', 'p:4:1', '/c', 'Windows Developer Config will resume after sign-in.') `
        -Name 'Schedule Windows restart' `
        -AllowAnyExitCode
    if ($result.ExitCode -ne 0) {
        throw "Failed to schedule restart: $($result.ExitCodeHex)"
    }
}
