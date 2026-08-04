<#
.SYNOPSIS
  Post-reboot scheduled-task entry point that shows output live and mirrors it to a log.
#>

param(
    [Parameter(Mandatory)] [string] $ScriptPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This wrapper sets UTF-8 output so relayed characters render consistently.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

. (Join-Path $PSScriptRoot '_elevation.ps1')
. (Join-Path $PSScriptRoot '_console.ps1')

$logDir    = Split-Path -Path $ScriptPath -Parent
$masterLog = Join-Path $logDir 'resume-output.log'
$innerOut  = Join-Path $logDir 'resume-inner-stdout.log'
$innerErr  = Join-Path $logDir 'resume-inner-stderr.log'
Remove-Item $masterLog, $innerOut, $innerErr -ErrorAction SilentlyContinue

$shell = Get-DevConfigShellExe
$proc = Start-Process -FilePath $shell `
    -ArgumentList (Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed) `
    -RedirectStandardOutput $innerOut -RedirectStandardError $innerErr -NoNewWindow -PassThru

# Mirroring new lines keeps resumed output visible while preserving one combined log.
$shown = 0
function Show-DevConfigResumeNewLines {
    # @() keeps single-line files from being treated as a scalar string.
    # UTF-8 matches the encoding used by the redirected child process output.
    $lines = @(Get-Content -Path $innerOut -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $script:shown) {
        $lines[$script:shown..($lines.Count - 1)] | ForEach-Object {
            Write-Host $_
            Add-Content -Path $masterLog -Value $_ -Encoding UTF8
        }
        $script:shown = $lines.Count
    }
}

while (-not $proc.HasExited) {
    Show-DevConfigResumeNewLines
    Start-Sleep -Milliseconds 300
}
Show-DevConfigResumeNewLines

# Errors are read after process exit, which preserves their terminal placement.
if (Test-Path -LiteralPath $innerErr) {
    Get-Content -Path $innerErr -Encoding UTF8 | ForEach-Object {
        Write-Host $_ -ForegroundColor Red
        Add-Content -Path $masterLog -Value $_ -Encoding UTF8
    }
}

# The post-reboot window owns the closing pause because it is the visible process.
Wait-DevConfigKeyPress

exit $proc.ExitCode
