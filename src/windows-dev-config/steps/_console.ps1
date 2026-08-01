<#
.SYNOPSIS
  Small shared console helper used at the very end of a run, so a window nobody is
  watching doesn't just vanish the moment the last line prints.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
