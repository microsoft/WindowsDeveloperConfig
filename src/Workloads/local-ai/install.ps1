<#
.SYNOPSIS
  Prepare the major dependencies for a runnable local AI development scenario.

.DESCRIPTION
  Detects hardware, installs a contained PyTorch backend, runs tensor and neural
  model acceptance, and optionally installs one local model runtime. It does not
  install every vendor SDK or every model runtime.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $Backend = 'Auto',
    [ValidateSet('None', 'LlamaCpp', 'Ollama', 'Foundry')] [string] $Runtime = 'None',
    [switch] $RequireTriton,
    [switch] $PlanOnly,
    [string] $ReportRoot = (Join-Path $env:LOCALAPPDATA 'DevConfig\reports\local-ai')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null

& (Join-Path $PSScriptRoot '..\_common\collect-ai-hardware.ps1') `
    -OutputPath (Join-Path $ReportRoot 'hardware.json')

$pytorchReportPath = Join-Path $ReportRoot 'pytorch.json'
$pytorchArguments = @{
    Backend = $Backend
    ReportPath = $pytorchReportPath
}
if ($RequireTriton) { $pytorchArguments.RequireTriton = $true }
if ($PlanOnly) { $pytorchArguments.PlanOnly = $true }
& (Join-Path $sourceRoot 'Workloads\pytorch\install.ps1') @pytorchArguments
$pytorchReport = Get-Content -LiteralPath $pytorchReportPath -Raw | ConvertFrom-Json
if ($pytorchReport.result.blockers.Count -gt 0) {
    Write-Host "LOCAL_AI_SCENARIO_UNSUPPORTED: $($pytorchReport.result.blockers -join '; ')"
    return
}
if (-not $PlanOnly -and -not $pytorchReport.result.ready) {
    throw 'The PyTorch scenario step did not report result.ready=true.'
}

if ($Runtime -ne 'None') {
    $runtimePath = switch ($Runtime) {
        'LlamaCpp' { Join-Path $sourceRoot 'Workloads\llama.cpp\install.ps1' }
        'Ollama' { Join-Path $sourceRoot 'Workloads\ollama\install.ps1' }
        'Foundry' { Join-Path $sourceRoot 'Workloads\foundry\install.ps1' }
    }
    $runtimeReportPath = Join-Path $ReportRoot "$($Runtime.ToLowerInvariant()).json"
    $runtimeArguments = @{ ReportPath = $runtimeReportPath }
    if ($PlanOnly) { $runtimeArguments.PlanOnly = $true }
    & $runtimePath @runtimeArguments
    $runtimeReport = Get-Content -LiteralPath $runtimeReportPath -Raw | ConvertFrom-Json
    if ($runtimeReport.result.blockers.Count -gt 0) {
        Write-Host "LOCAL_AI_SCENARIO_UNSUPPORTED: $($runtimeReport.result.blockers -join '; ')"
        return
    }
    if (-not $PlanOnly -and -not $runtimeReport.result.ready) {
        throw "The $Runtime scenario step did not report result.ready=true."
    }
}

if ($PlanOnly) {
    Write-Host "LOCAL_AI_SCENARIO_PLAN_OK: backend=$Backend, runtime=$Runtime, reports=$ReportRoot"
} else {
    Write-Host "LOCAL_AI_SCENARIO_READY: backend=$Backend, runtime=$Runtime, reports=$ReportRoot"
}
