$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-report.ps1')

Assert-Equal (Get-AmdGfxTarget -GpuName 'AMD Radeon RX 9070 XT') 'gfx1201' 'RX 9070 XT should map to gfx1201'
Assert-Equal (Get-AmdGfxTarget -GpuName 'AMD Radeon RX 7900 XTX') 'gfx1100' 'RX 7900 XTX should map to gfx1100'
Assert-Equal (Get-AmdGfxTarget -GpuName 'AMD Radeon RX 7600') 'gfx1102' 'RX 7600 should map to gfx1102'
Assert-Equal (Get-AmdGfxTarget -GpuName 'AMD Radeon RX 7650 GRE') 'gfx1102' 'RX 7650 GRE should map to gfx1102'
Assert-Equal (Get-AmdGfxTarget -GpuName 'AMD Radeon 890M Graphics') 'gfx1150' 'Radeon 890M should map to its Ryzen AI gfx target'
Assert-Equal (Get-AmdGfxTarget -GpuName 'AMD Radeon 8060S Graphics') 'gfx1151' 'Radeon 8060S should map to its Ryzen AI Max gfx target'
Assert-Equal (Get-AmdGfxTarget -GpuName 'AMD Radeon(TM) 890M Graphics') 'gfx1150' 'Trademark tokens should not break Radeon 890M matching'
Assert-Equal (Select-AmdGpuName -GpuNames @('AMD Radeon Vega 8', 'AMD Radeon RX 9070 XT')) 'AMD Radeon RX 9070 XT' 'AMD selection should prefer a supported adapter regardless of enumeration order'
Assert-Equal (Get-AmdGfxTarget -GpuName 'Unsupported AMD GPU') $null 'Unsupported AMD GPU should not infer compatibility'
$plan = Resolve-RocmInstallPlan -Architecture X64 -GpuName 'AMD Radeon RX 9070 XT'
Assert-Equal $plan.Requirement 'rocm[libraries,devel,device-gfx1201]==10.0.0' 'ROCm plan should construct the exact device package'
Assert-ThrowsLike {
    Resolve-RocmInstallPlan -Architecture Arm64 -GpuName 'AMD Radeon RX 9070 XT'
} '*does not publish native Windows ARM64*' 'ROCm should reject ARM64'

$catalog = Get-AiCatalog
Assert-Equal $catalog.Components.AmdRocm.Architectures[0] 'X64' 'ROCm should be Windows x64 only'
Assert-Equal $catalog.Components.AmdRocm.Version '10.0.0' 'ROCm should pin the production tuple'
Assert-True ($catalog.Components.AmdRocm.IndexUrl -like 'https://stable.repo.amd.com/*') 'ROCm should use the official stable AMD feed'

$wingetArgs = Get-DevConfigWingetInstallArguments -Id 'Python.Python.3.13'
Assert-Equal ($wingetArgs -join ' ') 'install --id Python.Python.3.13 --exact --source winget --silent --accept-package-agreements --accept-source-agreements' 'Direct package command should be exact and noninteractive'

$script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\rocm\install.ps1') -Raw
Assert-True ($script -match '\[switch\]\s*\$PlanOnly') 'ROCm should support portable plan mode'
Assert-True ($script -match 'hip-smoke\.cpp') 'ROCm should compile a real HIP kernel'
Assert-True ($script -notmatch 'apply-configuration') 'ROCm should use direct acquisition'
Assert-True ($script -notmatch '''--only-binary=:all:'', ''--index-url'', \$component\.IndexUrl, \$requirement') 'ROCm should allow AMD source-only metapackage while its dependencies remain wheels'
Assert-True ($script -match 'rocm-sdk-device-\$gfx') 'ROCm rerun should verify the exact selected device package'
Assert-True ($script -match 'Test-PythonDistributionVersions') 'ROCm rerun should verify exact SDK package versions'
Assert-True ($script -match 'Ensure-AiVisualCppTools') 'ROCm should acquire the Windows host compiler and SDK'
Assert-True ($script -match 'Import-MsvcEnvironment') 'ROCm should initialize the host compiler environment before hipcc'

Write-Host "UNIT_OK: rocm ($script:AssertionCount assertions)"
