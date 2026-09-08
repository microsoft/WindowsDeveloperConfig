<#
.SYNOPSIS
  Install the NVIDIA CUDA Toolkit and compile/execute a minimal GPU kernel.

.PARAMETER ToolkitOnly
  Permit installing/verifying nvcc when no usable NVIDIA GPU and driver are
  present. By default the flow fails before installation when no NVIDIA GPU is
  detected and fails after installation when nvidia-smi is not usable.

.PARAMETER SkipWorkloadSmoke
  Skip compiling and executing the CUDA kernel. The default proves that the
  compiler, host toolchain, driver, and GPU work together.
#>
[CmdletBinding()]
param(
    [switch] $ToolkitOnly,
    [switch] $SkipWorkloadSmoke
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-CudaInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)

$gpu = Get-NvidiaGpu
if (-not $gpu -and -not $ToolkitOnly) {
    throw "No NVIDIA GPU was detected. CUDA Toolkit can be installed without a GPU only with -ToolkitOnly; GPU execution requires supported NVIDIA hardware and a current driver."
}

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id 'cuda' `
    -ConfigFile (Join-Path $PSScriptRoot $plan.ConfigurationName) `
    -RequireCommands @() `
    -DeferSentinel

if ($plan.Method -eq 'NvidiaInstaller') {
    $installed = $false
    try {
        $existingNvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
        $installedVersion = (& $existingNvcc --version 2>&1 | Out-String)
        $installed = $LASTEXITCODE -eq 0 -and $installedVersion -match 'release 13\.4'
    } catch {
        $installed = $false
    }
    if (-not $installed) {
        Write-Host 'Installing NVIDIA CUDA Toolkit 13.4 Developer Preview for Windows ARM64 (approximately 3.8 GB).'
        Invoke-VerifiedInstaller `
            -Uri $plan.InstallerUrl `
            -Sha256 $plan.InstallerSha256 `
            -SignerPattern 'NVIDIA' `
            -ArgumentList @('-s') `
            -SuccessExitCodes @(0, 3010)
    }
}

$nvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
Invoke-CheckedCommand -FilePath $nvcc -ArgumentList @('--version') -DisplayName 'CUDA compiler verification'
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

if ($SkipWorkloadSmoke -or -not $readiness.GpuReady) {
    Write-Warning 'CUDA_WORKLOAD_SMOKE_SKIPPED: the toolkit is installed, but a compiled GPU kernel was not executed.'
} else {
    $vsDevCmd = Get-VsDevCmdPath -Architecture $architecture
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-cuda-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        $executable = Join-Path $temporary 'cuda-smoke.exe'
        $compileCommand = Get-CudaKernelCompileCommand `
            -Architecture $architecture `
            -VsDevCmd $vsDevCmd `
            -Nvcc $nvcc `
            -Source (Join-Path $PSScriptRoot 'smoke.cu') `
            -Output $executable
        & $env:ComSpec /d /s /c $compileCommand
        if ($LASTEXITCODE -ne 0) {
            throw "CUDA smoke kernel compilation failed with exit code $LASTEXITCODE."
        }
        $output = (& $executable 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $output -ne 'CUDA_KERNEL_READY') {
            throw "CUDA smoke kernel failed on the GPU (exit $LASTEXITCODE, output '$output')."
        }
        Write-Host 'CUDA_WORKLOAD_READY: compiled and executed a CUDA kernel on the detected GPU.'
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

if ($plan.Preview) {
    Write-Warning 'CUDA 13.4 for Windows ARM64 is an NVIDIA Developer Preview and is not intended for production certification or benchmarking.'
}
Write-Host 'INSTALL_OK: cuda'
