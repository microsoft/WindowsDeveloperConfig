<#
.SYNOPSIS
  Build + run a hello-world and diff its stdout against an expected file.

.DESCRIPTION
  Invoked by CI after a flow's install script has run. Keeps the "does the
  install actually produce a working toolchain?" question down to a single
  assertion per flow.

.PARAMETER Id
  Flow id, used only for log prefixes.

.PARAMETER Build
  Shell command to build the hello-world. Empty string skips the build step
  (useful for interpreted languages).

.PARAMETER Run
  Shell command whose stdout is compared against -Expected.

.PARAMETER Expected
  Path to a file containing the exact expected stdout.

.NOTES
  Commands run with the repository root as the working directory (the harness
  does not change it). Output comparison normalizes CRLF->LF and trims trailing
  whitespace on each line plus trailing blank lines.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Id,
    [Parameter()]          [string] $Build = '',
    [Parameter(Mandatory)] [string] $Run,
    [Parameter(Mandatory)] [string] $Expected
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Section {
    param([string] $Text)
    Write-Host ""
    Write-Host "==== [$Id] $Text ===="
}

function Normalize-Output {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r",   "`n"
    $lines = @($Text -split "`n")
    $lines = @($lines | ForEach-Object { $_.TrimEnd() })
    # Trim trailing blank lines.
    $i = $lines.Count - 1
    while ($i -ge 0 -and [string]::IsNullOrEmpty($lines[$i])) { $i-- }
    if ($i -lt 0) { return '' }
    return ($lines[0..$i] -join "`n")
}

function Invoke-Shell {
    param(
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string] $Label
    )
    Write-Host "> $Command"
    if ($IsWindows -or ($null -eq $IsWindows)) {
        # Windows PowerShell 5.1 doesn't define $IsWindows but is always Windows.
        $output = & cmd.exe /d /c $Command 2>&1 | Out-String
    } else {
        # Useful for local testing on non-Windows hosts.
        $output = & bash -c $Command 2>&1 | Out-String
    }
    $exit = $LASTEXITCODE
    Write-Host $output
    if ($exit -ne 0) {
        throw "$Label failed with exit code $exit"
    }
    return $output
}

if (-not (Test-Path -LiteralPath $Expected)) {
    throw "Expected-output file not found: $Expected"
}
$expectedText = Normalize-Output (Get-Content -LiteralPath $Expected -Raw)

if (-not [string]::IsNullOrWhiteSpace($Build)) {
    Write-Section 'build'
    [void](Invoke-Shell -Command $Build -Label 'build')
} else {
    Write-Section 'build (skipped)'
}

Write-Section 'run'
$runOutput = Invoke-Shell -Command $Run -Label 'run'
$actualText = Normalize-Output $runOutput

Write-Section 'assert'
if ($actualText -ceq $expectedText) {
    Write-Host "OK: stdout matches $Expected"
    Write-Host "FLOW_OK: $Id"
    exit 0
}

Write-Host '--- expected ---'
Write-Host $expectedText
Write-Host '--- actual ---'
Write-Host $actualText
Write-Host '--- end ---'
throw "Flow '$Id' stdout did not match expected output in $Expected"
