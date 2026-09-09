<#
.SYNOPSIS
  Emit a portable JSON hardware inventory for AI workload planning.
#>
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path $env:LOCALAPPDATA 'DevConfig\reports\hardware-latest.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\Workloads\_common\ai-support.ps1')
. (Join-Path $PSScriptRoot '..\Workloads\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\Workloads\_common\ai-report.ps1')

$report = New-AiWorkloadReport -Id 'hardware-inventory' -Request @{ PlanOnly = $true }
$report.result.ready = $true
$report.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
Write-DevConfigTextFile -Path $OutputPath -Content ($report | ConvertTo-Json -Depth 20)
Write-Host "AI_HARDWARE_REPORT: $OutputPath"
