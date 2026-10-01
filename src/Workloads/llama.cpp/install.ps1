<#
.SYNOPSIS
  Install a hardware-selected llama.cpp backend, acquire a pinned small GGUF,
  and prove the selected backend with benchmark and inference evidence.

.PARAMETER Backend
  Auto prefers supported NVIDIA CUDA, AMD ROCm, Intel SYCL, Qualcomm Adreno
  OpenCL, x64 Vulkan, then CPU. OpenVINO is an explicit Windows x64 option.
  Explicit backend requests fail instead of silently selecting another backend.

.PARAMETER Device
  Optional llama.cpp runtime device identifier such as CUDA0, Vulkan0, or SYCL0.
  Use this to target a same-vendor secondary adapter. When omitted, the selected
  backend chooses its default device and the actual device is recorded.

.PARAMETER SkipModelSmoke
  Skip the default Qwen3-0.6B GGUF download and inference. The install then
  verifies only the CLI and does not claim workload readiness.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CUDA', 'ROCm', 'SYCL', 'OpenVINO', 'Vulkan', 'OpenCL', 'CPU')] [string] $Backend = 'Auto',
    [string] $Device = '',
    [switch] $SkipModelSmoke,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$driver = Get-NvidiaDriverInfo
$amdGpuName = Get-AmdGpuName
$amdGfxTarget = if ($amdGpuName) { Get-AmdGfxTarget -GpuName $amdGpuName } else { $null }
$intelGpuName = Get-IntelGpuName
$qualcommGpuName = Get-QualcommGpuName
$hasOpenCl = Test-AiOpenClRuntimeAvailable
$vulkanGpuName = Get-VulkanGpuName
$hasVulkan = Test-AiVulkanRuntimeAvailable -GpuName $vulkanGpuName
$component = (Get-AiCatalog).Components.LlamaCppRolling
$report = New-AiWorkloadReport -Id 'llama.cpp' -Request @{
    Backend = $Backend
    Device = $Device
    SkipModelSmoke = [bool]$SkipModelSmoke
    PlanOnly = [bool]$PlanOnly
    SelectedBackend = $null
    DetectedNvidiaDevice = $(if ($driver) { $driver.Name } else { $null })
    NvidiaDriverVersion = $(if ($driver) { $driver.DriverVersion.ToString() } else { $null })
    NvidiaComputeCapability = $(if ($driver) { $driver.ComputeCapability.ToString() } else { $null })
    DetectedAmdDevice = $amdGpuName
    DetectedIntelDevice = $intelGpuName
    DetectedQualcommDevice = $qualcommGpuName
    OpenClAvailable = $hasOpenCl
    VulkanAvailable = $hasVulkan
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'llama.cpp' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
try {
    $plan = Resolve-LlamaCppInstallPlan `
        -Architecture $architecture `
        -Backend $Backend `
        -HasNvidia ([bool]$driver) `
        -DriverVersion $(if ($driver) { $driver.DriverVersion } else { [version]'0.0' }) `
        -ComputeCapability $(if ($driver) { $driver.ComputeCapability } else { [version]'0.0' }) `
        -NvidiaGpuName $(if ($driver) { $driver.Name } else { $null }) `
        -AmdGpuName $amdGpuName `
        -AmdGfxTarget $amdGfxTarget `
        -IntelGpuName $intelGpuName `
        -QualcommGpuName $qualcommGpuName `
        -HasOpenCl $hasOpenCl `
        -HasVulkan $hasVulkan `
        -VulkanGpuName $vulkanGpuName
} catch {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($_.Exception.Message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: llama.cpp'
        return
    }
    throw
}
$report.request.SelectedBackend = $plan.Backend
$report.request.SelectedVendor = $plan.Vendor
$report.request.SelectedDevice = $plan.DeviceName
$report.request.SelectedRuntime = $plan.Runtime
$report.result.fallbackUsed = $Backend -eq 'Auto' -and $plan.Backend -in @('Vulkan', 'CPU')
if ($report.result.fallbackUsed) {
    [void]$report.result.warnings.Add("Auto selected the compatibility fallback '$($plan.Backend)'; this is not reported as vendor-native acceleration.")
}
if (-not $PlanOnly) { Assert-AiAdministrator }
$legacyDestination = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp'
$destination = Join-Path $legacyDestination 'runtime'
$assetCache = Join-Path $legacyDestination 'asset-cache'
if ($PlanOnly) {
    $acquisition = [pscustomobject]@{
        Action = 'resolve-rolling-release'
        Tag = $null
        Assets = @()
        Source = 'github'
        CacheDirectory = $assetCache
    }
} else {
    $acquisition = Install-VerifiedGitHubReleaseAssets `
        -Repository $component.Repository `
        -AssetPatterns $plan.AssetPatterns `
        -Destination $destination `
        -VersionMarker '.devconfig-version' `
        -RequiredFile @('llama-cli.exe', 'llama-bench.exe') `
        -CacheDirectory $assetCache
    Remove-UserPathEntry -Path $legacyDestination
    Add-UserPathEntry -Path $destination -Prepend
    $llamaCli = Join-Path $destination 'llama-cli.exe'
    $llamaBench = Join-Path $destination 'llama-bench.exe'
    if (-not (Test-Path -LiteralPath $llamaCli) -or -not (Test-Path -LiteralPath $llamaBench)) {
        throw "The verified $($acquisition.Tag) $($plan.Runtime) asset set was extracted to '$destination', but required llama.cpp executables were not found."
    }
}
$assetIdentity = @($acquisition.Assets | ForEach-Object {
    [ordered]@{
        name = $_.name
        sha256 = ([string]$_.digest).Substring(7)
        bytes = $_.size
        cachePath = Join-Path (Join-Path $assetCache $acquisition.Tag) $_.name
    }
})
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $plan.Vendor
    architecture = $architecture
    maturity = $plan.Maturity
    sourceType = $component.SourceType
    repository = $component.Repository
    backend = $plan.Backend
    runtime = $plan.Runtime
    selectedDevice = $plan.DeviceName
    requestedRuntimeDevice = $Device
    driverPrecondition = $(if ($plan.Backend -eq 'CUDA' -and $driver) { "NVIDIA $($driver.DriverVersion), compute capability $($driver.ComputeCapability)" } else { 'Use the installed vendor display/compute driver reported in host.gpus; this flow does not replace GPU drivers.' })
    amdGfxTarget = $plan.AmdGfxTarget
    assetPatterns = $plan.AssetPatterns
    resolvedTag = $acquisition.Tag
    resolvedAssets = $assetIdentity
    versionPolicy = $plan.VersionPolicy
    integrity = $component.Integrity
    cachePath = $assetCache
    installPath = $destination
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = $acquisition.Action
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{
        model = 'Qwen3-0.6B-Q4_K_M.gguf'
        backend = $plan.Backend
        runtime = $plan.Runtime
        device = $plan.DeviceName
    }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: llama.cpp'
    return
}

Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--version') -DisplayName 'llama.cpp CLI verification'
Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--help') -DisplayName 'llama.cpp help verification'
$statePath = Join-Path $legacyDestination 'selected-backend.json'
Write-DevConfigTextFile -Path $statePath -Content ([ordered]@{
    backend = $plan.Backend
    runtime = $plan.Runtime
    expectedDevice = $plan.DeviceName
    requestedDevice = $Device
} | ConvertTo-Json -Compress)

$modelPlan = Get-LlamaModelSmokePlan
$inferenceEvidence = $null
if ($SkipModelSmoke) {
    Write-Warning 'LLAMA_CPP_MODEL_SMOKE_SKIPPED: CLI is ready, but no model inference was performed.'
} else {
    $modelDirectory = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\models'
    $modelPath = Join-Path $modelDirectory $modelPlan.FileName
    Write-Host "Downloading pinned $($modelPlan.Repository) model $($modelPlan.FileName) (approximately $([math]::Round($modelPlan.Size / 1MB)) MB, $($modelPlan.License))."
    Install-VerifiedDownload `
        -Uri $modelPlan.Url `
        -Destination $modelPath `
        -Sha256 $modelPlan.Sha256 `
        -ExpectedSize $modelPlan.Size
    $benchArguments = @(
        '-m', $modelPath,
        '-ngl', $(if ($plan.Backend -eq 'CPU') { '0' } else { '999' }),
        '-p', '32', '-n', '1', '-r', '1', '-o', 'json', '-v'
    )
    if ($plan.Backend -eq 'CPU') {
        $benchArguments += @('--device', 'none')
    } elseif ($Device) {
        $benchArguments += @('--device', $Device)
    }
    $benchmarkResult = Invoke-AiNativeCommandSeparated `
        -FilePath $llamaBench `
        -Arguments $benchArguments `
        -TimeoutSeconds 300
    $benchmark = $benchmarkResult.StandardOutput.Trim()
    if ($benchmarkResult.ExitCode -ne 0) {
        throw "llama-bench failed while collecting backend evidence (exit $($benchmarkResult.ExitCode)): $($benchmarkResult.StandardError)"
    }
    $parsedBenchmark = ConvertFrom-AiJsonArrayWithDiagnostics -Json $benchmark -Diagnostics $benchmarkResult.StandardError
    $backendEvidence = Get-LlamaBenchmarkBackendEvidence `
        -Data @($parsedBenchmark.Data) `
        -Diagnostics $parsedBenchmark.Diagnostics `
        -Backend $plan.Backend `
        -ExpectedDeviceName $(if ($Device) { $null } else { $plan.DeviceName }) `
        -RequestedDevice $Device
    $arguments = Get-LlamaInferenceArguments -ModelPath $modelPath -Marker $modelPlan.Marker
    $arguments += @('-ngl', $(if ($plan.Backend -eq 'CPU') { '0' } else { '999' }))
    if ($plan.Backend -eq 'CPU') {
        $arguments += @('--device', 'none')
    } elseif ($Device) {
        $arguments += @('--device', $Device)
    }
    $inferenceResult = Invoke-AiNativeCommandSeparated `
        -FilePath $llamaCli `
        -Arguments $arguments `
        -TimeoutSeconds 300
    $output = @(
        $inferenceResult.StandardOutput
        $inferenceResult.StandardError
    ) -join "`n"
    $output = $output.Trim()
    if ($inferenceResult.ExitCode -ne 0 -or $output -notmatch [regex]::Escape($modelPlan.Marker)) {
        throw "llama.cpp model inference did not produce marker '$($modelPlan.Marker)' (exit $($inferenceResult.ExitCode)). Output: $output"
    }
    $report.acceptance.inference = [ordered]@{
        model = $modelPlan.FileName
        modelSha256 = $modelPlan.Sha256
        modelBytes = $modelPlan.Size
        modelLicense = $modelPlan.License
        marker = $modelPlan.Marker
        backendPlan = $plan.Backend
        runtimePlan = $plan.Runtime
        selectedVendor = $plan.Vendor
        selectedDevice = $plan.DeviceName
        requestedRuntimeDevice = $Device
        requestedRuntimeDevices = $backendEvidence.RequestedDevices
        actualRuntimeDevices = $backendEvidence.GpuInfo
        amdGfxTarget = $plan.AmdGfxTarget
        backendEvidence = $backendEvidence
        benchmark = $parsedBenchmark.Data
        benchmarkJson = $parsedBenchmark.Json
        benchmarkDiagnostics = $parsedBenchmark.Diagnostics
        benchmarkJsonRepaired = $parsedBenchmark.JsonRepaired
    }
    $inferenceEvidence = [ordered]@{
        model = $modelPlan.FileName
        marker = $modelPlan.Marker
        backend = $plan.Backend
        runtime = $plan.Runtime
        device = $backendEvidence.GpuInfo
        hardwareAccelerated = $backendEvidence.HardwareAccelerated
        actualOffloadedLayers = $backendEvidence.ActualOffloadedLayers
        benchmarkJsonRepaired = $parsedBenchmark.JsonRepaired
    }
    Write-Host "LLAMA_CPP_READY: architecture=$architecture, backend=$($plan.Backend), runtime=$($plan.Runtime), device=$($backendEvidence.GpuInfo -join ','), model=$($modelPlan.FileName), sha256=$($modelPlan.Sha256)."
}
Add-AiReportPhase -Report $report -Name 'llama-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: llama.cpp'
