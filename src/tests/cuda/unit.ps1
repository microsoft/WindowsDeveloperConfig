$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$ready = Get-CudaReadiness -ToolkitAvailable $true -NvidiaGpuPresent $true -DriverAvailable $true
Assert-Equal $ready.Status 'Ready' 'Toolkit and driver/GPU should be ready'
Assert-True $ready.GpuReady 'GPU readiness should be true'

$toolkitOnly = Get-CudaReadiness -ToolkitAvailable $true -NvidiaGpuPresent $false -DriverAvailable $false
Assert-Equal $toolkitOnly.Status 'ToolkitOnlyNoGpu' 'Toolkit-only state should be distinct'
Assert-True (-not $toolkitOnly.GpuReady) 'Toolkit-only should not report GPU readiness'
$toolkitOnlyRepeat = Get-CudaReadiness -ToolkitAvailable $true -NvidiaGpuPresent $false -DriverAvailable $false
Assert-Equal ($toolkitOnlyRepeat | ConvertTo-Json -Compress) ($toolkitOnly | ConvertTo-Json -Compress) 'CUDA readiness should be idempotent'

Assert-ThrowsLike {
    Assert-DevConfigArchitecture -Architecture 'Arm64' -Supported @('X64') -Component 'CUDA'
} '*does not publish a compatible Windows artifact*' 'CUDA must reject ARM64 before installation'

Write-Host "UNIT_OK: cuda ($script:AssertionCount assertions)"
