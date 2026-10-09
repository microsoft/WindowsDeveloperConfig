<#
.SYNOPSIS
  Install a self-contained Windows PyTorch backend and run device acceptance.

.PARAMETER Backend
  Auto deterministically selects supported NVIDIA CUDA, then AMD ROCm, then
  Intel XPU, then CPU. Explicit selection can target a supported secondary GPU.
  CUDA/ROCm/XPU runtime packages are installed inside the contained PyTorch
  environment. The standalone CUDA, ROCm, and Intel AI flows are native
  developer-toolkit/runtime flows, not prerequisites for ordinary tensor use.

.PARAMETER SkipTriton
  Do not install or verify Triton when supported. Native Windows Triton is
  supported for qualified NVIDIA CUDA (`triton-windows`) and Intel XPU
  (`triton-xpu`/`torch.compile`) paths, not AMD ROCm.

.PARAMETER RequireTriton
  Fail unless this host has a supported Triton combination. This is available
  for qualified NVIDIA CUDA and Intel XPU paths; native Windows AMD ROCm has no
  supported Triton package.

.PARAMETER DeviceIndex
  Zero-based device index for CUDA/ROCm/XPU acceptance. Use this to target a
  same-vendor secondary adapter with an explicit backend. Auto requires index 0
  so package resolution and execution cannot refer to different vendor devices.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $Backend = 'Auto',
    [switch] $SkipTriton,
    [switch] $RequireTriton,
    [ValidateRange(0, 63)] [int] $DeviceIndex = 0,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$gpuVendor = Get-AiDetectedVendor
