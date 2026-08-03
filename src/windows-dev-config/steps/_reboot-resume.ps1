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

    # At the instant of logon the desktop is still assembling and the network stack often has no
    # address yet, which would make the resumed run's package checks fail for no real reason. Half a
    # minute costs nothing and lets the machine settle first.
    try {
        $trigger.Delay = 'PT30S'
    } catch {
        Write-Verbose "Could not delay the resume trigger: $($_.Exception.Message)"
    }

    Clear-DevConfigResume
    Register-ScheduledTask -TaskName $Script:DevConfigResumeTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Save-DevConfigTally -Path (Join-Path (Split-Path -Path $ScriptPath -Parent) 'devconfig-tally.json')

    Write-Host ''
    Write-Host 'WSL needs a restart to finish. Rebooting in 10s -- setup continues automatically' -ForegroundColor Yellow
    Write-Host 'after you log back in. This is expected, not an error.' -ForegroundColor Yellow
    Start-Sleep -Seconds 10

    # Group policy or a pending servicing operation can refuse the restart. The resume task is already
    # registered at this point, so a manual restart picks up exactly where an automatic one would have.
    try {
        Restart-Computer -Force
    } catch {
        Write-Host ''
        Write-Host "Windows would not let setup restart this machine ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host 'Restart when convenient -- setup carries on by itself once you log back in.' -ForegroundColor Yellow
        # The restart is the one thing left for the user to do, so keep the window up long enough to
        # read it rather than closing on the only instruction that still matters.
        Wait-DevConfigKeyPress
        exit 0
    }

    # Restart-Computer -Force signals the reboot but returns immediately; sleep so this
    # process doesn't fall through to code that assumes the reboot already happened.
    Start-Sleep -Seconds 60
    exit 0
}
