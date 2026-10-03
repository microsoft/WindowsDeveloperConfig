<#
.SYNOPSIS
  Retries a script block with exponential backoff for transient failures.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-DevConfigRetry {
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $Name = 'operation',
        [int] $MaxAttempts = 3,
        [int] $InitialDelaySeconds = 5,
        [scriptblock] $ShouldRetry
    )
    $attempt = 0
    $delay = $InitialDelaySeconds
    while ($true) {
        $attempt++
        try {
            & $ScriptBlock
            return
        } catch {
            # Timeout exceptions already consumed their allowance, so callers handle the fallback path.
            if ($_.Exception -is [System.TimeoutException]) {
                throw
            }
            if ($ShouldRetry -and -not (& $ShouldRetry $_)) {
                throw
            }
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            # Write-Warning becomes redirected stderr after reboot and would appear after the retry.
            Write-Host "  ... $Name didn't take on attempt $attempt ($($_.Exception.Message)). Trying again in ${delay}s." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
    }
}

# Bootstrap carries this self-contained helper too, before shared files are available.
function Invoke-DevConfigWebRequest {
    param(
        [Parameter(Mandatory)] [hashtable] $Parameters
    )

    $waited = 0.0
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            return Invoke-WebRequest @Parameters -UseBasicParsing -ErrorAction Stop
        } catch {
            $response = $null
            $networkFailure = $false
            for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                if ($exception -is [Security.Authentication.AuthenticationException]) { throw }
                if ($exception.PSObject.Properties['Response'] -and $null -ne $exception.Response) {
                    $response = $exception.Response
                }
                if ($exception -is [Net.WebException]) {
                    $networkFailure = $exception.Status.ToString() -in @(
                        'Timeout', 'ConnectFailure', 'ConnectionClosed', 'KeepAliveFailure',
                        'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ReceiveFailure', 'SendFailure'
                    )
                } elseif ($exception.GetType().FullName -in @(
                    'System.Net.Http.HttpRequestException', 'System.Net.Http.HttpIOException',
                    'System.Threading.Tasks.TaskCanceledException', 'System.TimeoutException'
                )) {
                    $networkFailure = $true
                }
            }
            $status = if ($null -ne $response) { [int]$response.StatusCode } else { 0 }
            if ($attempt -eq 4 -or
                ($status -ne 0 -and $status -notin @(408, 429, 500, 502, 503, 504)) -or
                ($status -eq 0 -and -not $networkFailure)) {
                throw
            }

            $retryAfter = $null
            if ($null -ne $response) {
                if ($response.Headers -is [Net.WebHeaderCollection]) {
                    $retryAfter = $response.Headers['Retry-After']
                } elseif ($response.Headers.Contains('Retry-After')) {
                    $retryAfter = @($response.Headers.GetValues('Retry-After'))[0]
                }
            }
            $serverDelay = 0.0
            $date = [DateTimeOffset]::MinValue
            if ($retryAfter -match '^\d+$') {
                if (-not [double]::TryParse($retryAfter, [Globalization.NumberStyles]::None,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$serverDelay)) { throw }
            } elseif ($retryAfter -and [DateTimeOffset]::TryParse($retryAfter,
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
                $serverDelay = [Math]::Max(0, [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds))
            } elseif ($retryAfter) {
                Write-Verbose 'Ignoring an invalid Retry-After header.'
            }

            $backoff = 5 * [Math]::Pow(2, $attempt - 1)
            $delay = [Math]::Max($backoff, $serverDelay)
            $remaining = 120 - $waited
            if ($delay -gt $remaining) {
                Write-Host '  Download retry wait exceeds the remaining two-minute budget.' -ForegroundColor DarkYellow
                throw
            }
            $jitterMilliseconds = [int][Math]::Floor([Math]::Min($backoff, $remaining - $delay) * 1000)
            $milliseconds = [int]($delay * 1000) + (Get-Random -Minimum 0 -Maximum ($jitterMilliseconds + 1))
            Write-Host "  Download attempt $attempt failed; retrying in $([Math]::Round($milliseconds / 1000, 1))s." -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds $milliseconds
            $waited += $milliseconds / 1000
        }
    }
}
