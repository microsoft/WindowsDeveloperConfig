<#
.SYNOPSIS
  Install Foundry Local, acquire a small catalog model, and run text inference.

.PARAMETER SkipModelSmoke
  Skip the default qwen3-0.6b download and inference. The install then verifies
  only the CLI and server and does not claim workload readiness.
#>
[CmdletBinding()]
param([switch] $SkipModelSmoke)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-FoundryInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
Write-Host "Foundry Local plan: $($plan.Architecture), WinML, CUDA dependency: $($plan.RequiresCuda)"

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id 'foundry' `
    -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('foundry') `
    -DeferSentinel

Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('--version') -DisplayName 'Foundry Local CLI verification'
& foundry server status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Foundry Local server is not ready; restarting it once.'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'restart') -DisplayName 'Foundry Local server restart'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'status') -DisplayName 'Foundry Local server readiness'
}

$modelPlan = Get-FoundryModelSmokePlan
if ($SkipModelSmoke) {
    Write-Warning 'FOUNDRY_MODEL_SMOKE_SKIPPED: CLI and server are ready, but no model inference was performed.'
} else {
    $commands = Get-FoundryModelSmokeCommands -Model $modelPlan.Model -Marker $modelPlan.Marker
    Write-Host "Downloading Foundry catalog model $($modelPlan.Model) (approximately $($modelPlan.ApproximateDownloadMb) MB, $($modelPlan.License))."
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList $commands.Download -DisplayName 'Foundry Local model download'
    $modelInfo = (& foundry model info $modelPlan.Model 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $modelInfo) {
        throw "Foundry Local could not report the selected $($modelPlan.Model) hardware variant."
    }
    Write-Host $modelInfo
    $completeArguments = @($commands.Complete)
    $completion = (& foundry @completeArguments 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $completion -notmatch [regex]::Escape($modelPlan.Marker)) {
        throw "Foundry Local model inference did not produce marker '$($modelPlan.Marker)'. Output: $completion"
    }
    $cache = (& foundry cache location 2>&1 | Out-String).Trim()
    Write-Host "FOUNDRY_READY: $($modelPlan.Model) downloaded to '$cache' and generated the deterministic marker using the selected hardware variant."
}
Write-Host 'INSTALL_OK: foundry'
