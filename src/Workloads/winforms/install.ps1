<#
.SYNOPSIS
  Apply the WinForms winget DSC configuration on Windows.

.DESCRIPTION
  This script is a thin CI/dev shim. The core artifact for the WinForms flow
  is `configuration.winget` in this directory - a winget DSC configuration
  that declaratively installs the .NET 10 SDK (which includes the Windows
  Desktop targeting pack used by `UseWindowsForms=true` projects).

  The shim exists only to:
    * apply the DSC config with retry (hosted-runner networks are flaky),
    * rehydrate PATH in the current session so later CI steps see `dotnet`,
    * verify `dotnet` resolves, and
    * emit `INSTALL_OK: winforms` for the test harness.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'winforms' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('dotnet')
