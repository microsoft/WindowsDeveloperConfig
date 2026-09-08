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

Write-Host "UNIT_OK: foundry ($script:AssertionCount assertions)"
