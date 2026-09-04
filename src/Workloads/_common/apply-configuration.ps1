<#
.SYNOPSIS
  Apply a winget DSC configuration file with retry, refresh PATH in the current
  session, verify a list of expected commands, and emit the CI sentinel.

.DESCRIPTION
  Flow-level `install.ps1` files are thin shims: the real install logic lives
  in each flow's `configuration.winget`. This helper centralizes the glue
  that CI needs around `winget configure`:

    1. `winget configure --file <ConfigFile>` with exponential-backoff retry
       (shared helper; flaky network is common on hosted runners). Always
       passes `--accept-configuration-agreements` and `--disable-interactivity`.
       Note: `--accept-package-agreements` is NOT a valid flag on
       `winget configure` (only on `winget install`). Package-agreement
       consent for packages installed by DSC resources flows through
       `--accept-configuration-agreements`.
    2. Re-read machine+user PATH from the registry into `$env:Path` so the
       caller's *current* PowerShell session can see freshly installed
       executables (winget updates the registry but not running processes).
    3. Assert each command in `-RequireCommands` resolves on PATH.
    4. Print `INSTALL_OK: <Id>` as the final line; CI asserts on this.

.PARAMETER Id
  Flow id, only used in log prefixes and the final sentinel line.

.PARAMETER ConfigFile
  Path to the winget DSC YAML config for the flow.

.PARAMETER RequireCommands
  Commands that must resolve on PATH after configuration has been applied.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $Id,
    [Parameter(Mandatory)] [string]   $ConfigFile,
    # AllowEmptyCollection: Windows PowerShell 5.1 rejects empty arrays
    # bound to Mandatory parameters. Some flows (e.g. mac-comfort-shell)
    # have no post-install CLI to verify - the DSC only installs a font
    # and pwsh - so they legitimately pass @() here.
    [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RequireCommands,
    [switch] $DeferSentinel
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Fix #15: force UTF-8 on this process's console + external-program
# pipes. Windows PowerShell 5.1 defaults to the ANSI code page (1252 on
# en-US) for `[Console]::OutputEncoding`, which mangles winget's
# braille-pattern spinner glyphs into scrolling mojibake. winget writes
# UTF-8; matching it up front lets the carriage-return overwrites in
# the spinner work as intended and gives readable progress output.
# Safe no-op on pwsh 7 where UTF-8 is already the default.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    # Some hosts (e.g. certain CI agents with redirected stdout) reject
    # the assignment. Not worth failing the whole flow over cosmetics.
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

$common = Split-Path -Parent $PSCommandPath
. (Join-Path $common 'invoke-retry.ps1')

# Hard-fail fast if `winget configure` isn't available on this host. Every
# flow in this repo -- and the CmdPal extension that launches them -- uses
# `winget configure` as its only install path, so this is a stop-the-world
# prerequisite, not a warn-and-continue diagnostic.
#
# Fix #16: if the assert fails on first try, auto-invoke the canonical
# remediation (`enable-winget-configure.ps1`) once and then re-assert.
# The remediation runs `winget configure --enable` and installs
# Microsoft.VCRedist.2015+.x64, which covers the two failure modes a
# fresh VM actually hits. The remediation script itself self-elevates
# via UAC when needed; when we're already elevated (the install.ps1
# entry point in practice) it runs in-process and does not pause.
$assertScript = Join-Path $common 'assert-winget-configure.ps1'
$enableScript = Join-Path $common 'enable-winget-configure.ps1'
try {
    & $assertScript
}
catch {
    Write-Host ''
    Write-Host "--- winget configure not available; auto-remediating via $enableScript ---" -ForegroundColor Yellow
    Write-Host "    (reason: $($_.Exception.Message.Split([Environment]::NewLine)[0]))" -ForegroundColor DarkGray
    Write-Host ''
    & $enableScript
    # Re-assert; surface the original failure mode if remediation did
    # not actually fix it.
    & $assertScript
}

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    throw "DSC config file not found: $ConfigFile"
}

Write-Host "--- $Id flow: winget configure --file $ConfigFile ---"

Invoke-Retry -Name "winget configure $Id" -ScriptBlock {
    winget configure `
        --file $ConfigFile `
        --accept-configuration-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget configure failed with exit code $LASTEXITCODE"
    }
}

# winget updates the registry copy of PATH but not the PATH of this already
# running PowerShell process. Rehydrate so subsequent CI steps see new tools.
& (Join-Path $common 'refresh-path.ps1')

foreach ($cmd in $RequireCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "$cmd not found on PATH after applying $ConfigFile"
    }
    Write-Host "$cmd : $(& $cmd --version 2>&1 | Select-Object -First 1)"
}

if (-not $DeferSentinel) {
    Write-Host "INSTALL_OK: $Id"
}
