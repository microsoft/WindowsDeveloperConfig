<#
.SYNOPSIS
  Invoke the signed-package-compatible AI hardware inventory helper.
#>
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path $env:LOCALAPPDATA 'DevConfig\reports\hardware-latest.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot '..\Workloads\_common\collect-ai-hardware.ps1') `
    -OutputPath $OutputPath
