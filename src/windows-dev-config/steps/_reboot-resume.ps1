<#
.SYNOPSIS
  Scheduled-task plumbing so the flow can resume elevated after the WSL-required reboot.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigResumeTask = 'WindowsDevConfigResume'

function Clear-DevConfigResume {
    # SilentlyContinue allows cleanup when no resume task is registered.
    Unregister-ScheduledTask -TaskName $Script:DevConfigResumeTask -Confirm:$false -ErrorAction SilentlyContinue
}

function Suspend-DevConfigForReboot {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath
    )

    $shell       = Get-DevConfigShellExe
    $wrapperPath = Join-Path $PSScriptRoot '_resume-wrapper.ps1'

    # The wrapper handles output capture so the resumed run stays visible on screen.
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`" -ScriptPath `"$ScriptPath`""
    $action    = New-ScheduledTaskAction -Execute $shell -Argument $arguments

    # Scheduled task logon matching requires the DOMAIN\User or MACHINE\User account name.
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger     = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal   = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

    # A short delay lets desktop and network initialization complete before package checks resume.
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

    # The resume task is already registered, so a manual restart continues from the same point.
    try {
        Restart-Computer -Force
    } catch {
        Write-Host ''
        Write-Host "Windows would not let setup restart this machine ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host 'Restart when convenient -- setup carries on by itself once you log back in.' -ForegroundColor Yellow
        # Keep the window open so the remaining manual restart instruction is visible.
        Wait-DevConfigKeyPress
        exit 0
    }

    # Restart-Computer can return before reboot begins, so pause before any fall-through code.
    Start-Sleep -Seconds 60
    exit 0
}
