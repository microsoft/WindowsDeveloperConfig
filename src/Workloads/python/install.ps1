<#
.SYNOPSIS
  Apply the Python winget DSC configuration on Windows.

.DESCRIPTION
  This script is a thin CI/dev shim. The core artifact for the Python flow is
  `configuration.winget` in this directory - a winget DSC configuration that
  installs the Python install manager and uv via winget, then CPython 3.14
  through the install manager.

  The shim exists only to:
    * apply the DSC config with retry (hosted-runner networks are flaky),
    * rehydrate PATH in the current session so later CI steps see `python`,
      `pip`, and `uv`,
    * verify those commands resolve, and
    * emit `INSTALL_OK: python` for the test harness.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'python' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('python', 'pip', 'uv')
