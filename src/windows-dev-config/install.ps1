<#
.SYNOPSIS
  Apply the Windows Dev Config user-experience configuration on Windows.

.DESCRIPTION
  Thin CI/dev shim around `dev-config.winget`, a winget DSC configuration
  that sets up the full Windows Dev Config developer workstation (apps,
  distraction-free desktop, taskbar polish, Recall off, dark theme, WSL + Ubuntu).

  The shim only:
    * applies the DSC config with retry,
    * rehydrates PATH in the current session,
    * emits `INSTALL_OK: windows-dev-config` for the test harness.

  RequireCommands lists `git` because the master config installs it
  unconditionally; asserting it on PATH catches a clean-install failure
  early.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\Workloads\_common\apply-configuration.ps1') `
    -Id              'windows-dev-config' `
    -ConfigFile      (Join-Path $PSScriptRoot 'dev-config.winget') `
    -RequireCommands @('git')
