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

    $shell       = Get-DevConfigShellExe
    $wrapperPath = Join-Path $PSScriptRoot '_resume-wrapper.ps1'

    # The wrapper (not cmd.exe) handles output capture, so the resumed run stays visible on screen.
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`" -ScriptPath `"$ScriptPath`""
    $action    = New-ScheduledTaskAction -Execute $shell -Argument $arguments

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
