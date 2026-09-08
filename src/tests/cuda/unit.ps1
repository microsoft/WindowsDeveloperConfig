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
Assert-Equal $x64Plan.ToolkitVersion '13.3' 'CUDA x64 should use the current catalog toolkit'

$armPlan = Resolve-CudaInstallPlan -Architecture Arm64 -WindowsBuild 28120
Assert-Equal $armPlan.Method 'NvidiaInstaller' 'CUDA ARM64 should use NVIDIA developer-preview installer'
Assert-Equal $armPlan.ToolkitVersion '13.4' 'CUDA ARM64 should select toolkit 13.4'
Assert-Equal $armPlan.InstallerSha256 'a1f68c81160b16d519c4087788b9c07de41306c3f1b872471ceee0996621374d' 'CUDA ARM64 installer should be checksum pinned'
Assert-True ($armPlan.InstallerUrl -like 'https://packages.nvidia.com/prerelease/*windows_arm64.exe') 'CUDA ARM64 installer should use NVIDIA prerelease origin'

$compile = Get-CudaKernelCompileCommand `
    -Architecture Arm64 `
    -VsDevCmd 'C:\VS\VsDevCmd.bat' `
    -Nvcc 'C:\CUDA\nvcc.exe' `
    -Source 'C:\src\smoke.cu' `
    -Output 'C:\out\smoke.exe'
Assert-True ($compile -like '*-arch=arm64 -host_arch=arm64*') 'CUDA ARM64 smoke should select native MSVC environment'
Assert-True ($compile -like '*-arch=native*smoke.cu*') 'CUDA smoke should compile for the detected GPU'

$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\cuda\install.ps1') -Raw
Assert-True ($installScript -match '\[switch\]\s*\$SkipWorkloadSmoke') 'CUDA should expose workload-smoke opt-out'
$armConfiguration = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\cuda\configuration.arm64.winget') -Raw
Assert-True ($armConfiguration -match "'modify','--installPath'") 'CUDA ARM64 should modify the installed Build Tools instance'
Assert-True ($armConfiguration -match 'Microsoft\.VisualStudio\.Component\.VC\.Tools\.ARM64') 'CUDA ARM64 should install native compiler tools'

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
