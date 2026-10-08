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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDUlp/x8o00H/C0
# so8yo1Mn7zq7PIiskzeRNiLKyUzcOKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIDSDlpCOAYBQ/7prIL2ucosz/Y3Vzi0IIoDdUqKIVkVmMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAsEDoa3IjnZvOswCQ
# P/+NLXwTf8J8MlzelSMqZen9AJdzlS+5o5Pys0uBbvFVQmtEQWQGn6LKZDTNiai1
# +9Yr75NtEUGxUEpHGdqUl3U77usha5cR8bcujNhuRi1ADbF0DCSOsz2FeFlbPgKO
# I90p5FVPmJGkJqx96l415E0sRn16aFXnWnMku1oqPQzkHC5CR1y8dTXC/Nnxhu7c
# uYgjR8K5JRcPMCUaIdlkoM7vdHstv6pdhu/Gmjahl2FVj72ljayjXnGQ2tmqyMwe
# PQZSXFdnVLXv2WItluhqP3nRoGukHGdcEjnIh7eK9fmiBY6W5bQ1TONYU1gWp89U
# nSyBL6GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCgKD/tDtwmA+Jf
# cqFq2oRKjc17CJMNZUDoMZCU/e266AIGarfwfBf5GBMyMDI2MTAwODAzMDIwNC44
# NDJaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiEzwDX70g8hpAABAAACITANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTRaFw0yNzA1MTcxOTM5NTRa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDb
# cTACqU1YvRocyWL2PL9fyf/+ULs2qK7U1aZsRnDZSnlCr7K7jgA3eFCEJL5BZ7dU
# TC0DeZepf+ZC+7HEbB4IdzmJfQAUDFFerqY5VTHmQvP2XA3lWSFj740idcGUHglP
# 5H/PbCJU7GAHWP2HdcCjdx1lYAo0A+zLI7xwnTQeMyOXX212Eg4UmDPPJgxdTMw6
# WFVWsBPWRBi5gDixy2s+7R8ADk5lbBBFDB5h0CjrNWIN7uCAzF5g7trrL8nXIKp1
# 0mj9RxhcGQ+tlht6VIvdygRVTUGdzFB2/nBvJqQ9kxxFltQST70fEdx4TyaKow/f
# 5+BSh4z4/9f7NXIVVTLn/8kcJAfRqFmRrrFt3IKby7VrzmYuoQWD0lmNFtGQ57Br
# JkPrPFAPek1ALtcbb7FH3nQpvi8ngz/MFX/+cnmNFWFU29VVLmzB9XvLZxbYvkee
# tt0mh5lfteeN2rEwUyrdrKufz9h2S6pbate+C2h02CrXwSka0x6ezpTmGkIJLFt2
# 5ub/UYXNLdHdsxGD6EfckOIoJYsm4MS9F/vSqLNHK89I0vTLBngQEp6LIFkINanR
# T3PtNx3pNKRKJRALc6L6mhW4hL4aHL749qPfQ72t5qAMm5xiKYMgJ2WanidRLNuI
# 251JIN7raaeA/2vb0XFkZcIbTR1pfQGsco4U0g5tjwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFOYjIs5qa6pfuquPyyK1FTr5QDCnMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA4I/3bkdnTxD2rFum3MF8xVKdEkohAObbePrQ+0fr5bRimjz9sVkKT/7gc
# j4OMcClSYG+IdX6Mp3EYsLHWfjvwfzFoeZE+yTbdBj/1VHZQRuCmw6QqeVCTbw2n
# nS7nBxnWd9oZXbPUpqEawH5DqXQaWFgR9A4KWVK/IvXVDMj1PlPCES1P3JonNbdh
# kkkz49rJuKOm5b7e/BH8loqAmXOXRc22yxWVTMWrEp4pslmv8eT7VoY8X/jdKYTP
# VEXsfmLbVFcqzMuB8vFGfUyWsWROS8wgq7lQYfWcYqh7NymoATX+wWYK3zWG7aRc
# iPGUAzznXdf+aHtIWnQLNa5HFmSXkiak3fSuprWYZiHhuYjE16hroApcBHpm+8S/
# kNqhm9WjQX+2BxnYv+Jejy6lqTi8fLBLS069WXVw/ptf5IV+FtYl34GvVoeg31Uo
# UmVVZe1SDUJkm9dDXc8l/qBDYiAIT2CCsPTyt9XA9JVuHxdP63n7ChvWAO/47QRu
# CDsUlFJoWwyBwl7jeYpaRVMtQt0iuJMGGjgEaJX1Q/2j8sXURvTceLHDD9ipWt09
# 2ZDWMQciDRmhHNFOX1dnjBvk/k1UMcg997j5oYznAnSpJvlg/4BP3aVE0h/YH2Kg
# sKbU4NXZHAjJXj2Slqo1C115CG6qBZaFkM8W6vPZCm5qnSezOjCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjMzMDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQALbEgZZnyYHXJ1DGb5fGjplXpt
# uaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nDtojAiGA8yMDI2MTAwNzE2MTExNFoYDzIwMjYxMDA4MTYxMTE0
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucO2iAgEAMAcCAQACAgD1MAcCAQAC
# AhHmMAoCBQDucj8iAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAAqW18Zd
# P2wjdlV1xQlVl1dXGznRfYc1Vjdc5L/EPaMP3qgF1ZfB3m8T0m13kWqJJwTuHKDS
# M06hOMgPSX43d3HULJpEeiayooNUyHepKzXvYNXE0nqp6xVe0+Ag1Pv2OCfiiArX
# AE0quKXFW7foKdbZfgyKp5yZ7Htw45EjX8T5aHUAYdWYxlvxQXlsSIkVCeTSf282
# 2GT/NqLRHQmd2xC2gU7BjmvafMS7jrh6EmP6lBOdKilcZHkndBbmSAKHau+AgQ5h
# GoUDbJi+1/p2QaQ3sFcEuJSE+6XDDMxVhh1KPM5hAXj1sNDXrRRk1JMUQ/EtTHnk
# pqyWLJX5sdMYlBQxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiEzwDX70g8hpAABAAACITANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCC3KHP
# J8dSDaVzuFt5Sarvy15ePVj7J16Z+mXacxnEsTCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIADvIQefFVUa4BJy8IZywMAvmGSKdUVqEmy9A++PCj1EMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIhM8A1+9IPIaQA
# AQAAAiEwIgQgHGMCfjkoXCvG5nhW5+ICmXx1sBvT2iQs5uWulJt4iuowDQYJKoZI
# hvcNAQELBQAEggIAvTAYBsFTaNJMa7rcW9sSXsLl+R8iGuQMNxHZ4FYB/Kcq0vGZ
# aim54Gh2qT8lcux4tTLYve5s7Rkg8O13HHEMMKIQp6Q8Sc+9YuXGPrE4wOMAd0jj
# es4TL2Si3QRuz6hiaRaUPIa24xmgoBQ5wk1TpY+6Ysf6HyqI/+k4yZKI0cu9KOhJ
# pmZ1nK1g5Vjoq7ZSeQP15OKV7ki0dCAZHZVMF5DQL7vNIW0aEsrOa/Tix6Z/cEDc
# pnLETvN1Yw7sHerF76tvDpq36Ei/Z0D8ftp4h0eQz1gNDUg6n7aryjJ253WY//+x
# +le/tBl/ejnw88m9bdXcgmBcr6PearEw70jtfdAl/WD3aQmnMqMMDNAaJVEd08FV
# ptEiYotCyzy38yss2K7b+uH9ceX20IVvq7WG6RRQlIMDs23rlU37iXm41MYy87IJ
# C4hDTj0Rza6vwAYwVPtjsVe4jLJYfb4l97TbrgDc8lAFx4TFQ5IzSNc3iUNuAuPz
# nWRVPJCXC4kiwe+hl3EF+OGSGPgAreHog3PZh+zap2O2IqLhxOx4zBy/UGaZ14s4
# pgk7yXU0hcj0LwxcgUZshf4/iaOkZr5xuUBV65Nytctt8uKOxupN+mHhVAnqAqfR
# HSmtXq6YUqwTRr76L5tS4c1X3BJ8JHrCFcsK3tSNu+uoNfLIw3r4LWukJLE=
# SIG # End signature block
