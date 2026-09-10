$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$cpu = Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 -HasNvidia $false
Assert-Equal $cpu.Backend 'CPU' 'Auto should select CPU without NVIDIA'
Assert-Equal $cpu.IndexUrl 'https://download.pytorch.org/whl/cpu' 'CPU should use the official CPU index'
Assert-True (-not $cpu.InstallTriton) 'CPU should not install Triton'

$cuda12 = Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 `
    -HasNvidia $true -DriverMajor 579 -ComputeCapability 8.9
Assert-Equal $cuda12.Runtime 'cu126' 'Driver branches below 580 should select cu126'
Assert-True $cuda12.InstallTriton 'Compatible CUDA x64 should install Triton'

$cuda13 = Resolve-PyTorchPlan -Architecture X64 -Backend CUDA -PythonVersion 3.14 `
    -HasNvidia $true -DriverMajor 580 -ComputeCapability 10.0
Assert-Equal $cuda13.Runtime 'cu130' 'Driver branch 580 should select cu130'
Assert-Equal $cuda13.TritonRequirement 'triton-windows==3.8.0.post28' 'PyTorch should pin the verified Triton build'

$arm = Resolve-PyTorchPlan -Architecture Arm64 -Backend Auto -PythonVersion 3.13 -HasNvidia $false
Assert-Equal $arm.Backend 'CPU' 'ARM64 should select the official CPU wheel'
Assert-True (-not $arm.InstallTriton) 'ARM64 stable stack should skip Triton'

$n1x = Resolve-PyTorchPlan -Architecture Arm64 -Backend Auto -PythonVersion 3.13 `
    -HasNvidia $true -DriverMajor 616 -ComputeCapability 12.1
Assert-Equal $n1x.Backend 'CUDA' 'RTX Spark N1X ARM64 should select CUDA'
Assert-Equal $n1x.Runtime 'cu134' 'RTX Spark N1X should use CUDA 13.4 wheel'
Assert-True ($n1x.TorchRequirement -like 'torch @ https://pypi.nvidia.com/*win_arm64.whl#sha256=*') 'N1X torch wheel should be direct, native, official, and hash pinned'
Assert-True $n1x.InstallTriton 'Compatible ARM64 CUDA preview should run Triton verification'

$rocm = Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 `
    -GpuVendor AMD -AmdGfxTarget gfx1201
Assert-Equal $rocm.Backend 'ROCm' 'Supported AMD hardware should select ROCm'
Assert-Equal $rocm.TorchRequirement 'torch[device-gfx1201]==2.13.0+rocm10.0.0' 'ROCm should select the exact supported GPU package'
Assert-True (-not $rocm.InstallTriton) 'Native Windows AMD should not claim Triton support'

$xpu = Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 -GpuVendor Intel -GpuName 'Intel(R) Arc(TM) B580 Graphics'
Assert-Equal $xpu.Backend 'XPU' 'Intel GPU should select XPU'
Assert-Equal $xpu.TorchRequirement 'torch==2.14.0+xpu' 'XPU should use the official stable wheel'
Assert-Equal $xpu.TritonRequirement 'triton-xpu==3.8.0' 'XPU should use PyTorch-managed Triton XPU'

Assert-ThrowsLike {
    Resolve-PyTorchPlan -Architecture X64 -Backend CUDA -PythonVersion 3.13 -HasNvidia $false
} '*nvidia-smi did not report*' 'Explicit CUDA should fail without usable hardware'

