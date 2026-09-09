$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-report.ps1')

$catalog = Get-AiCatalog
Assert-Equal $catalog.Components.IntelOpenVino.Architectures[0] 'X64' 'OpenVINO flow should be native Windows x64 only'
Assert-Equal $catalog.Components.IntelOneApi.PackageId 'Intel.OneAPI.Toolkit' 'oneAPI should use the current unified WinGet package'
Assert-Equal $catalog.Components.IntelOneApi.Version '2026.0.0.193' 'oneAPI metadata should record the qualified stable version'
Assert-True ($catalog.Components.IntelOpenVino.Packages -contains 'openvino==2026.3.1') 'OpenVINO runtime should be exactly pinned'
$gpuPlan = Resolve-IntelAiPlan -Architecture X64 -Device Auto -Profile Full -IntelGpuPresent $true
Assert-Equal $gpuPlan.Device 'GPU' 'Intel Auto should select a detected GPU'
Assert-True $gpuPlan.InstallOpenVino 'Full profile should install OpenVINO'
Assert-True $gpuPlan.InstallOneApi 'Full profile should install oneAPI'
$npuPlan = Resolve-IntelAiPlan -Architecture X64 -Device Auto -Profile OpenVINO -IntelGpuPresent $true -IntelNpuPresent $true
Assert-Equal $npuPlan.Device 'NPU' 'Intel Auto should prefer an available NPU for OpenVINO'
Assert-ThrowsLike {
    Resolve-IntelAiPlan -Architecture Arm64 -Device Auto -Profile OpenVINO -IntelGpuPresent $false
} '*do not publish native Windows ARM64*' 'Intel AI should reject Windows ARM64'
Assert-ThrowsLike {
    Resolve-IntelAiPlan -Architecture X64 -Device GPU -Profile OpenVINO -IntelGpuPresent $false
} '*no Intel display adapter*' 'Explicit Intel GPU should fail without hardware'
Assert-ThrowsLike {
    Resolve-IntelAiPlan -Architecture X64 -Device NPU -Profile OpenVINO -IntelNpuPresent $false
} '*no Intel AI Boost/NPU*' 'Explicit Intel NPU should fail without hardware'

$script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\intel-ai\install.ps1') -Raw
Assert-True ($script -match "ValidateSet\('Auto', 'CPU', 'GPU', 'NPU'\)") 'Intel flow should expose explicit device selection'
Assert-True ($script -match "ValidateSet\('OpenVINO', 'SYCL', 'Full'\)") 'Intel flow should expose runtime/toolkit profiles'
Assert-True ($script -match '\[switch\]\s*\$PlanOnly') 'Intel flow should support portable plan mode'
Assert-True ($script -notmatch 'apply-configuration') 'Intel flow should use direct acquisition'
Assert-True ($script -match 'Test-PythonDistributionVersions') 'Intel flow should skip package work when exact OpenVINO versions are installed'

$openvino = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\intel-ai\openvino-smoke.py') -Raw
Assert-True ($openvino -match 'compile_model\(model, requested\)') 'OpenVINO acceptance should compile on the requested device'
Assert-True ($openvino -match 'FULL_DEVICE_NAME') 'OpenVINO report should identify the actual device'
$sycl = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\intel-ai\sycl-smoke.cpp') -Raw
Assert-True ($sycl -match 'gpu_selector_v') 'SYCL acceptance should require an Intel GPU instead of CPU fallback'
Assert-True ($sycl -match 'parallel_for') 'SYCL acceptance should execute a real kernel'

Write-Host "UNIT_OK: intel-ai ($script:AssertionCount assertions)"
