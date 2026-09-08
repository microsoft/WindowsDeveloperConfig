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
Assert-Equal $cuda13.TritonRequirement 'triton-windows>=3.8,<3.9' 'PyTorch 2.14 should select Triton 3.8'

$arm = Resolve-PyTorchPlan -Architecture Arm64 -Backend Auto -PythonVersion 3.13 -HasNvidia $false
Assert-Equal $arm.Backend 'CPU' 'ARM64 should select the official CPU wheel'
Assert-True (-not $arm.InstallTriton) 'ARM64 stable stack should skip Triton'

$n1x = Resolve-PyTorchPlan -Architecture Arm64 -Backend Auto -PythonVersion 3.13 `
    -HasNvidia $true -DriverMajor 616 -ComputeCapability 12.1
Assert-Equal $n1x.Backend 'CUDA' 'RTX Spark N1X ARM64 should select CUDA'
Assert-Equal $n1x.Runtime 'cu134' 'RTX Spark N1X should use CUDA 13.4 wheel'
Assert-True ($n1x.TorchRequirement -like 'torch @ https://pypi.nvidia.com/*win_arm64.whl#sha256=*') 'N1X torch wheel should be direct, native, official, and hash pinned'
Assert-True $n1x.InstallTriton 'Compatible ARM64 CUDA preview should run Triton verification'

Assert-ThrowsLike {
    Resolve-PyTorchPlan -Architecture X64 -Backend CUDA -PythonVersion 3.13 -HasNvidia $false
} '*nvidia-smi did not report*' 'Explicit CUDA should fail without usable hardware'

Assert-ThrowsLike {
    Resolve-PyTorchPlan -Architecture Arm64 -Backend Auto -PythonVersion 3.13 `
        -HasNvidia $true -DriverMajor 615 -ComputeCapability 12.1
} '*Use -Backend CPU to explicitly accept CPU-only*' 'ARM64 NVIDIA auto mode should never silently fall back to CPU'

Assert-PythonArchitecture -Architecture X64 -PythonMachine AMD64
Assert-PythonArchitecture -Architecture Arm64 -PythonMachine aarch64
Assert-ThrowsLike {
    Assert-PythonArchitecture -Architecture Arm64 -PythonMachine AMD64
} '*does not match Windows architecture*' 'Emulated or conflicting Python should fail before wheel installation'

$arguments = Get-PipInstallArguments -Requirement 'torch==2.14.0' `
    -IndexUrl 'https://download.pytorch.org/whl/cpu' -DryRun
Assert-Equal ($arguments -join ' ') '-m pip install --dry-run --only-binary=:all: torch==2.14.0 --index-url https://download.pytorch.org/whl/cpu' 'pip command should be wheel-only and use the selected official index'

$n1xArguments = Get-PipInstallArguments -Requirement $n1x.TorchRequirement -DryRun
Assert-True (($n1xArguments -join ' ') -notlike '*--index-url*') 'Direct N1X torch wheel should leave dependency resolution on the configured default index'
Assert-True (($n1xArguments -join ' ') -like '*af0872854d183cb6894dbd5b1e5e9291875ce139d138b5fc0b501498828265d3*') 'N1X torch command should preserve the wheel hash'
$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\install.ps1') -Raw
Assert-True ($installScript -match "Get-PipInstallArguments -Requirement 'numpy'") 'PyTorch environment should include NumPy'
Assert-True ($installScript -match 'Get-Python313Path') 'PyTorch should select the installed Python 3.13 explicitly'
Assert-True ($installScript -match 'Import-MsvcEnvironment') 'Triton path should import the architecture-native MSVC build environment'
Assert-True ($installScript -match 'configuration\.triton\.arm64\.winget') 'ARM64 Triton should acquire its own JIT compiler dependency'
$tritonConfiguration = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\configuration.triton.arm64.winget') -Raw
Assert-True ($tritonConfiguration -match "'modify','--installPath'") 'Triton should modify the installed Build Tools instance'
Assert-True ($tritonConfiguration -match 'Microsoft\.VisualStudio\.Component\.VC\.Tools\.ARM64') 'ARM64 Triton should install the native compiler component'

$repeat = Resolve-PyTorchPlan -Architecture X64 -Backend Auto -PythonVersion 3.13 -HasNvidia $false
Assert-Equal ($repeat | ConvertTo-Json -Compress) ($cpu | ConvertTo-Json -Compress) 'Plan resolution should be idempotent'

Write-Host "UNIT_OK: pytorch ($script:AssertionCount assertions)"