Assert-ThrowsLike {
    Resolve-PyTorchPlan -Architecture Arm64 -Backend Auto -PythonVersion 3.13 `
        -HasNvidia $true -DriverMajor 615 -ComputeCapability 12.1
} '*Use -Backend CPU to explicitly accept CPU-only*' 'ARM64 NVIDIA auto mode should never silently fall back to CPU'
Assert-ThrowsLike {
    Resolve-PyTorchPlan -Architecture Arm64 -Backend ROCm -PythonVersion 3.13 -GpuVendor AMD -AmdGfxTarget gfx1201
} '*not published for native Windows ARM64*' 'ROCm should reject Windows ARM64'
Assert-ThrowsLike {
    Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 -GpuVendor AMD -GpuName 'Unsupported Radeon'
} '*not in the ROCm 10.0 Windows support matrix*' 'Unsupported AMD hardware should not silently fall back to CPU'
Assert-ThrowsLike {
    Resolve-PyTorchPlan -Architecture X64 -Backend XPU -PythonVersion 3.13 -GpuVendor Intel -GpuName 'Intel HD Graphics 4000'
} '*not in the validated Windows PyTorch XPU families*' 'Unsupported Intel hardware should fail explicitly'
Assert-True (Test-IntelXpuGpuSupported -GpuName 'Intel(R) Arc(TM) 140V GPU') 'Intel Arc 140V should be accepted for XPU'
Assert-True (Test-IntelXpuGpuSupported -GpuName 'Intel(R) Arc(TM) 130V GPU') 'Intel Arc 130V should be accepted for XPU'
Assert-Equal (Select-IntelGpuName -GpuNames @('Intel(R) HD Graphics 4000', 'Intel(R) Arc(TM) B580 Graphics')) 'Intel(R) Arc(TM) B580 Graphics' 'Intel selection should prefer a supported adapter regardless of enumeration order'
$mixedXpu = Resolve-PyTorchPlan -Architecture X64 -Backend XPU -PythonVersion 3.13 `
    -GpuVendor NVIDIA -HasNvidia $true -HasIntel $true -GpuName 'Intel(R) Arc(TM) B580 Graphics'
Assert-Equal $mixedXpu.Backend 'XPU' 'Explicit XPU should select a supported secondary Intel GPU'
$mixedRocm = Resolve-PyTorchPlan -Architecture X64 -Backend ROCm -PythonVersion 3.13 `
    -GpuVendor NVIDIA -HasNvidia $true -HasAmd $true -GpuName 'AMD Radeon RX 9070 XT' -AmdGfxTarget gfx1201
Assert-Equal $mixedRocm.Backend 'ROCm' 'Explicit ROCm should select a supported secondary AMD GPU'
$autoIntelFallback = Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 `
    -GpuVendor AMD -HasAmd $true -GpuName 'Unsupported Radeon' -HasIntel $true -IntelGpuName 'Intel(R) Arc(TM) B580 Graphics'
Assert-Equal $autoIntelFallback.Backend 'XPU' 'Auto should skip unsupported AMD hardware and select a supported Intel accelerator'

Assert-PythonArchitecture -Architecture X64 -PythonMachine AMD64
Assert-PythonArchitecture -Architecture Arm64 -PythonMachine aarch64
Assert-ThrowsLike {
    Assert-PythonArchitecture -Architecture Arm64 -PythonMachine AMD64
} '*does not match Windows architecture*' 'Emulated or conflicting Python should fail before wheel installation'

$arguments = Get-PipInstallArguments -Requirement 'torch==2.14.0+cpu' `
    -IndexUrl 'https://download.pytorch.org/whl/cpu' -DryRun
Assert-Equal ($arguments -join ' ') '-m pip install --dry-run --only-binary=:all: torch==2.14.0+cpu --index-url https://download.pytorch.org/whl/cpu' 'pip command should pin the exact CPU build on the official index'
Assert-Equal $cuda12.TorchRequirement 'torch==2.14.0+cu126' 'CUDA 12 repair should require the exact backend build'
Assert-Equal $cuda13.TorchRequirement 'torch==2.14.0+cu130' 'CUDA 13 repair should require the exact backend build'

$n1xArguments = Get-PipInstallArguments -Requirement $n1x.TorchRequirement -DryRun
Assert-True (($n1xArguments -join ' ') -notlike '*--index-url*') 'Direct N1X torch wheel should leave dependency resolution on the configured default index'
Assert-True (($n1xArguments -join ' ') -like '*af0872854d183cb6894dbd5b1e5e9291875ce139d138b5fc0b501498828265d3*') 'N1X torch command should preserve the wheel hash'
$localWheelArguments = Get-PipLocalWheelInstallArguments -WheelPath 'C:\cache\torch.whl'
Assert-Equal ($localWheelArguments -join ' ') '-m pip install --only-binary=:all: C:\cache\torch.whl' 'Verified direct wheel should install from one local cached artifact'

$matchingState = [ordered]@{
    architecture = 'Arm64'
    backend = 'CUDA'
    torch = $n1x.TorchRequirement
    torchVersion = $n1x.TorchVersion
    index = $n1x.IndexUrl
    triton = $n1x.TritonRequirement
    tritonVersion = $n1x.TritonVersion
    numpy = $n1x.NumpyRequirement
    numpyVersion = $n1x.NumpyVersion
    additionalRequirements = @()
    python = '3.13'
} | ConvertTo-Json -Compress
$matchingVersions = [pscustomobject]@{
    torch = '2.15.0.dev20260904+cu134'
    numpy = '2.5.2'
    triton = '3.8.0.post28'
    torchvision = $null
    torchaudio = $null
}
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $matchingState -CurrentStateJson $matchingState -InstalledVersions $matchingVersions) 'VerifyOnly' 'Matching rerun should skip package resolution and installation'
$legacyState = [ordered]@{
    architecture = 'Arm64'
    backend = 'CUDA'
    torch = $n1x.TorchRequirement
    index = $n1x.IndexUrl
    triton = 'triton-windows>=3.8,<3.9'
    python = '3.13'
} | ConvertTo-Json -Compress
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $matchingState -CurrentStateJson $legacyState -InstalledVersions $matchingVersions) 'VerifyOnly' 'Compatible legacy state with exact installed versions should migrate without downloading packages'
$legacyCpuDesired = [ordered]@{
    architecture = 'X64'; backend = 'CPU'; torch = 'torch==2.14.0+cpu'; torchVersion = '2.14.0+cpu'
    index = 'https://download.pytorch.org/whl/cpu'; triton = $null; tritonVersion = $null
    numpy = 'numpy==2.5.2'; numpyVersion = '2.5.2'; python = '3.13'
} | ConvertTo-Json -Compress
$legacyCpuState = [ordered]@{
    architecture = 'X64'; backend = 'CPU'; torch = 'torch==2.14.0'
    index = 'https://download.pytorch.org/whl/cpu'; triton = $null; python = '3.13'
} | ConvertTo-Json -Compress
$legacyCpuVersions = [pscustomobject]@{ torch = '2.14.0+cpu'; numpy = '2.5.2'; triton = $null; torchvision = $null; torchaudio = $null }
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $legacyCpuDesired -CurrentStateJson $legacyCpuState -InstalledVersions $legacyCpuVersions) 'VerifyOnly' 'Legacy stable CPU state should migrate without downloading'
$wrongTorch = [pscustomobject]@{ torch = '2.14.0+cpu'; numpy = '2.5.2'; triton = '3.8.0.post28'; torchvision = $null; torchaudio = $null }
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $matchingState -CurrentStateJson $matchingState -InstalledVersions $wrongTorch) 'Install' 'Mismatched installed torch should repair the environment'
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $matchingState -CurrentStateJson $null -InstalledVersions $matchingVersions) 'Install' 'Missing state should not skip package installation'
$wrongBackendState = $legacyState -replace '"backend":"CUDA"', '"backend":"CPU"'
Assert-True (-not (Test-PyTorchStateCompatible -DesiredStateJson $matchingState -CurrentStateJson $wrongBackendState)) 'Backend plan changes should recreate the environment'
$noTritonState = $matchingState -replace '"triton":"triton-windows==3.8.0.post28","tritonVersion":"3.8.0.post28"', '"triton":null,"tritonVersion":null'
Assert-True (-not (Test-PyTorchStateCompatible -DesiredStateJson $noTritonState -CurrentStateJson $matchingState)) 'Disabling Triton should recreate an environment that still records Triton'
Assert-True (Test-PyTorchEnvironmentRequiresRecreation -DesiredStateJson $noTritonState -CurrentStateJson $noTritonState -InstalledVersions $matchingVersions) 'Unexpected installed Triton should recreate the environment instead of repeating pip work'
$rocmState = [ordered]@{
    architecture = 'X64'; backend = 'ROCm'; torch = $rocm.TorchRequirement; torchVersion = $rocm.TorchVersion
    index = $rocm.IndexUrl; triton = $null; tritonVersion = $null; numpy = $rocm.NumpyRequirement
    numpyVersion = $rocm.NumpyVersion; additionalRequirements = @($rocm.AdditionalRequirements); python = '3.13'
} | ConvertTo-Json -Compress
$rocmVersionsMissingVision = [pscustomobject]@{
    torch = $rocm.TorchVersion; numpy = $rocm.NumpyVersion; triton = $null; torchvision = $null; torchaudio = '2.11.0.2+rocm10.0.0'
}
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $rocmState -CurrentStateJson $rocmState -InstalledVersions $rocmVersionsMissingVision) 'Install' 'ROCm rerun should repair missing additional packages'

$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\install.ps1') -Raw
Assert-True ($installScript -match 'Get-PipInstallArguments -Requirement \$plan\.NumpyRequirement') 'PyTorch environment should include pinned NumPy'
Assert-True ($installScript -like "*if (`$packageAction -eq 'VerifyOnly')*") 'PyTorch should branch around package work on a matching rerun'
Assert-True ($installScript -match 'Install-VerifiedDownload') 'Fresh direct-wheel install should use the verified download cache'
Assert-True ($installScript -match 'Get-PipLocalWheelInstallArguments') 'Fresh direct-wheel install should install the one cached wheel'
Assert-True ($installScript -match 'tensor smoke failed') 'Matching rerun should still execute the tensor readiness probe'
Assert-True ($installScript -match 'GPU kernel smoke failed') 'Matching rerun should still execute the Triton readiness probe'
Assert-True ($installScript -notmatch '\$LASTEXITCODE') 'PyTorch should not depend on inherited LASTEXITCODE state'
$probeScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'probe.ps1') -Raw
Assert-True ($probeScript -notmatch '\$LASTEXITCODE') 'PyTorch probe should not depend on inherited LASTEXITCODE state'
Assert-True ($probeScript -match 'Invoke-DevConfigNativeCommand') 'PyTorch probe should use guarded native execution'
Assert-True ($installScript -match 'Get-Python313Path') 'PyTorch should select the installed Python 3.13 explicitly'
Assert-True ($installScript -match 'Import-MsvcEnvironment') 'Triton path should import the architecture-native MSVC build environment'
Assert-True ((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1') -Raw) -like '*PATH=$vsInstaller;%PATH%*') 'Triton compiler environment should put vswhere.exe on PATH before VsDevCmd runs'
Assert-True ($installScript -match 'Ensure-AiVisualCppTools') 'Triton should acquire its JIT compiler through direct shared setup'
Assert-True ($installScript -match 'Ensure-AiCudaToolkit') 'CUDA Triton should acquire its toolkit through direct shared setup'
Assert-True ($installScript -notmatch 'apply-configuration') 'PyTorch should not use winget configure'
Assert-True ($installScript -match "'ROCm', 'XPU'") 'PyTorch should expose AMD ROCm and Intel XPU backends'
Assert-True ($installScript -match 'xpu-smoke\.py') 'PyTorch XPU should execute torch.compile/Triton acceptance'

$fakeVs = Join-Path $env:TEMP "devconfig-vs-test-$([guid]::NewGuid().ToString('N'))"
$fakeToolset = Join-Path $fakeVs 'VC\Tools\MSVC\14.99.0\bin\Hostarm64\arm64'
$fakeVsDevCmd = Join-Path $fakeVs 'Common7\Tools\VsDevCmd.bat'
New-Item -ItemType Directory -Path $fakeToolset -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $fakeVsDevCmd) -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $fakeToolset 'cl.exe') -Force | Out-Null
New-Item -ItemType File -Path $fakeVsDevCmd -Force | Out-Null
try {
    $resolvedVsDevCmd = Resolve-VsDevCmdPath -InstallationPaths @('', $fakeVs) -Architecture Arm64
    Assert-Equal $resolvedVsDevCmd $fakeVsDevCmd 'VS discovery should skip empty output and select a Build Tools instance with ARM64 cl.exe'
    Assert-ThrowsLike {
        Resolve-VsDevCmdPath -InstallationPaths @() -Architecture Arm64
    } '*No Visual Studio Build Tools installation with an Arm64 MSVC compiler*' 'Empty vswhere output should produce an actionable error instead of a null dereference'
} finally {
    Remove-Item -LiteralPath $fakeVs -Recurse -Force -ErrorAction SilentlyContinue
}

$repeat = Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 -HasNvidia $false
Assert-Equal ($repeat | ConvertTo-Json -Compress) ($cpu | ConvertTo-Json -Compress) 'Plan resolution should be idempotent'

Write-Host "UNIT_OK: pytorch ($script:AssertionCount assertions)"
