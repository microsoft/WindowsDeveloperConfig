<#
.SYNOPSIS
  Post-reboot scheduled-task entry point: runs the orchestrator with output both shown live
  on screen and mirrored to a log file, without masking the real exit code.
#>

param(
    [Parameter(Mandatory)] [string] $ScriptPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '_elevation.ps1')

$logDir    = Split-Path -Path $ScriptPath -Parent
$masterLog = Join-Path $logDir 'resume-output.log'
$innerOut  = Join-Path $logDir 'resume-inner-stdout.log'
$innerErr  = Join-Path $logDir 'resume-inner-stderr.log'
Remove-Item $masterLog, $innerOut, $innerErr -ErrorAction SilentlyContinue

$shell = Get-DevConfigShellExe
$proc = Start-Process -FilePath $shell `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-NoElevate') `
    -RedirectStandardOutput $innerOut -RedirectStandardError $innerErr -NoNewWindow -PassThru

# Tee: mirror new lines to the console (visible on screen) and one combined log file.
$shown = 0
function Show-DevConfigResumeNewLines {
    # @() forces array semantics; Get-Content returns a bare string for single-line files.
    $lines = @(Get-Content -Path $innerOut -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $script:shown) {
        $lines[$script:shown..($lines.Count - 1)] | ForEach-Object {
            Write-Host $_
            Add-Content -Path $masterLog -Value $_
        }
        $script:shown = $lines.Count
    }
}

while (-not $proc.HasExited) {
    Show-DevConfigResumeNewLines
    Start-Sleep -Milliseconds 300
}
Show-DevConfigResumeNewLines

# Errors are terminal, so showing them last matches when they actually happened.
if (Test-Path -LiteralPath $innerErr) {
    Get-Content -Path $innerErr | ForEach-Object {
        Write-Host $_ -ForegroundColor Red
        Add-Content -Path $masterLog -Value $_
    }
}

exit $proc.ExitCode
