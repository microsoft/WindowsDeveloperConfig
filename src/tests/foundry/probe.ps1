$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
    throw 'foundry was not found on PATH.'
}
& foundry --version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "foundry --version failed with exit code $LASTEXITCODE."
}
$plan = Get-FoundryModelSmokePlan
$commands = Get-FoundryModelSmokeCommands -Model $plan.Model -Marker $plan.Marker
$completeArguments = @($commands.Complete)
$output = (& foundry @completeArguments 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $output -notmatch [regex]::Escape($plan.Marker)) {
    throw "Foundry cached-model inference failed with exit code $LASTEXITCODE."
}

Write-Output 'Foundry Local ready'