$amdGpuName = if ($Backend -in @('Auto', 'ROCm')) { Get-AmdGpuName -DeviceIndex $DeviceIndex } else { Get-AmdGpuName }
$intelGpuName = if ($Backend -in @('Auto', 'XPU')) { Get-IntelGpuName -DeviceIndex $DeviceIndex } else { Get-IntelGpuName }
$driver = $null
$driverError = $null
try {
    $driver = Get-NvidiaDriverInfo -DeviceIndex $(if ($Backend -in @('Auto', 'CUDA')) { $DeviceIndex } else { 0 })
} catch {
    $driverError = $_.Exception.Message
}
$nvidiaGpu = if ($driver) { [pscustomobject]@{ Name = $driver.Name } } else { Get-NvidiaGpu }
$gpuName = if ($Backend -eq 'ROCm') {
    $amdGpuName
} elseif ($Backend -eq 'XPU') {
    $intelGpuName
} elseif ($nvidiaGpu) {
    $nvidiaGpu.Name
} elseif ($amdGpuName) {
    $amdGpuName
} else {
    $intelGpuName
}
$amdGfxTarget = if ($amdGpuName) { Get-AmdGfxTarget -GpuName $amdGpuName } else { $null }
$report = New-AiWorkloadReport -Id 'pytorch' -Request @{
    Backend = $Backend
    SelectedBackend = $null
    SkipTriton = [bool]$SkipTriton
    RequireTriton = [bool]$RequireTriton
    DeviceIndex = $DeviceIndex
    PlanOnly = [bool]$PlanOnly
    DetectedVendorPriority = $gpuVendor
    DetectedNvidiaDevice = $(if ($nvidiaGpu) { $nvidiaGpu.Name } else { $null })
    DetectedAmdDevice = $amdGpuName
    DetectedIntelDevice = $intelGpuName
    AmdGfxTarget = $amdGfxTarget
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'pytorch' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
if ($Backend -eq 'Auto' -and $DeviceIndex -ne 0) {
    $message = 'PyTorch -Backend Auto supports only -DeviceIndex 0. Select CUDA, ROCm, or XPU explicitly to target a secondary same-vendor adapter.'
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: pytorch'
        return
    }
    throw $message
}
if ($driverError) {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($driverError)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: pytorch'
        return
    }
    throw $driverError
}
if ($SkipTriton -and $RequireTriton) {
    throw '-SkipTriton and -RequireTriton cannot be used together.'
}
if ($PlanOnly) {
    $pythonPackage = Ensure-AiWingetPackage -Id 'Python.Python.3.13' -PlanOnly
    $pythonVersion = [version]'3.13'
} else {
    Assert-AiAdministrator
    $pythonPackage = Ensure-AiWingetPackage -Id 'Python.Python.3.13'
    $pythonPath = Get-Python313Path -Architecture $architecture
    $pythonVersionResult = Invoke-DevConfigNativeCommand -FilePath $pythonPath -Arguments @(
        '-c', 'import platform; print(platform.python_version())'
    )
    $pythonVersionText = $pythonVersionResult.Output.Trim()
    if ($pythonVersionResult.ExitCode -ne 0) { throw 'Python failed while reporting its version.' }
    $pythonVersion = [version]$pythonVersionText
    $pythonMachineResult = Invoke-DevConfigNativeCommand -FilePath $pythonPath -Arguments @(
        '-c', 'import platform; print(platform.machine())'
    )
    $pythonMachine = $pythonMachineResult.Output.Trim()
    if ($pythonMachineResult.ExitCode -ne 0) { throw 'Python failed while reporting its architecture.' }
    Assert-PythonArchitecture -Architecture $architecture -PythonMachine $pythonMachine
}
$hasNvidia = [bool]$driver
try {
    $plan = Resolve-PyTorchPlan `
        -Architecture $architecture `
        -Backend $Backend `
        -PythonVersion $pythonVersion `
        -HasNvidia $hasNvidia `
        -DriverMajor $(if ($driver) { $driver.DriverMajor } else { 0 }) `
        -ComputeCapability $(if ($driver) { $driver.ComputeCapability } else { [version]'0.0' }) `
        -GpuVendor $gpuVendor `
        -GpuName $gpuName `
        -AmdGpuName $amdGpuName `
        -IntelGpuName $intelGpuName `
        -AmdGfxTarget $amdGfxTarget `
        -HasAmd ([bool]$amdGpuName) `
        -HasIntel ([bool]$intelGpuName) `
        -SkipTriton:$SkipTriton
} catch {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($_.Exception.Message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: pytorch'
        return
    }
    throw
}
$report.request.SelectedBackend = $plan.Backend
$report.request.SelectedVendor = $plan.Vendor
$report.request.SelectedDevice = $plan.DeviceName
if ($RequireTriton -and -not $plan.InstallTriton) {
    $message = "Triton Windows is required but unsupported: $($plan.TritonReason)"
    if (-not $PlanOnly) { throw $message }
    [void]$report.result.blockers.Add($message)
}
$catalog = (Get-AiCatalog).Components
$component = if ($plan.Backend -eq 'CUDA' -and $architecture -eq 'Arm64') {
    $catalog.NvidiaPyTorchArm64
} elseif ($plan.Backend -eq 'CUDA') {
    $catalog.PyTorchCudaX64
} elseif ($plan.Backend -eq 'ROCm') {
    $catalog.PyTorchRocm
} elseif ($plan.Backend -eq 'XPU') {
    $catalog.PyTorchXpu
} else {
    $catalog.PyTorchCpu
}
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = 'Python 3.13'
    sourceType = 'winget'
    packageId = 'Python.Python.3.13'
    action = $pythonPackage.Action
    packageEvidence = $(if ($PlanOnly) { $null } else { $pythonPackage.Evidence })
})
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = "PyTorch $($plan.Backend)"
    vendor = $component.Vendor
    detectedVendorPriority = $gpuVendor
    selectedDeviceName = $plan.DeviceName
    selectedVendor = $plan.Vendor
    selectedDevice = $plan.DeviceName
    amdGfxTarget = $plan.AmdGfxTarget
    architecture = $architecture
    maturity = $component.Maturity
    sourceType = $component.SourceType
    requirement = $plan.TorchRequirement
    additionalRequirements = $plan.AdditionalRequirements
    runtimePackageTuple = @($plan.TorchRequirement) + @($plan.AdditionalRequirements)
    index = $plan.IndexUrl
    version = $plan.TorchVersion
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = '%LOCALAPPDATA%\DevConfig\pytorch\.venv'
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    promotionCandidate = Get-AiCatalogValue -Entry $component -Name 'PromotionCandidate'
    nativeToolkitRequired = $component.NativeToolkitRequired
    nativeToolkitRelationship = $component.NativeToolkitRelationship
    action = $(if ($PlanOnly) { 'planned' } else { 'pending' })
})
if ($plan.InstallTriton) {
    $tritonComponent = if ($plan.Backend -eq 'XPU') { $catalog.TritonXpu } else { $catalog.TritonWindows }
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = $tritonComponent.Component
        vendor = $tritonComponent.Vendor
        architecture = $architecture
        maturity = $tritonComponent.Maturity
        sourceType = $tritonComponent.SourceType
        package = $tritonComponent.Package
        versionPolicy = $tritonComponent.VersionPolicy
        integrity = $tritonComponent.Integrity
        cachePath = $tritonComponent.CachePath
        installPath = $tritonComponent.InstallPath
        reasonNormalChannelInsufficient = $tritonComponent.NormalChannelLimitation
        expectedStableSource = $tritonComponent.ExpectedStableSource
        migrationTrigger = $tritonComponent.MigrationTrigger
        cleanupUpgrade = $tritonComponent.CleanupUpgrade
        action = $(if ($PlanOnly) { 'planned' } else { 'pending' })
    })
}
$vcRedistPackage = Ensure-AiWingetPackage -Id "Microsoft.VCRedist.2015+.$($architecture.ToLowerInvariant())" -PlanOnly:$PlanOnly
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = 'Visual C++ Redistributable'
    sourceType = 'winget'
    packageId = $vcRedistPackage.Id
    architecture = $architecture
    action = $vcRedistPackage.Action
    packageEvidence = $(if ($PlanOnly) { $null } else { $vcRedistPackage.Evidence })
})
$cppTools = $null
$cudaToolkit = $null
if ($plan.InstallTriton -and $plan.Backend -in @('CUDA', 'XPU')) {
    $cppTools = Ensure-AiVisualCppTools -Architecture $architecture -PlanOnly:$PlanOnly
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = 'MSVC C++ Build Tools'
        sourceType = 'winget-plus-workload'
        packageId = $cppTools.Package.Id
        architecture = $architecture
        action = $cppTools.Action
        compiler = $(if ($PlanOnly) { $null } else { $cppTools.Compiler })
        packageEvidence = $(if ($PlanOnly) { $null } else { $cppTools.Package.Evidence })
    })
    if ($plan.Backend -eq 'CUDA') {
        $cudaToolkit = Ensure-AiCudaToolkit -Architecture $architecture -PlanOnly:$PlanOnly
        Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
            component = 'CUDA Toolkit for Triton JIT'
            sourceType = $cudaToolkit.Source
            architecture = $architecture
            action = $cudaToolkit.Action
            toolkitVersion = $cudaToolkit.ToolkitVersion
            nvcc = $(if ($PlanOnly) { $null } else { $cudaToolkit.Nvcc })
            versionEvidence = Get-AiObjectPropertyValue -InputObject $cudaToolkit -Names @('VersionEvidence')
            packageEvidence = Get-AiObjectPropertyValue -InputObject $cudaToolkit -Names @('PackageEvidence')
        })
    }
}
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'tensor' -Status 'planned' -Evidence @{
        backend = $plan.Backend
        vendor = $plan.Vendor
        device = $plan.DeviceName
        deviceIndex = $DeviceIndex
        amdGfxTarget = $plan.AmdGfxTarget
        selfContainedRuntime = $true
        separateToolkitRequired = $false
        tritonToolchainRequired = [bool]($plan.InstallTriton -and $plan.Backend -in @('CUDA', 'XPU'))
    }
    Add-AiReportPhase -Report $report -Name 'triton' -Status $(if ($plan.InstallTriton) { 'planned' } elseif ($SkipTriton) { 'skipped' } else { 'unsupported' }) -Evidence @{ reason = $plan.TritonReason }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host $(if ($report.result.blockers.Count) { 'PLAN_UNSUPPORTED: pytorch' } else { 'PLAN_OK: pytorch' })
    return
}

