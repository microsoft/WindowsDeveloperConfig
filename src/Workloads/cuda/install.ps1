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
    [switch] $SkipWorkloadSmoke,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$catalog = (Get-AiCatalog).Components
$component = if ($architecture -eq 'Arm64') { $catalog.CudaArm64 } else { $catalog.CudaX64 }
$report = New-AiWorkloadReport -Id 'cuda' -Request @{
    ToolkitOnly = [bool]$ToolkitOnly
    SkipWorkloadSmoke = [bool]$SkipWorkloadSmoke
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'cuda' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
try {
    $plan = Resolve-CudaInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
} catch {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($_.Exception.Message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: cuda'
        return
    }
    throw
}
if (-not $PlanOnly) { Assert-AiAdministrator }

$gpu = Get-NvidiaGpu
if (-not $gpu -and -not $ToolkitOnly) {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add('No NVIDIA GPU detected; default kernel acceptance would fail. Use -ToolkitOnly for compiler-only planning.')
    } else {
    throw "No NVIDIA GPU was detected. CUDA Toolkit can be installed without a GPU only with -ToolkitOnly; GPU execution requires supported NVIDIA hardware and a current driver."
    }
}

Write-AiPhase -Name 'Plan' -Detail "$architecture / NVIDIA CUDA $($plan.ToolkitVersion)"
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $component.Vendor
    architecture = $architecture
    maturity = $component.Maturity
    sourceType = $component.SourceType
    packageId = Get-AiCatalogValue -Entry $component -Name 'PackageId'
    version = Get-AiCatalogValue -Entry $component -Name 'Version'
    uri = Get-AiCatalogValue -Entry $component -Name 'Uri'
    sha256 = Get-AiCatalogValue -Entry $component -Name 'Sha256'
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = $component.InstallPath
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = if ($PlanOnly) { 'planned' } else { 'pending' }
})

$toolchain = Ensure-AiVisualCppTools -Architecture $architecture -PlanOnly:$PlanOnly
Add-AiReportPhase -Report $report -Name 'host-compiler' -Status $(if ($PlanOnly) { 'planned' } else { 'ready' }) -Evidence $toolchain

$cudaAcquisition = Ensure-AiCudaToolkit -Architecture $architecture -PlanOnly:$PlanOnly
$report.acquisitions[0].action = $cudaAcquisition.Action
if (-not $PlanOnly -and $architecture -eq 'X64') {
    $report.acquisitions[0].packageEvidence = $cudaAcquisition.PackageEvidence
}
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'cuda-kernel' -Status 'planned' -Evidence @{
        source = (Join-Path $PSScriptRoot 'smoke.cu')
        target = 'detected NVIDIA GPU'
    }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host $(if ($report.result.blockers.Count) { 'PLAN_UNSUPPORTED: cuda' } else { 'PLAN_OK: cuda' })
    return
}

$nvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
Invoke-CheckedCommand -FilePath $nvcc -ArgumentList @('--version') -DisplayName 'CUDA compiler verification'
$nvccVersionEvidence = (& $nvcc --version 2>&1 | Out-String).Trim()
if ($nvccVersionEvidence -match 'release\s+([0-9]+\.[0-9]+)') {
    $report.acquisitions[0].version = $Matches[1]
}
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

$kernelReady = $false
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
        $kernelReady = $true
        $report.acceptance.kernel = [ordered]@{
            compiled = $true
            executed = $true
            marker = 'CUDA_KERNEL_READY'
            device = $driver.Name
            computeCapability = $driver.ComputeCapability.ToString()
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

if ($plan.Preview) {
    Write-Warning 'CUDA 13.4 for Windows ARM64 is an NVIDIA Developer Preview and is not intended for production certification or benchmarking.'
}
Add-AiReportPhase -Report $report -Name 'cuda-toolkit' -Status 'ready' -Evidence @{
    nvcc = $nvcc
    nvccVersion = $nvccVersionEvidence
    driver = $driver
}
Complete-AiWorkloadReport -Report $report -Ready $kernelReady -Path $ReportPath
Write-Host 'INSTALL_OK: cuda'
