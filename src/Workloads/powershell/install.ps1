<#
.SYNOPSIS
  Apply the PowerShell winget DSC configuration on Windows.

.DESCRIPTION
  This script is a thin CI/dev shim. The core artifact for the PowerShell flow
  is `configuration.winget` in this directory, which declaratively installs
  PowerShell 7, VS Code, PowerShell-focused VS Code extensions, and user-level
  PSScriptAnalyzer settings.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'powershell' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('pwsh', 'code')