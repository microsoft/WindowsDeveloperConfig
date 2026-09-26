<#
.SYNOPSIS
  Shared helpers for PATH refresh, TLS, native process execution, and UTF-8 text I/O.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Update-DevConfigSessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    # A missing per-user PATH is normal, so empty values are filtered before joining.
    $env:Path    = (@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

# Normalize native failures to exit codes so callers are not tied to shell-specific error behavior.
function Invoke-DevConfigNativeCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [ValidateRange(0, 86400)] [int] $TimeoutSeconds = 0
    )
    $invoke = {
        param($FilePath, $Arguments)
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $FilePath @Arguments 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    if ($TimeoutSeconds -eq 0) {
        return & $invoke $FilePath $Arguments
    }

    $pipeline = [PowerShell]::Create().AddScript($invoke.ToString()).AddArgument($FilePath).AddArgument($Arguments)
    try {
        $pending = $pipeline.BeginInvoke()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $nextProgress = 60
        while (-not $pending.IsCompleted) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $pipeline.Stop()
                throw [TimeoutException]::new("The command timed out and was stopped: $FilePath $($Arguments -join ' ').")
            }
            if ($timer.Elapsed.TotalSeconds -ge $nextProgress) {
                Write-Host "  still working -- $([int]$timer.Elapsed.TotalMinutes)m so far" -ForegroundColor DarkGray
                $nextProgress += 60
            }
            Start-Sleep -Milliseconds 500
        }
        $result = $pipeline.EndInvoke($pending)
        # A command that cannot start fails inside the runspace, not here; surface it like the in-process path does.
        if ($pipeline.Streams.Error.Count -gt 0) {
            throw $pipeline.Streams.Error[0].Exception
        }
        return $result
    } finally {
        $pipeline.Dispose()
    }
}

function Invoke-DevConfigCleanupCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [int[]] $SuccessCodes = @(0),
        [switch] $Unelevated,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 900
    )
    $command = Get-Command $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $result = if ($Unelevated) {
        Invoke-DevConfigUnelevatedCommand -FilePath $command.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    } else {
        Invoke-DevConfigNativeCommand -FilePath $command.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    }
    if ($null -eq $result.ExitCode -or $result.ExitCode -notin $SuccessCodes) {
        throw "$FilePath $($Arguments -join ' ') failed ($($result.ExitCode)): $(([string]$result.Output).Trim())"
    }
    return $result
}

# Some installers can wait indefinitely, so process waits are bounded and emit periodic progress.
function Invoke-DevConfigProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [switch] $NoNewWindow,
        [string] $RedirectStandardOutput,
        [string] $RedirectStandardError
    )
    $start = @{ FilePath = $FilePath; PassThru = $true }
    if ($Arguments.Count)         { $start.ArgumentList           = $Arguments }
    if ($NoNewWindow)             { $start.NoNewWindow            = $true }
    if ($RedirectStandardOutput)  { $start.RedirectStandardOutput = $RedirectStandardOutput }
    if ($RedirectStandardError)   { $start.RedirectStandardError  = $RedirectStandardError }

    $process   = Start-Process @start
    # Cache the process handle before exit so Windows PowerShell can still report ExitCode.
    try { $null = $process.Handle } catch { Write-Verbose "Could not hold a handle on $FilePath." }
    $startedAt = Get-Date
    $deadline  = $startedAt.AddSeconds($TimeoutSeconds)
    $nextBeat  = $startedAt.AddSeconds(60)
    while (-not $process.HasExited) {
        $now = Get-Date
        if ($now -ge $deadline) {
            try { $process.Kill() } catch { Write-Verbose "Could not stop $FilePath : $($_.Exception.Message)" }
            $minutes = [Math]::Round($TimeoutSeconds / 60)
            # TimeoutException lets retry logic distinguish a bounded wait from retryable install failures.
            throw [System.TimeoutException]::new("$FilePath did not finish within $minutes minutes, so it was stopped.")
        }
        if ($now -ge $nextBeat) {
            Write-Host "  still working -- $([int]($now - $startedAt).TotalMinutes)m so far" -ForegroundColor DarkGray
            $nextBeat = $now.AddSeconds(60)
        }
        Start-Sleep -Milliseconds 500
    }
    $process.WaitForExit()
    return $process.ExitCode
}

# TLS 1.2 is enabled once so downloads work on Windows PowerShell 5.1 defaults.
function Enable-DevConfigModernTls {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
    }
}

# ReadAllText preserves UTF-8 files without relying on Windows PowerShell 5.1 ANSI decoding.
function Read-DevConfigTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

# Write through a UTF-8 no-BOM temp file to avoid truncation and edition-specific encoding behavior.
function Write-DevConfigTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = "$Path.new"
    [System.IO.File]::WriteAllText($temp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
