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
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
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
# nSyBL6GCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCgKD/tDtwmA+Jf
# cqFq2oRKjc17CJMNZUDoMZCU/e266AIGaq8ms08ZGBMyMDI2MTAwOTIxNDQ1NS4z
# NzlaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1NTFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACG9CyuAJn93LPAAEAAAIbMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgzMFoXDTI2MTEx
# MzE4NDgzMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU1MUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAjsWd52ZZkzB5Xe5g/l2GsOjAz30sg6jVxfFJV+w4xIDV
# yaI3LO8bIpmzYul3AZHg50UIQ8PrSRZGpQqFkRNu+o3YKJ4g2uGYBRksHnHYR0uV
# SCQg58ThkYyeplGX3oAvGRVuPIpQtAiTsR76A/gdoU7HDwEbb73bJwTyrbKHhR+W
# aMy9DQHI4k5Qo4+bZDs0kj76bvhJvdGU+S8zxQBp7UAhjJnFqKxIusSITE7zCCR4
# 22ELhkhVVOFqK2w6h1MAvILe76hxRIcPj0SBL2r8O9tx5njU4+tg2rAdU153pmyh
# qazdpUccYBE9wDRFUd/e9CoWx7TdnUicB+Mai7RT6qse7e5aGqX1B7bnj/ZHvrrf
# F+BJEIlS9iDXAUgekvXZ+FZmjvLwP+dN+0/crh++r4e8FknF7EX6IJfnmNeDN/68
# Z59kbaJ1f+P5mnKYfydCeZmxrGpS0taWkDk36D3jPVZflvxrc+1rhCIlM5v9agLE
# FI12QiBTfpOBOBr3AGCPk+eH0+latjQajug+2/BD12qb82500LQytUWT2ota/HYn
# RgSv1jvZ0/dml1FsxWYzOnCrjfdB/7N6pNySt4vn+PGN6dFLim7kxos+B9WfQPez
# Ji3fuKyyDAB9zSHPj1Zu8nZfecZJ9um4zj7DFgvJXTDTnG5qlG4ZdbFRa/rrfzkC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBS2vp93/lxLppNK8OkauJ2AvNmIUDAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAZkU1XxQD4OTM3GTht32TXShIfPBoMfSsFsBQ
# qFOZqLJOxyJOllIBFpmpvOtGNPkC5Z8ldG8aCpvgFNo/jDWeT5FiW53dAj9KnZxp
# sQ3Pf5fRzSGHRcxEMOdXIVzDJwcZUX0cjfxna7ydNv8eXB/Xk6G6SyrR2OH6S1LH
# MW11m3UvKF+eLjIPl45rximuDCoEd+ad0lOAXA5/vZOKN5n/ePYeP0LRchZX0Q6H
# 8n/ZmSPMlbli3MO851Q09RmT/ZGHa+/Fdy+WLDrwcYykV9mUy/4TbwKw6FtdR6ZP
# HxMdIi1pk8Y2mC/GzCq0LCsH0uTFeQ6Q7Nc3MRmER/3mLWUhbaWHgX1FbYchvR22
# b+Bup+YPR5Q/0BhaaAN6AIBfcGs+u/nJoIByyZKA8cTyCmnUI/4vW6D4vywg3XBF
# f4f2DwFHy/evsC+58KMl+k2wa05X2kK0T/bCPLhaov9ZXyobawfNOLYGiauKT2FW
# vbwZzHIFCTxjBww6Pt5uRvCE/jnUcf/xhlOGMn6iKO9Xt49vZTE2SfIBk/34iLTR
# BJ6H7aGPTTQnza3OfWu1/dRycC6Wl5ons3PjnGXTSKSxXllJPmg6R/ulGonP/UCY
# oJ6mN+EXjfyDLPXLqsr91+VTG1rYzRCjPwBFAHv4EIwaE0ajCrf75eUGI3+oXU0U
# P6rloZ8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCC
# Aj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1NTFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAhoV6r49M4GBd41K1RYB1Z0f4zuCggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5zWCowIhgPMjAyNjEw
# MDkxMjEwMThaGA8yMDI2MTAxMDEyMTAxOFowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7nNYKgIBADAHAgEAAgIGujAHAgEAAgISqzAKAgUA7nSpqgIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQCSgPaoHYuJExOgWwbbmZIxf4HfD/AtYPFTWnUp
# Y4xjbc4ItzbhU0tfMkfu9XzvgSj6cSIRLDJ2lAh+Cqf+4tY9OuGEQGPe21g/HXju
# 8LXCHJRd5dRlO7ZahQBsQhl21q9rZqe/fH6Gl+UiJBbPB0vt98KV4nW5vHy/6dBC
# yiddm3gC+knxKjCUJD+uJfCoF/4OTOo6axnofQHFhAejpwlSQdWJJAiWcxHeRfSa
# DzSKuOOU2N+xEqg2NkwbnDtNFvcYJWolI4ucHoQmbFVxpQwWh9aIgX8+g7htjYLx
# zU3WPxuF6lHbYpVwY9eqWnus+B4cwU7IUZY4iJdRuv+lOy0IMYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIb0LK4Amf3cs8A
# AQAAAhswDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQgk0wmNn8jpCkikrrFWNRqmeQX/zXIrardBzze
# 8RjERqEwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCAwJRSVuD2jmMcQCFXd
# LuJAwDpUVNZ6bc6dfJU83Q2LgDCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACG9CyuAJn93LPAAEAAAIbMCIEIIOqvqCchK/YcJjieAdK
# aTOOn9eHvEh4N29NgTWB7kr1MA0GCSqGSIb3DQEBCwUABIICAFgiQ7CgQDP0UdUq
# uKBijQrlEy1KhLjv67OSIbDr9v5OBoLyvIp/gBVCsmY6xHjWRukzBO537rlaByEt
# Ynt15AV3c0HZAfK+tssOzWJKlsp/N+B8xKTyHIgl9vMwvvX6/Hh6N03Y3HMf8F/P
# StgoHYQe3KCi38vYhZ5lsUQlhxuBLPhggb+b0ddUP4PFkgt9aKmoP75Os3tgceI4
# 5iDscHSa+e1veHPbq55C8iFC0xySk1FxvnK5dyMwoXCXCNIVD0uf3GYzxO2ZDtI9
# CtjIsSGRPguaHyI7OzHMFLZggdpszFYQS5H9Va3bvKnpyFD+8HMQ8/OPTqPrj+Vw
# P9sZSADXjSULQ+BHzI2PaSQBh2MQkCUBB1l68erIVkqawnnCAW7LavEmygkQguST
# Tw63sFHjBm1Fd8shXzm6XKvwBofe8P3jRrIQ6djmAQoNWhbwTuJRTnXWOBKwJvnO
# d2vryGkJR4QWfqaQSz/JmR3Upb57RJktY5F/qGGHcqZ7lIc31AVk4nWvqBEah/GT
# ujv0byReDNyoKDac30fM3xDugC8C/g4/tZjKZcy6oaCfeOOKU21XMkqI7QpK7TrP
# nckMIdiFcK9sOOGslX60+Orb+ydpGnKhC1Wrarp4oKMJkj5r/XVd1GSD8QqmnJC0
# giRjFRuG8dMwTh7XsN4wHYqfgd+0
# SIG # End signature block
