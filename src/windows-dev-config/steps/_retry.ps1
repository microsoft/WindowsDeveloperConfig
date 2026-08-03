<#
.SYNOPSIS
  Retries a script block with exponential backoff, for flaky network calls.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-DevConfigRetry {
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $Name = 'operation',
        [int] $MaxAttempts = 3,
        [int] $InitialDelaySeconds = 5
    )
    $attempt = 0
    $delay = $InitialDelaySeconds
    while ($true) {
        $attempt++
        try {
            & $ScriptBlock
            return
        } catch {
            # A step that had to be stopped for running too long already had its full allowance, so
            # trying it a second time only spends that allowance again before reaching the same
            # fallback. Give up on it immediately and let the caller take the other route.
            if ($_.Exception -is [System.TimeoutException]) {
                throw
            }
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            # Write-Host, not Write-Warning: the warning stream becomes stderr once this process is
            # relaunched with redirected output after the reboot, and would then only surface at the
            # very end, in red, long after the retry it describes.
            Write-Host "  ... $Name didn't take on attempt $attempt ($($_.Exception.Message)). Trying again in ${delay}s." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
    }
}
