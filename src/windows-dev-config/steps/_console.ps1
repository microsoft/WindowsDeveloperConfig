<#
.SYNOPSIS
  Shared console helpers for run logging and the optional end-of-run pause.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigLogPath = $null

# Logging starts only in the worker process so relaunches do not write to the same transcript.
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

    # Polling allows unattended windows to close without waiting for a key press.
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
        # Input may be redirected, leaving no console to read from.
    }
}
