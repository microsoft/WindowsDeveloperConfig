<#
.SYNOPSIS
  Apply the TypeScript winget DSC configuration on Windows.

.DESCRIPTION
  This script is a thin CI/dev shim. The core artifact for the TypeScript flow
  is `configuration.winget` in this directory - a winget DSC configuration
  that declaratively installs Node.js LTS and, via a PSDscResources/Script
  resource, globally installs the TypeScript compiler.

  The shim exists only to:
    * apply the DSC config with retry (hosted-runner networks are flaky),
    * rehydrate PATH in the current session so later CI steps see new tools,
    * verify the expected commands resolve, and
    * emit `INSTALL_OK: typescript` for the test harness.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'typescript' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('node', 'npm', 'tsc')
