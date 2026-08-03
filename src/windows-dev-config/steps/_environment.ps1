<#
.SYNOPSIS
  Process-level environment fixes: refreshing PATH so tools installed earlier in the same run become
  runnable, raising TLS so every download in the run can reach a modern HTTPS endpoint, running
  native commands safely, and reading and writing text files without corrupting them.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Update-DevConfigSessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    # A machine with no per-user PATH is normal; joining it in blind would leave a stray separator.
    $env:Path    = (@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

# Windows PowerShell 5.1 turns any native command that writes to stderr into a terminating
# NativeCommandError once its output is merged with 2>&1, and PowerShell 7 can be configured to treat
# a non-zero exit code the same way. Both fire before the exit code can be read, which is the one
# signal that is actually stable across tool versions and locales. Preference variables assigned here
# are function-scoped, so they shadow the caller's values only for the duration of the call.
function Invoke-DevConfigNativeCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @()
    )
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false

    $output = & $FilePath @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

# Some of the installers this script drives -- wsl --install above all -- can block forever: they
# reach out to the Store, or raise a window on a desktop nobody is watching, and Start-Process -Wait
# has no way to give up. A run that sits on one line for an hour is worse than one that fails, so the
# wait is bounded and the process is stopped when it overruns; callers treat that as "try another way".
# The heartbeat exists because these are the longest steps in the run, and silence reads as a freeze.
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
    # Touching Handle caches it while the process is alive. Without that, Windows PowerShell releases
    # the handle on exit and ExitCode reads back as nothing at all, so every caller here would decide
    # a perfectly successful install had failed.
    try { $null = $process.Handle } catch { Write-Verbose "Could not hold a handle on $FilePath." }
    $startedAt = Get-Date
    $deadline  = $startedAt.AddSeconds($TimeoutSeconds)
    $nextBeat  = $startedAt.AddSeconds(60)
    while (-not $process.HasExited) {
        $now = Get-Date
        if ($now -ge $deadline) {
            try { $process.Kill() } catch { Write-Verbose "Could not stop $FilePath : $($_.Exception.Message)" }
            $minutes = [Math]::Round($TimeoutSeconds / 60)
            # A TimeoutException rather than a plain string: this is the one failure that must not be
            # retried, and the retry helper decides that by type rather than by matching on wording.
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

# Windows PowerShell 5.1 on older Windows still negotiates TLS 1.0 by default, which the PowerShell
# Gallery, GitHub releases and githubassets all refuse -- and they refuse it as a connection failure,
# so it surfaces as "the network is down" rather than anything actionable. Raised once for the whole
# process so every download in the run benefits, not just the first one that thought to ask.
function Enable-DevConfigModernTls {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
    }
}

# Every file this script edits -- settings.json, the PowerShell profile -- is UTF-8 without a BOM,
# and is read here only to be written back. Get-Content on Windows PowerShell 5.1 decodes such a file
# using the system ANSI code page, so a profile name, font face or comment holding any non-ASCII
# character comes back as mojibake and is then saved that way, permanently damaging the user's file.
# ReadAllText honours a BOM when there is one and falls back to UTF-8, which is right on both editions.
# $null for a missing file matches Get-Content -Raw, so callers keep their existing "nothing yet" test.
function Read-DevConfigTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

# The write half of the same story, plus atomicity. Set-Content truncates before writing, so an
# interruption mid-write leaves a zero-byte file and the reading app silently falls back to its
# defaults; writing beside the target and renaming means the file is only ever whole. -Encoding UTF8
# is inconsistent across editions too: 5.1 emits a BOM, 7 does not, and Windows Terminal wants none.
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