$root = Join-Path $env:LOCALAPPDATA 'DevConfig\pytorch'
$venv = Join-Path $root '.venv'
$statePath = Join-Path $root 'install-state.json'
$desiredState = [ordered]@{
    architecture = $plan.Architecture
    backend = $plan.Backend
    torch = $plan.TorchRequirement
    torchVersion = $plan.TorchVersion
    index = $plan.IndexUrl
    triton = $plan.TritonRequirement
    tritonVersion = $plan.TritonVersion
    numpy = $plan.NumpyRequirement
    numpyVersion = $plan.NumpyVersion
    additionalRequirements = @($plan.AdditionalRequirements)
    python = "$($pythonVersion.Major).$($pythonVersion.Minor)"
    deviceIndex = $DeviceIndex
    selectedDevice = $plan.DeviceName
}
$desiredJson = $desiredState | ConvertTo-Json -Compress

$currentJson = $null
if (Test-Path -LiteralPath $statePath) {
    $currentJson = (Get-Content -LiteralPath $statePath -Raw).Trim()
}
$existingVenvPython = Join-Path $venv 'Scripts\python.exe'
$existingVersions = Get-PythonEnvironmentVersions -PythonPath $existingVenvPython
if ((Test-Path -LiteralPath $venv) -and
    (Test-PyTorchEnvironmentRequiresRecreation `
        -DesiredStateJson $desiredJson `
        -CurrentStateJson $currentJson `
        -InstalledVersions $existingVersions)) {
    Write-Host 'The requested PyTorch plan changed; recreating the contained environment.'
    Remove-Item -LiteralPath $venv -Recurse -Force
    $currentJson = $null
    $existingVersions = $null
}

New-Item -ItemType Directory -Path $root -Force | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python.exe'))) {
    Invoke-CheckedCommand -FilePath $pythonPath -ArgumentList @('-m', 'venv', $venv) -DisplayName 'PyTorch virtual environment creation'
}

$venvPython = Join-Path $venv 'Scripts\python.exe'
$installedVersions = if ($existingVersions) {
    $existingVersions
} else {
    Get-PythonEnvironmentVersions -PythonPath $venvPython
}
$packageAction = Get-PyTorchPackageAction `
    -DesiredStateJson $desiredJson `
    -CurrentStateJson $currentJson `
    -InstalledVersions $installedVersions

if ($plan.InstallTriton -and $plan.Backend -in @('CUDA', 'XPU')) {
    $compiler = Import-MsvcEnvironment -Architecture $architecture
    Write-Host "Triton JIT compiler: $compiler"
}

if ($packageAction -eq 'VerifyOnly') {
    Write-Host "PYTORCH_PACKAGES_CURRENT: torch=$($installedVersions.torch), numpy=$($installedVersions.numpy), triton=$($installedVersions.triton). Skipping package resolution and installation."
} else {
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '--upgrade', 'pip') -DisplayName 'pip upgrade'
    Invoke-CheckedCommand `
        -FilePath $venvPython `
        -ArgumentList (Get-PipInstallArguments -Requirement $plan.NumpyRequirement) `
        -DisplayName 'NumPy installation from the configured Python index'

    if ($plan.DirectWheelUrl) {
        $wheelDirectory = Join-Path $root 'wheel-cache'
        $wheelPath = Join-Path $wheelDirectory $plan.DirectWheelFileName
        Install-VerifiedDownload `
            -Uri $plan.DirectWheelUrl `
            -Destination $wheelPath `
            -Sha256 $plan.DirectWheelSha256
        Invoke-CheckedCommand `
            -FilePath $venvPython `
            -ArgumentList (Get-PipLocalWheelInstallArguments -WheelPath $wheelPath) `
            -DisplayName 'PyTorch installation from verified wheel cache'
    } else {
        $allRequirements = @($plan.TorchRequirement) + @($plan.AdditionalRequirements)
        $binaryPolicy = if ($plan.Backend -eq 'ROCm') { @() } else { @('--only-binary=:all:') }
        $torchDryRun = @('-m', 'pip', 'install', '--dry-run') + $binaryPolicy + $allRequirements
        if ($plan.IndexUrl) { $torchDryRun += @('--index-url', $plan.IndexUrl) }
        Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $torchDryRun -DisplayName 'PyTorch compatible-wheel check'
        $torchInstall = @('-m', 'pip', 'install') + $binaryPolicy + $allRequirements
        if ($plan.IndexUrl) { $torchInstall += @('--index-url', $plan.IndexUrl) }
        Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $torchInstall -DisplayName 'PyTorch installation'
    }

    if ($plan.InstallTriton) {
        $tritonDryRun = Get-PipInstallArguments -Requirement $plan.TritonRequirement -IndexUrl $(if ($plan.Backend -eq 'XPU') { $plan.IndexUrl } else { $null }) -DryRun
        Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $tritonDryRun -DisplayName 'Triton Windows compatible-wheel check'
        $tritonInstall = Get-PipInstallArguments -Requirement $plan.TritonRequirement -IndexUrl $(if ($plan.Backend -eq 'XPU') { $plan.IndexUrl } else { $null })
        Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $tritonInstall -DisplayName 'Triton Windows installation'
    }
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @('-m', 'pip', 'check') -DisplayName 'PyTorch dependency check'
}

$tensorArguments = @(
    (Join-Path $PSScriptRoot 'smoke.py'), '--backend', $plan.Backend, '--device-index', $DeviceIndex
)
$tensorResult = Invoke-DevConfigNativeCommand -FilePath $venvPython -Arguments $tensorArguments
$tensorEvidence = $tensorResult.Output.Trim()
if ($tensorResult.ExitCode -ne 0) {
    throw "PyTorch $($plan.Backend) tensor smoke failed: $tensorEvidence"
}
$tensorRecord = ConvertFrom-AiKeyedJsonLine -Text $tensorEvidence -Prefix 'PYTORCH_SMOKE='
if ($plan.Backend -ne 'CPU' -and $plan.DeviceName -and
    -not (Test-AiDeviceNameMatch -Expected $plan.DeviceName -Actual $tensorRecord.device)) {
    throw "PyTorch device index $DeviceIndex executed on '$($tensorRecord.device)', but the resolver selected '$($plan.DeviceName)'. Use the matching -DeviceIndex."
}
$tritonRecord = $null
if ($plan.InstallTriton) {
    $tritonSmoke = if ($plan.Backend -eq 'XPU') { 'xpu-smoke.py' } else { 'triton-smoke.py' }
    $tritonResult = Invoke-DevConfigNativeCommand -FilePath $venvPython -Arguments @(
        (Join-Path $PSScriptRoot $tritonSmoke), '--device-index', $DeviceIndex
    )
    $tritonEvidence = $tritonResult.Output.Trim()
    if ($tritonResult.ExitCode -ne 0) {
        throw "Triton $($plan.Backend) GPU kernel smoke failed: $tritonEvidence"
    }
    $tritonRecord = if ($plan.Backend -eq 'XPU') {
        ConvertFrom-AiKeyedJsonLine -Text $tritonEvidence -Prefix 'TRITON_XPU_READY='
    } else {
        $null
    }
    Write-Host "TRITON_READY: $($plan.TritonRequirement)"
} else {
    $tritonEvidence = $plan.TritonReason
    Write-Host "TRITON_SKIPPED: $($plan.TritonReason)"
}

Set-Content -LiteralPath $statePath -Value $desiredJson -Encoding ascii
if ($plan.Preview) {
    Write-Warning 'PyTorch CUDA on Windows ARM64 is an NVIDIA Developer Preview nightly, not a stable or production-supported release.'
}
Write-Host "PYTORCH_READY: backend=$($plan.Backend), runtime=$($plan.Runtime), environment=$venv"
$versions = Get-PythonEnvironmentVersions -PythonPath $venvPython
$report.acceptance.tensor = [ordered]@{
    backend = $plan.Backend
    vendor = $plan.Vendor
    runtime = $plan.Runtime
    device = $tensorRecord.device
    deviceIndex = $DeviceIndex
    amdGfxTarget = $plan.AmdGfxTarget
    torch = $versions.torch
    numpy = $versions.numpy
    torchCudaRuntime = $tensorRecord.torch_cuda_runtime
    torchHipRuntime = $tensorRecord.torch_hip_runtime
    runtimePackageTuple = @($plan.TorchRequirement) + @($plan.AdditionalRequirements)
    selfContainedRuntime = $true
    separateNativeToolkitRequired = $false
    deviceEvidence = $tensorEvidence
}
$report.acceptance.triton = [ordered]@{
    supported = [bool]$plan.InstallTriton
    version = $versions.triton
    distribution = $versions.triton_distribution
    reason = $plan.TritonReason
    evidence = $tritonEvidence
    device = $(if ($tritonRecord) { $tritonRecord.device } else { $tensorRecord.device })
    torchCompileExecuted = $(if ($tritonRecord) { [bool]$tritonRecord.torch_compile_executed } else { $null })
    compiler = $(if ($cppTools) { $cppTools.Compiler } else { $null })
    cudaToolkit = $(if ($cudaToolkit) {
        [ordered]@{
            version = $cudaToolkit.ToolkitVersion
            nvcc = $cudaToolkit.Nvcc
            action = $cudaToolkit.Action
        }
    } else { $null })
}
$report.acquisitions[1].action = $packageAction.ToLowerInvariant()
if ($plan.InstallTriton) {
    $report.acquisitions[2].action = $(if ($packageAction -eq 'VerifyOnly') { 'already-current' } else { 'installed-or-upgraded' })
}
Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
Write-Host "Activate with: & '$venv\Scripts\Activate.ps1'"
Write-Host 'INSTALL_OK: pytorch'

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDUlp/x8o00H/C0
# so8yo1Mn7zq7PIiskzeRNiLKyUzcOKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIDSDlpCOAYBQ/7prIL2ucosz/Y3V
# zi0IIoDdUqKIVkVmMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAuWP1/iLqzTjCM3gRqucOPMihUPwXhcFi1XVALg8pMyC7NzIJvrGns3Bc3Bkx
# MN6lGr3+RWvd2+tHAnaC/TPQyc9TNjP0LDowZ5QtbaAJn0rUjtS4t/JFbFsTiTR/
# mR3q2vXWyXqtljdySHtO60i83InnZd3vCWh3FxbBxKG5wsPo8/ogKXoVNDo6LlEf
# isib2fuCo7bs1oB6VjbZdg1mTZYiANwngRtsMDgevvsFjy6+Gz8IFU5oBtBNzYCU
# Mon0Yet86tBOXQfHhtQ/62z1grct4+pf5wUBVi6nf8pqQQ4tlPNif6QZ/p7aSZ8F
# xF+DoKV7NJUO4DfIDX+qjwG5gqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBQMKtOYT4hcV9w8aYZltFs+TypNaAJqYYOazB8klHmIgIGaqmskmqsGBMy
# MDI2MTAwOTAwMTczOC43MTFaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiWAxzfGzap3SQABAAACJTANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDFa
# Fw0yNzA1MTcxOTQwMDFaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCm8RIP0eLA46VcCPovvmqsIlN6qkmz5IsHWmUU0neUqp8u
# Gxadeo+SwWBCwQ5alZI/DNdpXfyiZLZR6XYgpRPFzepIl7OCDb4NtEskJCIZDkQM
# NwrH9YwUyu71GGigsLIxeleHtA3utoVTeHjS1b8UnwORRtknKkyrUArT6ZpB2rod
# IcmcLcv3x3wwgYlOs0FEg5EsVrZb7LNc/nd0bXDp+HTOWWui8eoTVwJeLxcVP869
# oF8li5SU81aa2tGJ6/Jsejiz9JMW8SJXKBT2DCXMOUkCsGjonPZRqfvoMSIQZgta
# OTyAJlrvsy0TZ78XrGqoygtQimQnbOAL4KNLSCuW5TZEQGTHLOQJGgggb3j5gKC7
# 78+RIPJA+n/hmHJ/x4qT/HTTPoVeMCcuBKWrQXR1+/pYau3Fwe0tWIyG+LWzkRr/
# ZNPPupcA2Yci3qn8HR9RwvQopqSNJwn2Ri6am8AQyfVVy/BBw0t6jpoRPjwKvuUj
# fCzpae6duOxQtQ1XDN9PA2yl9sDko/+AXV/SOe8ea8QoQcv3s3ErkG+Lp6hnvw6O
# MPian4ggNkRtgtB7ro1OiopOUXJn9Y5EO3JUAXNcuM9m+5My1VEuvGytgAH3uxms
# lTnW3YbrfazaySCSSnWkhaOZ33hgbuUQfH7n2NFEAUc/cFzfmCQUikWisnJYywID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFLE40qoXTuMHX3AfZUu1n8nx2h93MB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQAHnfc2yUyoHZbvvyVKFuXh5HxxHIvIaR9JWpIf
# ITJlc/Ki03juR+vckzq3tp5fFH5LL7eIFXRIuoewMsvWeFrWufrrW4HhmhCwkqAr
# fA1C0xk+HaYs2O48YSxMX9lgS1kTTIb3YsfoFdFpKurPf2nc2Yd4wLg+Fgwmkxke
# yE3MUKVna8SZeVpEjnS5ucFck4srPwK2ORAf70I23GGyPhqgIKZphNXhSscTAQsy
# IqB5GwDMdRV5LK37NfU4YmxvCYh3TFYE/Gh01Q6yJvf9HxiEZpwW+oUk0gruHobg
# 3sgIR5rfgUo8l30vUnaDYMcPAClaFMC/QbHZSaUhWXZG1OOcMp0g9vYQNLDEqFX2
# jlquvzVSSwtHtm1KTldCjRED+kdCybcPxbPalwJigXc1BsI9CitnTf0ljwb9NkZ/
# JVI8/D62rXXzhz4F3u0iVGzwncGaxRxHG/Xv4nTrpkOeepoYbNBbMWS2G1qP3Xj7
# pVf0+4qRyAqJ0stjQjoVOJImVPWRjz5PR3Dn6adQVMBJDM6gDrj1rZTFVgCtTijq
# GZSGzvXpGkF3vYsyE6ZDma/kGdiUe5saeI6lH66PiWWXgqxt7sy2Ezv0yIjSVv+e
# MOT2QMUiZ6WCc7gVtAmXpfeIus+NmgFvM+Ic1X58e4I9EL4ZSAidSpWW0GZTLNC0
# 2mryLjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEw
# MB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk
# 4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9c
# T8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWG
# UNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6Gnsz
# rYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2
# LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLV
# wIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
# EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0
# gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFph
# AXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJ
# YfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXb
# GjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJ
# KwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnP
# EP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMw
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggr
# BgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
# xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
# BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0B
# AQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U5
# 18JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgAD
# sAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo
# 32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZ
# iefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZK
# PmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RI
# LLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
# ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9
# af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzba
# ukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIIC
# NQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjg2MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQBTb+bK
# OPAjCBflhzw5EXBuSWxeDqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nJ5yzAiGA8yMDI2MTAwODIwMjEzMVoY
# DzIwMjYxMDA5MjAyMTMxWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucnnLAgEA
# MAcCAQACAhiyMAcCAQACAhX4MAoCBQDuc8tLAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAMQABardHlQRw0N5a3zCrwhoktQoYWz+OP2w8CpFK1gL4rRvAAgt
# dgYfyImIbMvpNy6I0XPnESvwo+cn4uSUI22SaozIjfaxBkG34MSBZUHuy8FWi24Z
# 5b/nC+rybnvhe5OiYmqLeQqJgcx71wvzzUufCUiLX8qW6s+ZeXQUmqRzEHvzoFe2
# YSbuC73nCpbdpGGwRHnEXr+RPzkEWKORxbI1ogxF3M8frUOirNsSJu/2V4TmMDBh
# fP1iEN+v5GnVwu2JdxSR0cuyb3mA/uPEeE/jfbtNuu6RVFyrIJDimQaFQmRzNmEq
# QBs5+DJzVU3zaI+gVg2HRk+zZoMA1QXBrkoxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiWAxzfGzap3SQABAAACJTANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCBMZgyKXwWxzIPeozIWVt11sfXxRiefNj05o2aj/yCXSzCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFYN7oh6ON3y92CmAl/lF0CYwrjWWQP6
# dCUxajPSHKEQMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIlgMc3xs2qd0kAAQAAAiUwIgQgzcRbqpIhcdX/xu1uCUUynG0Orhx0mTed
# n/r5DoOtKSowDQYJKoZIhvcNAQELBQAEggIAZFNjBXs7kbawXo3WOi83lCtkMfVg
# fWANXh7ERJA3q/d1y376KJ7khShqmzJnojXXyWNW5PXe8lT7EbUni+PMNJbWRvzu
# wyxaXm6O27tbyIkrrwkEJ95VFxGmfaBO5CN0RNumU2heSJGV8v1boH08frGyAGsA
# 2Z667hur+0SAM0IWMZ8qhznYWmKkHeTvg/MswegUP0ZLFy20/KWq9sk925IgOgsh
# TcL5KSEpLlScG3D7WkdVEawuuisupK2nr3WgztlGlnS8oPCr7s4P0vbaghQ+YlGm
# +6k63BLe7k+dBMYKhZ/8OYPf2M/PO2C9KQwdgv4mWEvtnS+ZVVlBRuO01RcHnTmD
# B/r3vz2CIk4HaJ/zjiJghUQkg+tr0DqxTNTkbbT65kXL6eVZZCaHwxMDFg+A8d9d
# cZ3g6EkPDLah/+gP+CJISQ4WbsgXdgCLAGxGP8vr3eLpvcawoKwb1Y31u60Bi4zU
# EmvTsalygIg3pFEY7Rpc6oZDwojmdMNDu+3ygXICJ81rsjUtIVFrN11a8POlCx5T
# O49fDLDVt9MKlQ6fmWCz4MAD6xBSP2UlSdRqj9+NOmFIQUNVouXzb8oyX5NQbZ/L
# kErjnj2LwqWkmz3WXpW5A8EtbhWMkR7l0UDOxvwbuPITpooSeoeoBEv31uA+dq7t
# efdkIxA6p8uHPAw=
# SIG # End signature block
