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

Write-Host "UNIT_OK: foundry ($script:AssertionCount assertions)"
