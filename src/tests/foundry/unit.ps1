$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

foreach ($architecture in @('X64', 'Arm64')) {
    $plan = Resolve-FoundryInstallPlan -Architecture $architecture -WindowsBuild 26100
    Assert-Equal $plan.Architecture $architecture "Foundry should preserve $architecture"
    Assert-Equal $plan.PackageId 'Microsoft.FoundryLocal' 'Foundry should use WinGet on both architectures'
    Assert-True (-not $plan.RequiresCuda) 'Foundry must not depend on CUDA'
}

Assert-ThrowsLike {
    Resolve-FoundryInstallPlan -Architecture 'X64' -WindowsBuild 22631
} '*requires Windows 11 24H2*' 'Foundry should reject older Windows builds'

$first = Resolve-FoundryInstallPlan -Architecture Arm64 -WindowsBuild 26100
$repeat = Resolve-FoundryInstallPlan -Architecture Arm64 -WindowsBuild 26100
Assert-Equal ($repeat | ConvertTo-Json -Compress) ($first | ConvertTo-Json -Compress) 'Foundry plan should be idempotent'

$model = Get-FoundryModelSmokePlan
Assert-Equal $model.Model 'qwen3-0.6b' 'Foundry should use the tested small catalog model'
Assert-Equal $model.ApproximateDownloadMb 593 'Foundry should document expected download size'
$commands = Get-FoundryModelSmokeCommands -Model $model.Model -Marker $model.Marker
Assert-Equal ($commands.Download -join ' ') 'model download qwen3-0.6b' 'Foundry download command should be deterministic'
Assert-True (($commands.Complete -join ' ') -like '*DEVCONFIG_FOUNDRY_READY*') 'Foundry completion should require a marker'
$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\foundry\install.ps1') -Raw
Assert-True ($installScript -match '\[switch\]\s*\$SkipModelSmoke') 'Foundry should expose model-smoke opt-out'
Assert-True ($installScript -match '\[switch\]\s*\$PlanOnly') 'Foundry should expose portable plan mode'
Assert-True ($installScript -match 'Ensure-AiWingetPackage') 'Foundry should use direct package acquisition'
Assert-True ($installScript -notmatch 'apply-configuration') 'Foundry should not use winget configure'
Assert-True ($installScript -match "'server', 'logs', '-n', '200'") 'Foundry report should retain execution-provider diagnostics'
Assert-True ($installScript -match '\$inferenceEvidence = \$null') 'Foundry model-smoke opt-out should use explicit skipped evidence'

$decoratedCache = "$([char]0x25A0) note: C:\Users\mihippel\.foundry\cache\models"
Assert-Equal (Get-AiWindowsPathFromOutput -Text $decoratedCache) 'C:\Users\mihippel\.foundry\cache\models' 'Decorated Foundry output should produce a clean absolute cache path'
$ansiCache = "$([char]27)[32mready$([char]27)[0m C:\Foundry Cache\models"
Assert-Equal (Get-AiWindowsPathFromOutput -Text $ansiCache) 'C:\Foundry Cache\models' 'ANSI decoration should be removed before parsing the cache path'
Assert-ThrowsLike {
    Get-AiWindowsPathFromOutput -Text 'cache unavailable'
} '*No absolute Windows path*' 'Foundry cache output without a path should fail actionably'
Assert-True ($installScript -match 'Invoke-DevConfigNativeCommand') 'Foundry output should use guarded UTF-8 native capture'

$cpuProviderEvidence = Get-FoundryExecutionProviderEvidence -ServerLogs @'
Failed to register WebGPUExecutionProvider
CUDAExecutionProvider dependency is unavailable
2026-09-10 [INF] Device: CPU,EPs: CPUExecutionProvider
'@
Assert-Equal $cpuProviderEvidence.SelectedProvider 'CPUExecutionProvider' 'Failed accelerator registrations should not hide the actual CPU provider'
Assert-True $cpuProviderEvidence.CpuFallback 'Foundry CPU provider should be reported as a truthful fallback'
$gpuProviderEvidence = Get-FoundryExecutionProviderEvidence -ServerLogs '2026-09-10 [INF] Device: GPU,EPs: DmlExecutionProvider'
Assert-Equal $gpuProviderEvidence.SelectedProvider 'DmlExecutionProvider' 'Foundry should retain a conclusive accelerator provider'
Assert-Equal $gpuProviderEvidence.SelectedDevice 'GPU' 'Foundry should retain the source-managed selected device'
Assert-True (-not $gpuProviderEvidence.CpuFallback) 'Accelerator provider should not be marked as CPU fallback'
Assert-ThrowsLike {
    Get-FoundryExecutionProviderEvidence -ServerLogs 'Available providers: DmlExecutionProvider, CPUExecutionProvider'
} '*neither the current inference logs nor the selected model variant*' 'Foundry readiness should reject provider availability lists without a selection event'
$cachedVariantEvidence = Get-FoundryExecutionProviderEvidence -ModelInfo @'
| Variant         | Model ID       | Device | Execution      | Size   | Cached |
|                 |                |        | Provider       |        |        |
|-----------------+----------------+--------+----------------+--------+--------|
| qwen3-0.6b-gene | qwen3-0.6b-gen | CPU    | CPUExecutionPr | 593 MB | yes    |
| ric-cpu         | eric-cpu:4     |        | ovider         |        |        |
+-----------------+----------------+--------+----------------+--------+--------+
'@
Assert-Equal $cachedVariantEvidence.SelectedProvider 'CPUExecutionProvider' 'Cached Foundry reruns should use the selected variant provider when no new server event is emitted'
Assert-Equal $cachedVariantEvidence.SelectedDevice 'CPU' 'Cached Foundry variant evidence should retain the selected device'
$logDelta = Get-AiAppendedLogText `
    -Before "old line`n2026-09-10 [INF] Device: CPU,EPs: CPUExecutionProvider" `
    -After "old line`n2026-09-10 [INF] Device: CPU,EPs: CPUExecutionProvider`n2026-09-10 [INF] Device: GPU,EPs: DmlExecutionProvider"
Assert-Equal $logDelta '2026-09-10 [INF] Device: GPU,EPs: DmlExecutionProvider' 'Foundry provider parsing should use only log lines appended by the current inference'

Write-Host "UNIT_OK: foundry ($script:AssertionCount assertions)"
