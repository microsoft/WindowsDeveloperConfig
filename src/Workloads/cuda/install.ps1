<#
.SYNOPSIS
  Install and verify the NVIDIA CUDA Toolkit on Windows x64.

.PARAMETER ToolkitOnly
  Permit installing/verifying nvcc when no usable NVIDIA GPU and driver are
  present. By default the flow fails before installation when no NVIDIA GPU is
  detected and fails after installation when nvidia-smi is not usable.
#>
[CmdletBinding()]
param([switch] $ToolkitOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
Assert-DevConfigArchitecture -Architecture $architecture -Supported @('X64') -Component 'NVIDIA CUDA Toolkit 13.3'

$gpu = Get-NvidiaGpu
if (-not $gpu -and -not $ToolkitOnly) {
    throw "No NVIDIA GPU was detected. CUDA Toolkit can be installed without a GPU only with -ToolkitOnly; GPU execution requires supported NVIDIA hardware and a current driver."
}

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id 'cuda' `
    -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('nvcc') `
    -DeferSentinel

Invoke-CheckedCommand -FilePath 'nvcc' -ArgumentList @('--version') -DisplayName 'CUDA compiler verification'
$driver = Get-NvidiaDriverInfo
$readiness = Get-CudaReadiness `
    -ToolkitAvailable $true `
    -NvidiaGpuPresent ([bool]$gpu) `
    -DriverAvailable ([bool]$driver)

Write-Host 'CUDA_TOOLKIT_READY: nvcc is installed and runnable.'
if ($readiness.GpuReady) {
    Write-Host "CUDA_GPU_READY: $($driver.Name), driver $($driver.DriverVersion), compute capability $($driver.ComputeCapability)."
} elseif ($ToolkitOnly) {
    Write-Warning "CUDA toolkit is ready, but GPU execution is not: $($readiness.Status). Install/update the NVIDIA driver and confirm 'nvidia-smi' succeeds."
} else {
    throw "CUDA Toolkit is installed, but no usable NVIDIA driver/GPU was reported by nvidia-smi. Update the NVIDIA driver, reboot if requested, and rerun this flow."
}

Write-Host 'INSTALL_OK: cuda'
