<#
.SYNOPSIS
  Apply the SQL winget DSC configuration on Windows.

.DESCRIPTION
  This script is a thin CI/dev shim. The core artifact for the SQL flow is
  `configuration.winget` in this directory - a winget DSC configuration that
  installs SQL Server Developer, sqlcmd, VS Code, and the SQL Database Projects
  extension without installing Visual Studio or SSDT.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id              'sql' `
    -ConfigFile      (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('sqlcmd', 'code')