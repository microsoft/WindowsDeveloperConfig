<#
.SYNOPSIS
  Apply the Ruby winget DSC configuration on Windows.

.DESCRIPTION
  This script is a thin CI/dev shim. The core artifact for the Ruby flow is
  `configuration.winget` in this directory — a winget DSC configuration that
  declaratively installs Ruby 3.4 with MSYS2 DevKit via winget.

  The shim exists only to:
    * apply the DSC config with retry (hosted-runner networks are flaky),
    * rehydrate PATH in the current session so later CI steps see `ruby` and `gem`,
    * verify those commands resolve, and
    * emit `INSTALL_OK: ruby` for the test harness.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'ruby' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('ruby', 'gem')
