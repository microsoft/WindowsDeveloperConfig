<#
.SYNOPSIS
  Small shared console helpers: the run's log file, and the end-of-run pause so a window
  nobody is watching doesn't just vanish the moment the last line prints.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigLogPath = $null

# One file for the whole run, appended to across the reboot, so there's something to read (or send
# on) when a step fails. Start this only in the process that does the work: the elevation and
# PowerShell 7 relaunches would otherwise leave two processes writing to the same file.
function Start-DevConfigLog {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Append
    )
    try {
        Start-Transcript -LiteralPath $Path -Append:$Append -Force | Out-Null
        $Script:DevConfigLogPath = $Path
    } catch {
        Write-Verbose "Could not start the log file: $($_.Exception.Message)"
        $Script:DevConfigLogPath = $null
    }
}

function Stop-DevConfigLog {
    if (-not $Script:DevConfigLogPath) {
        return
    }
    try {
        Stop-Transcript | Out-Null
    } catch {
        Write-Verbose "Could not stop the log file: $($_.Exception.Message)"
    }
}

function Get-DevConfigLogPath {
    return $Script:DevConfigLogPath
}

function Wait-DevConfigKeyPress {
    param(
        [string] $Message = 'Press any key to close this window...',
        [int] $TimeoutSeconds = 900
    )

    Write-Host ''
    $minutes = [Math]::Round($TimeoutSeconds / 60)
    Write-Host "$Message (closes on its own in $minutes minutes if you step away)" -ForegroundColor DarkGray

    # Polls instead of a blocking ReadKey so an unattended window still closes eventually.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                [void][Console]::ReadKey($true)
                return
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        # No real console attached (e.g. input redirected) -- nothing to wait on.
    }
}
