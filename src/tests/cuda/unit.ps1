$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$ready = Get-CudaReadiness -ToolkitAvailable $true -NvidiaGpuPresent $true -DriverAvailable $true
Assert-Equal $ready.Status 'Ready' 'Toolkit and driver/GPU should be ready'
Assert-True $ready.GpuReady 'GPU readiness should be true'

$toolkitOnly = Get-CudaReadiness -ToolkitAvailable $true -NvidiaGpuPresent $false -DriverAvailable $false
Assert-Equal $toolkitOnly.Status 'ToolkitOnlyNoGpu' 'Toolkit-only state should be distinct'
Assert-True (-not $toolkitOnly.GpuReady) 'Toolkit-only should not report GPU readiness'
$toolkitOnlyRepeat = Get-CudaReadiness -ToolkitAvailable $true -NvidiaGpuPresent $false -DriverAvailable $false
Assert-Equal ($toolkitOnlyRepeat | ConvertTo-Json -Compress) ($toolkitOnly | ConvertTo-Json -Compress) 'CUDA readiness should be idempotent'

$x64Plan = Resolve-CudaInstallPlan -Architecture X64
Assert-Equal $x64Plan.Method 'WinGet' 'CUDA x64 should use WinGet'
Assert-Equal $x64Plan.ToolkitVersion $null 'CUDA x64 should discover the WinGet-installed stable toolkit version'

$armPlan = Resolve-CudaInstallPlan -Architecture Arm64 -WindowsBuild 28120
Assert-Equal $armPlan.Method 'NvidiaInstaller' 'CUDA ARM64 should use NVIDIA developer-preview installer'
Assert-Equal $armPlan.ToolkitVersion '13.4' 'CUDA ARM64 should select toolkit 13.4'
Assert-Equal $armPlan.InstallerSha256 'a1f68c81160b16d519c4087788b9c07de41306c3f1b872471ceee0996621374d' 'CUDA ARM64 installer should be checksum pinned'
Assert-True ($armPlan.InstallerUrl -like 'https://packages.nvidia.com/prerelease/*windows_arm64.exe') 'CUDA ARM64 installer should use NVIDIA prerelease origin'
$cudaCandidate = (Get-AiCatalogData).Components.CudaArm64.PromotionCandidate
Assert-Equal $cudaCandidate.Version '13.4.1' 'CUDA ARM64 should track the official stable direct candidate'
Assert-Equal $cudaCandidate.Sha256 '39af79e5e136c4e0de03bba816bda60fd7b70aad033e37ecaacf9f2e2c982442' 'CUDA 13.4.1 candidate should retain the verified installer hash'
Assert-Equal $cudaCandidate.Size 3711598920 'CUDA 13.4.1 candidate should retain the verified installer size'
Assert-True ($cudaCandidate.TrackingStatus -match 'awaiting N1X') 'CUDA stable candidate should remain gated on real workload qualification'

$compile = Get-CudaKernelCompileCommand `
    -Architecture Arm64 `
    -VsDevCmd 'C:\VS\VsDevCmd.bat' `
    -Nvcc 'C:\CUDA\nvcc.exe' `
    -Source 'C:\src\smoke.cu' `
    -Output 'C:\out\smoke.exe'
Assert-True ($compile -like '*-arch=arm64 -host_arch=arm64*') 'CUDA ARM64 smoke should select native MSVC environment'
Assert-True ($compile -like '*-arch=native*smoke.cu*') 'CUDA smoke should compile for the detected GPU'
Assert-True ($compile -like '*Microsoft Visual Studio\Installer;%PATH%*') 'CUDA compiler environment should put vswhere.exe on PATH before VsDevCmd runs'

$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\cuda\install.ps1') -Raw
Assert-True ($installScript -match '\[switch\]\s*\$SkipWorkloadSmoke') 'CUDA should expose workload-smoke opt-out'
Assert-True ($installScript -match '\[int\]\s*\$DeviceIndex') 'CUDA should expose same-vendor adapter selection'
Assert-True ($installScript -match 'Get-NvidiaDriverInfo -DeviceIndex \$DeviceIndex') 'CUDA should qualify the requested NVIDIA adapter'
Assert-True ($installScript -match 'current stable CUDA 13 x64 flow requires driver 580\+') 'CUDA x64 should fail before acquisition on unsupported CUDA 13 hardware'
Assert-True ($installScript -match 'CUDA 13\.4 ARM64 Developer Preview requires driver 616\+') 'CUDA ARM64 should enforce the qualified N1X driver/device tuple'
$smokeSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\cuda\smoke.cu') -Raw
Assert-True ($smokeSource -match 'cudaSetDevice\(device_index\)') 'CUDA kernel should execute on the requested NVIDIA adapter'
Assert-True ($smokeSource -match 'cudaGetDeviceProperties') 'CUDA kernel evidence should report the actual device'
$probeScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'probe.ps1') -Raw
Assert-True ($probeScript -match 'DeviceIndex') 'CUDA verification probe should reuse the selected adapter'
$directSetup = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1') -Raw
Assert-True ($directSetup -match 'Microsoft\.VisualStudio\.Component\.VC\.Tools\.ARM64') 'Direct setup should install native compiler tools'
Assert-True ($directSetup -match 'Invoke-DevConfigProcess') 'Direct setup should use PR #93 bounded process execution'
Assert-True ($directSetup -match 'Ensure-AiCudaToolkit') 'CUDA acquisition should be shared with PyTorch'
Assert-True ($installScript -notmatch 'apply-configuration') 'CUDA should not use winget configure'
Assert-True ($installScript -match 'Ready \$kernelReady') 'CUDA report should require a successfully executed kernel for readiness'

$cleanupPath = Join-Path $env:TEMP "devconfig-cleanup-test-$([guid]::NewGuid().ToString('N')).tmp"
Set-Content -LiteralPath $cleanupPath -Value 'test'
$script:cleanupAttempts = 0
$removed = Remove-TemporaryFileWithRetry `
    -Path $cleanupPath `
    -MaxAttempts 3 `
    -DelayMilliseconds 0 `
    -RemoveAction {
        param($Target)
        $script:cleanupAttempts++
        if ($script:cleanupAttempts -lt 3) {
            throw 'installer still holds the file'
        }
        Remove-Item -LiteralPath $Target -Force
    }
Assert-True $removed 'Temporary cleanup should succeed after a delayed installer release'
Assert-Equal $script:cleanupAttempts 3 'Temporary cleanup should retry until release'
Assert-True (-not (Test-Path -LiteralPath $cleanupPath)) 'Temporary cleanup should remove the released file'

$lockedPath = Join-Path $env:TEMP "devconfig-cleanup-locked-$([guid]::NewGuid().ToString('N')).tmp"
Set-Content -LiteralPath $lockedPath -Value 'test'
$warnings = [System.Collections.Generic.List[string]]::new()
$removed = Remove-TemporaryFileWithRetry `
    -Path $lockedPath `
    -MaxAttempts 2 `
    -DelayMilliseconds 0 `
    -RemoveAction { param($Target) throw 'access denied while installer child exits' } `
    -WarningVariable cleanupWarnings
foreach ($warning in $cleanupWarnings) {
    [void]$warnings.Add($warning.Message)
}
Assert-True (-not $removed) 'Persistent cleanup failure should return false instead of throwing'
Assert-True (($warnings -join ' ') -like '*Could not remove temporary file*access denied*') 'Persistent cleanup failure should emit a useful warning'
Remove-Item -LiteralPath $lockedPath -Force

Write-Host "UNIT_OK: cuda ($script:AssertionCount assertions)"
