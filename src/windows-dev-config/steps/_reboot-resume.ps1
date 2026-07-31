<#
.SYNOPSIS
  Scheduled-task plumbing so the flow can resume elevated after the WSL-required reboot.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigResumeTask = 'WindowsDevConfigResume'

function Clear-DevConfigResume {
    # Safe to call even when no task is registered.
    Unregister-ScheduledTask -TaskName $Script:DevConfigResumeTask -Confirm:$false -ErrorAction SilentlyContinue
}

function Suspend-DevConfigForReboot {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath
    )

    $shell   = Get-DevConfigShellExe
    $logPath = Join-Path (Split-Path -Path $ScriptPath -Parent) 'resume-output.log'

    # Task Scheduler actions have no redirection of their own, and in-script '*>' misses
    # unhandled thrown errors; wrap in cmd.exe for real process-level stdout/stderr capture.
    $innerCommand = "`"$shell`" -NoProfile -ExecutionPolicy Bypass -File `"`"$ScriptPath`"`" -NoElevate > `"$logPath`" 2>&1"
    $arguments    = "/c `"$innerCommand`""
    $action       = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $arguments

    # WindowsIdentity's Name gives DOMAIN\User (or MACHINE\User for local accounts),
    # which is what the scheduled task's logon matching needs.
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger     = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal   = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

    Clear-DevConfigResume
    Register-ScheduledTask -TaskName $Script:DevConfigResumeTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    Write-Host 'Registered a one-time resume task; rebooting now to finish WSL setup after you log back in...' -ForegroundColor Yellow
    Restart-Computer -Force

    # Restart-Computer -Force signals the reboot but returns immediately; sleep so this
    # process doesn't fall through to code that assumes the reboot already happened.
    Start-Sleep -Seconds 60
    exit 0
}
