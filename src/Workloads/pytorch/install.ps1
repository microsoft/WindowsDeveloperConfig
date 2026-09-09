<#
.SYNOPSIS
  Install PyTorch into a contained virtual environment and run a tensor smoke test.

.PARAMETER Backend
  Auto selects a verified NVIDIA CUDA wheel when the architecture, Python,
  driver, and GPU are compatible, otherwise CPU. On ARM64 with an unsupported
  NVIDIA GPU stack, Auto fails rather than silently presenting CPU as GPU-ready.

.PARAMETER SkipTriton
  Do not install Triton Windows even when the detected PyTorch CUDA stack is compatible.

.PARAMETER RequireTriton
  Fail unless this host has a supported Triton Windows combination.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU')] [string] $Backend = 'Auto',
    [switch] $SkipTriton,
    [switch] $RequireTriton,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$gpuVendor = Get-AiDetectedVendor
$amdGpuName = Get-AmdGpuName
$intelGpuName = Get-IntelGpuName
$nvidiaGpu = Get-NvidiaGpu
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
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'pytorch' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
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
    $pythonVersionText = (& $pythonPath -c 'import platform; print(platform.python_version())').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Python failed while reporting its version.' }
    $pythonVersion = [version]$pythonVersionText
    $pythonMachine = (& $pythonPath -c 'import platform; print(platform.machine())').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Python failed while reporting its architecture.' }
    Assert-PythonArchitecture -Architecture $architecture -PythonMachine $pythonMachine
}
$driver = Get-NvidiaDriverInfo
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
if ($RequireTriton -and -not $plan.InstallTriton) {
    throw "Triton Windows is required but unsupported: $($plan.TritonReason)"
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
    selectedDeviceName = $gpuName
    architecture = $architecture
    maturity = $component.Maturity
    sourceType = $component.SourceType
    requirement = $plan.TorchRequirement
    additionalRequirements = $plan.AdditionalRequirements
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
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'tensor' -Status 'planned' -Evidence @{ backend = $plan.Backend }
    Add-AiReportPhase -Report $report -Name 'triton' -Status $(if ($plan.InstallTriton) { 'planned' } else { 'unsupported' }) -Evidence @{ reason = $plan.TritonReason }
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
    $cppTools = Ensure-AiVisualCppTools -Architecture $architecture
    if ($plan.Backend -eq 'CUDA') {
        [void](Ensure-AiCudaToolkit -Architecture $architecture)
    }
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
        $torchDryRun = @('-m', 'pip', 'install', '--dry-run', '--only-binary=:all:') + $allRequirements
        if ($plan.IndexUrl) { $torchDryRun += @('--index-url', $plan.IndexUrl) }
        Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $torchDryRun -DisplayName 'PyTorch compatible-wheel check'
        $torchInstall = @('-m', 'pip', 'install', '--only-binary=:all:') + $allRequirements
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

$tensorEvidence = (& $venvPython (Join-Path $PSScriptRoot 'smoke.py') --backend $plan.Backend 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "PyTorch $($plan.Backend) tensor smoke failed: $tensorEvidence"
}
if ($plan.InstallTriton) {
    $tritonSmoke = if ($plan.Backend -eq 'XPU') { 'xpu-smoke.py' } else { 'triton-smoke.py' }
    $tritonEvidence = (& $venvPython (Join-Path $PSScriptRoot $tritonSmoke) 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Triton $($plan.Backend) GPU kernel smoke failed: $tritonEvidence"
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
    runtime = $plan.Runtime
    torch = $versions.torch
    numpy = $versions.numpy
    deviceEvidence = $tensorEvidence
}
$report.acceptance.triton = [ordered]@{
    supported = [bool]$plan.InstallTriton
    version = $versions.triton
    distribution = $versions.triton_distribution
    reason = $plan.TritonReason
    evidence = $tritonEvidence
}
$report.acquisitions[1].action = $packageAction.ToLowerInvariant()
if ($plan.InstallTriton) {
    $report.acquisitions[2].action = $(if ($packageAction -eq 'VerifyOnly') { 'already-current' } else { 'installed-or-upgraded' })
}
Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
Write-Host "Activate with: & '$venv\Scripts\Activate.ps1'"
Write-Host 'INSTALL_OK: pytorch'
