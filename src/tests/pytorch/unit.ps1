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
    python = '3.13'
} | ConvertTo-Json -Compress
$matchingVersions = [pscustomobject]@{
    torch = '2.15.0.dev20260904+cu134'
    numpy = '2.5.2'
    triton = '3.8.0.post28'
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
$legacyCpuVersions = [pscustomobject]@{ torch = '2.14.0+cpu'; numpy = '2.5.2'; triton = $null }
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $legacyCpuDesired -CurrentStateJson $legacyCpuState -InstalledVersions $legacyCpuVersions) 'VerifyOnly' 'Legacy stable CPU state should migrate without downloading'
$wrongTorch = [pscustomobject]@{ torch = '2.14.0+cpu'; numpy = '2.5.2'; triton = '3.8.0.post28' }
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $matchingState -CurrentStateJson $matchingState -InstalledVersions $wrongTorch) 'Install' 'Mismatched installed torch should repair the environment'
Assert-Equal (Get-PyTorchPackageAction -DesiredStateJson $matchingState -CurrentStateJson $null -InstalledVersions $matchingVersions) 'Install' 'Missing state should not skip package installation'
$wrongBackendState = $legacyState -replace '"backend":"CUDA"', '"backend":"CPU"'
Assert-True (-not (Test-PyTorchStateCompatible -DesiredStateJson $matchingState -CurrentStateJson $wrongBackendState)) 'Backend plan changes should recreate the environment'
$noTritonState = $matchingState -replace '"triton":"triton-windows==3.8.0.post28","tritonVersion":"3.8.0.post28"', '"triton":null,"tritonVersion":null'
Assert-True (-not (Test-PyTorchStateCompatible -DesiredStateJson $noTritonState -CurrentStateJson $matchingState)) 'Disabling Triton should recreate an environment that still records Triton'
Assert-True (Test-PyTorchEnvironmentRequiresRecreation -DesiredStateJson $noTritonState -CurrentStateJson $noTritonState -InstalledVersions $matchingVersions) 'Unexpected installed Triton should recreate the environment instead of repeating pip work'

$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\install.ps1') -Raw
Assert-True ($installScript -match 'Get-PipInstallArguments -Requirement \$plan\.NumpyRequirement') 'PyTorch environment should include pinned NumPy'
Assert-True ($installScript -like "*if (`$packageAction -eq 'VerifyOnly')*") 'PyTorch should branch around package work on a matching rerun'
Assert-True ($installScript -match 'Install-VerifiedDownload') 'Fresh direct-wheel install should use the verified download cache'
Assert-True ($installScript -match 'Get-PipLocalWheelInstallArguments') 'Fresh direct-wheel install should install the one cached wheel'
Assert-True ($installScript -match 'PyTorch tensor smoke test') 'Matching rerun should still execute the tensor readiness probe'
Assert-True ($installScript -match 'Triton Windows GPU kernel smoke test') 'Matching rerun should still execute the Triton readiness probe'
Assert-True ($installScript -match 'Get-Python313Path') 'PyTorch should select the installed Python 3.13 explicitly'
Assert-True ($installScript -match 'Import-MsvcEnvironment') 'Triton path should import the architecture-native MSVC build environment'
Assert-True ((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1') -Raw) -like '*PATH=$vsInstaller;%PATH%*') 'Triton compiler environment should put vswhere.exe on PATH before VsDevCmd runs'
Assert-True ($installScript -match 'configuration\.triton\.arm64\.winget') 'ARM64 Triton should acquire its own JIT compiler dependency'
$tritonConfiguration = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\configuration.triton.arm64.winget') -Raw
Assert-True ($tritonConfiguration -match 'vs_BuildTools\.exe') 'Triton should use the Build Tools bootstrapper'
Assert-True ($tritonConfiguration -match 'Get-AuthenticodeSignature') 'Triton should verify the bootstrapper signer'
Assert-True ($tritonConfiguration -like '*$env:ProgramFiles*WindowsDeveloperConfig\Installers*') 'Triton should stage the elevated bootstrapper outside user-writable temp'
Assert-True ($tritonConfiguration -like '*& $bootstrapper modify --installPath $installPath*') 'Triton should preserve the spaced install path as one PowerShell argument'
Assert-True ($tritonConfiguration -like "*`$signerName -ne 'Microsoft Corporation'*") 'Triton should require the exact Microsoft bootstrapper signer'
Assert-True ($tritonConfiguration -match '--quiet --wait --norestart') 'Triton should make the bootstrapper wait for the installer service'
Assert-True ($tritonConfiguration -match 'Microsoft\.VisualStudio\.Component\.VC\.Tools\.ARM64') 'ARM64 Triton should install the native compiler component'
Assert-True ($tritonConfiguration -match 'ARM64 cl\.exe is absent') 'Triton configuration should fail before success when the compiler did not materialize'

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
