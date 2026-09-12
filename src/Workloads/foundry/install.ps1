<#
.SYNOPSIS
  Install Foundry Local, acquire a small catalog model, and run text inference.

.PARAMETER SkipModelSmoke
  Skip the default qwen3-0.6b download and inference. The install then verifies
  only the CLI and server and does not claim workload readiness.
#>
[CmdletBinding()]
param(
    [switch] $SkipModelSmoke,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$component = (Get-AiCatalog).Components.FoundryLocal
$report = New-AiWorkloadReport -Id 'foundry' -Request @{
    SkipModelSmoke = [bool]$SkipModelSmoke
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'foundry' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
try {
    $plan = Resolve-FoundryInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
} catch {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($_.Exception.Message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: foundry'
        return
    }
    throw
}
if (-not $PlanOnly) { Assert-AiAdministrator }
Write-Host "Foundry Local plan: $($plan.Architecture), WinML, CUDA dependency: $($plan.RequiresCuda)"

$package = Ensure-AiWingetPackage -Id 'Microsoft.FoundryLocal' -PlanOnly:$PlanOnly
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $component.Vendor
    architecture = $architecture
    maturity = $component.Maturity
    sourceType = $component.SourceType
    packageId = $component.PackageId
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = $component.InstallPath
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = $package.Action
    packageEvidence = $(if ($PlanOnly) { $null } else { $package.Evidence })
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{
        model = 'qwen3-0.6b'
        selection = 'Foundry alias resolves the highest-priority hardware variant'
    }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: foundry'
    return
}

Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('--version') -DisplayName 'Foundry Local CLI verification'
$serverStatus = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('server', 'status')
if ($serverStatus.ExitCode -ne 0) {
    Write-Host 'Foundry Local server is not ready; restarting it once.'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'restart') -DisplayName 'Foundry Local server restart'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'status') -DisplayName 'Foundry Local server readiness'
}

$modelPlan = Get-FoundryModelSmokePlan
$inferenceEvidence = $null
if ($SkipModelSmoke) {
    Write-Warning 'FOUNDRY_MODEL_SMOKE_SKIPPED: CLI and server are ready, but no model inference was performed.'
} else {
    $commands = Get-FoundryModelSmokeCommands -Model $modelPlan.Model -Marker $modelPlan.Marker
    Write-Host "Downloading Foundry catalog model $($modelPlan.Model) (approximately $($modelPlan.ApproximateDownloadMb) MB, $($modelPlan.License))."
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList $commands.Download -DisplayName 'Foundry Local model download'
    $modelInfoResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('model', 'info', $modelPlan.Model)
    $modelInfo = $modelInfoResult.Output.Trim()
    if ($modelInfoResult.ExitCode -ne 0 -or -not $modelInfo) {
        throw "Foundry Local could not report the selected $($modelPlan.Model) hardware variant."
    }
    Write-Host $modelInfo
    $logsBeforeResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('server', 'logs', '-n', '200')
    if ($logsBeforeResult.ExitCode -ne 0) {
        throw "Foundry Local could not capture the pre-inference server log boundary: $($logsBeforeResult.Output)"
    }
    $completeArguments = @($commands.Complete)
    $completionResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments $completeArguments
    $completion = $completionResult.Output
    if ($completionResult.ExitCode -ne 0 -or $completion -notmatch [regex]::Escape($modelPlan.Marker)) {
        throw "Foundry Local model inference did not produce marker '$($modelPlan.Marker)'. Output: $completion"
    }
    $cacheResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('cache', 'location')
    if ($cacheResult.ExitCode -ne 0) {
        throw "Foundry Local cache location failed: $($cacheResult.Output)"
    }
    $cache = Get-AiWindowsPathFromOutput -Text $cacheResult.Output
    $logsResult = Invoke-DevConfigNativeCommand -FilePath 'foundry' -Arguments @('server', 'logs', '-n', '200')
    if ($logsResult.ExitCode -ne 0) {
        throw "Foundry Local could not capture post-inference provider evidence: $($logsResult.Output)"
    }
    $logs = $logsResult.Output.Trim()
    $currentInferenceLogs = Get-AiAppendedLogText -Before $logsBeforeResult.Output -After $logsResult.Output
    $providerEvidence = Get-FoundryExecutionProviderEvidence -ModelInfo $modelInfo -ServerLogs $currentInferenceLogs
    $report.acceptance.inference = [ordered]@{
        modelAlias = $modelPlan.Model
        modelInfo = $modelInfo
        marker = $modelPlan.Marker
        outputMatched = $true
        cache = $cache
        serverLogTail = $logs
        currentInferenceProviderLogs = $currentInferenceLogs
        selectedExecutionProvider = $providerEvidence.SelectedProvider
        selectedDevice = $providerEvidence.SelectedDevice
        observedExecutionProviders = $providerEvidence.ObservedProviders
        evidenceClass = 'resolved-variant-plus-successful-inference'
    }
    $inferenceEvidence = $report.acceptance.inference
    $report.result.fallbackUsed = $providerEvidence.CpuFallback
    Write-Host "FOUNDRY_READY: $($modelPlan.Model) downloaded to '$cache' and generated the deterministic marker using $($providerEvidence.SelectedProvider)."
}
Add-AiReportPhase -Report $report -Name 'foundry-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: foundry'
