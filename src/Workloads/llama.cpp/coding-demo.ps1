<#
.SYNOPSIS
  Run an optional coding demonstration with a pinned 1.5B Qwen coder model.

.DESCRIPTION
  This is intentionally separate from install.ps1. The default llama.cpp
  validation model is about 397 MB; this optional coding model is about 1.04 GB.
#>
[CmdletBinding()]
param([string] $ReportPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$runtime = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\runtime'
$llamaCli = Join-Path $runtime 'llama-cli.exe'
$statePath = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\selected-backend.json'
if (-not (Test-Path -LiteralPath $llamaCli) -or -not (Test-Path -LiteralPath $statePath)) {
    throw 'Run llama.cpp\install.ps1 before the optional coding demonstration.'
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$plan = Get-LlamaCodingDemoPlan
$prompt = 'Write only valid Python code defining group_anagrams(words: list[str]) -> list[list[str]].'
$modelDirectory = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\models'
$modelPath = Join-Path $modelDirectory $plan.FileName

Install-VerifiedDownload `
    -Uri $plan.Url `
    -Destination $modelPath `
    -Sha256 $plan.Sha256 `
    -ExpectedSize $plan.Size

$arguments = @(
    '--model', $modelPath,
    '--single-turn',
    '--prompt', $prompt,
    '--reasoning', 'off',
    '--seed', '42',
    '--temperature', '0.2',
    '--top-p', '0.8',
    '--top-k', '20',
    '--predict', '384',
    '--no-display-prompt',
    '--simple-io',
    '--log-disable',
    '-ngl', $(if ($state.backend -eq 'CPU') { '0' } else { '999' })
)
if ($state.backend -eq 'CPU') {
    $arguments += @('--device', 'none')
} elseif ($state.requestedDevice) {
    $arguments += @('--device', [string]$state.requestedDevice)
}

$result = Invoke-AiNativeCommandSeparated `
    -FilePath $llamaCli `
    -Arguments $arguments `
    -TimeoutSeconds 1800
$output = $result.StandardOutput.Trim()
if ($result.ExitCode -ne 0 -or $output -notmatch '(?m)^\s*(?:```python\s*)?def\s+group_anagrams\s*\(') {
    throw "Coding model did not return the requested Python function. Output: $output"
}

if ($ReportPath) {
    $report = New-AiWorkloadReport -Id 'llama.cpp-coding-demo' -Request @{
        Prompt = $prompt
        Backend = $state.backend
        RequestedDevice = $state.requestedDevice
    }
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = 'Qwen2.5-Coder-1.5B-Instruct GGUF'
        vendor = 'Qwen'
        maturity = 'stable-model'
        sourceType = 'huggingface-immutable-revision'
        repository = $plan.Repository
        revision = $plan.Revision
        file = $plan.FileName
        sha256 = $plan.Sha256
        bytes = $plan.Size
        cachePath = $modelPath
        action = 'already-current-or-downloaded'
    })
    $report.acceptance.coding = [ordered]@{
        backend = $state.backend
        expectedDevice = $state.expectedDevice
        model = $plan.FileName
        outputContainsFunction = $true
        output = $output
    }
    Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
}

Write-Host $output
Write-Host "CODING_DEMO_READY: model=$($plan.FileName), backend=$($state.backend)"
