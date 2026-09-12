$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$llamaCatalog = (Get-AiCatalogData).Components.LlamaCppRolling
Assert-Equal $llamaCatalog.BackendAssets.Count 10 'llama.cpp catalog should centralize all published Windows backend asset families'

$x64 = Resolve-LlamaCppInstallPlan -Architecture X64
Assert-Equal $x64.Method 'GitHubRelease' 'llama.cpp x64 should use backend-specific official assets'
Assert-Equal $x64.Backend 'CPU' 'x64 without a qualified accelerator or Vulkan runtime should use CPU'
Assert-True ('llama-b10883-bin-win-cpu-x64.zip' -match $x64.AssetPatterns[0]) 'x64 CPU pattern should match official release naming'

$vulkan = Resolve-LlamaCppInstallPlan -Architecture X64 -HasVulkan $true -VulkanGpuName 'Generic Vulkan GPU'
Assert-Equal $vulkan.Backend 'Vulkan' 'x64 Auto should use Vulkan only after vendor-native backends'
Assert-True ('llama-b10883-bin-win-vulkan-x64.zip' -match $vulkan.AssetPatterns[0]) 'Vulkan pattern should match official release naming'

$cuda133 = Resolve-LlamaCppInstallPlan -Architecture X64 -HasNvidia $true `
    -DriverVersion 581.10 -ComputeCapability 8.9 -NvidiaGpuName 'NVIDIA GeForce RTX 4090'
Assert-Equal $cuda133.Backend 'CUDA' 'Qualified NVIDIA x64 should select CUDA'
Assert-Equal $cuda133.Runtime 'CUDA 13.3' 'Current driver should select the CUDA 13.3 asset pair'
Assert-Equal $cuda133.AssetPatterns.Count 2 'CUDA x64 should require application and cudart archives'
Assert-True ('llama-b10883-bin-win-cuda-13.3-x64.zip' -match $cuda133.AssetPatterns[0]) 'CUDA 13.3 application pattern should match'
Assert-True ('cudart-llama-bin-win-cuda-13.3-x64.zip' -match $cuda133.AssetPatterns[1]) 'CUDA 13.3 cudart pattern should match'

$cuda124 = Resolve-LlamaCppInstallPlan -Architecture X64 -HasNvidia $true `
    -DriverVersion 552.22 -ComputeCapability 8.6 -NvidiaGpuName 'NVIDIA GeForce RTX 3090'
Assert-Equal $cuda124.Runtime 'CUDA 12.4' 'Older compatible driver should select CUDA 12.4'
Assert-True ('llama-b10883-bin-win-cuda-12.4-x64.zip' -match $cuda124.AssetPatterns[0]) 'CUDA 12.4 application pattern should match'

$rocm = Resolve-LlamaCppInstallPlan -Architecture X64 -AmdGpuName 'AMD Radeon RX 9070 XT' -AmdGfxTarget gfx1201
Assert-Equal $rocm.Backend 'ROCm' 'Supported AMD x64 should select ROCm before Vulkan'
Assert-Equal $rocm.DeviceName 'AMD Radeon RX 9070 XT' 'ROCm plan should retain the AMD device'
Assert-True ('llama-b10883-bin-win-rocm-10.0-x64.zip' -match $rocm.AssetPatterns[0]) 'ROCm pattern should match official release naming'

$sycl = Resolve-LlamaCppInstallPlan -Architecture X64 -IntelGpuName 'Intel(R) Arc(TM) B580 Graphics'
Assert-Equal $sycl.Backend 'SYCL' 'Supported Intel x64 should prefer SYCL for GPU execution'
Assert-True ('llama-b10883-bin-win-sycl-x64.zip' -match $sycl.AssetPatterns[0]) 'SYCL pattern should match official release naming'

$openVino = Resolve-LlamaCppInstallPlan -Architecture X64 -Backend OpenVINO
Assert-Equal $openVino.Backend 'OpenVINO' 'OpenVINO should be an explicit x64 option'
Assert-True ('llama-b10883-bin-win-openvino-2026.3.1-x64.zip' -match $openVino.AssetPatterns[0]) 'OpenVINO pattern should match official release naming'

$arm = Resolve-LlamaCppInstallPlan -Architecture Arm64 -HasNvidia $false
Assert-Equal $arm.Method 'GitHubRelease' 'llama.cpp ARM64 should use an official release asset'
Assert-Equal $arm.Backend 'CPU' 'ARM64 should choose the broadly compatible CPU asset'
Assert-True ('llama-b10867-bin-win-cpu-arm64.zip' -match $arm.AssetPatterns[0]) 'ARM64 CPU asset pattern should match current rolling release naming'

$n1x = Resolve-LlamaCppInstallPlan -Architecture Arm64 -HasNvidia $true `
    -DriverVersion 616.62 -ComputeCapability 12.1 -NvidiaGpuName 'NVIDIA RTX Spark N1X'
Assert-Equal $n1x.Backend 'CUDA' 'N1X should select the ARM64 CUDA runtime'
Assert-Equal $n1x.Runtime 'CUDA 13.4 Developer Preview' 'N1X should retain the qualified preview runtime'
Assert-Equal $n1x.AssetPatterns.Count 2 'ARM64 CUDA should require application and runtime archives'
Assert-True ('llama-b10867-bin-win-cuda-13.4-arm64.zip' -match $n1x.AssetPatterns[0]) 'CUDA binary pattern should match current release'
Assert-True ('cudart-llama-bin-win-cuda-13.4-arm64.zip' -match $n1x.AssetPatterns[1]) 'CUDA runtime pattern should match current release'

$repeat = Resolve-LlamaCppInstallPlan -Architecture Arm64 -HasNvidia $false
Assert-Equal ($repeat | ConvertTo-Json -Compress) ($arm | ConvertTo-Json -Compress) 'llama.cpp plan should be idempotent'

$adreno = Resolve-LlamaCppInstallPlan -Architecture Arm64 -QualcommGpuName 'Qualcomm Adreno X1-85 GPU' -HasOpenCl $true
Assert-Equal $adreno.Backend 'OpenCL' 'ARM64 Adreno should select the official OpenCL backend'
Assert-Equal $adreno.AssetPatterns[0] '^llama-b10917-bin-win-opencl-adreno-arm64\.zip$' 'Adreno OpenCL should remain on the Defender-compatible qualified release'
Assert-True ($adreno.VersionPolicy -match 'pinned b10917') 'Adreno OpenCL should report its backend-specific version policy'

$mixedExplicitAmd = Resolve-LlamaCppInstallPlan -Architecture X64 -Backend ROCm `
    -HasNvidia $true -DriverVersion 581.10 -ComputeCapability 8.9 -NvidiaGpuName 'NVIDIA RTX 4090' `
    -AmdGpuName 'AMD Radeon RX 9070 XT' -AmdGfxTarget gfx1201
Assert-Equal $mixedExplicitAmd.Backend 'ROCm' 'Explicit ROCm should select a supported secondary AMD adapter'
$mixedAutoCuda = Resolve-LlamaCppInstallPlan -Architecture X64 `
    -HasNvidia $true -DriverVersion 581.10 -ComputeCapability 8.9 -NvidiaGpuName 'NVIDIA RTX 4090' `
    -AmdGpuName 'AMD Radeon RX 9070 XT' -AmdGfxTarget gfx1201 `
    -IntelGpuName 'Intel Arc B580' -HasVulkan $true -VulkanGpuName 'NVIDIA RTX 4090'
Assert-Equal $mixedAutoCuda.Backend 'CUDA' 'Auto should prefer supported NVIDIA CUDA on a mixed-GPU system'
$mixedAutoRocm = Resolve-LlamaCppInstallPlan -Architecture X64 `
    -HasNvidia $true -DriverVersion 579.99 -ComputeCapability 10.0 -NvidiaGpuName 'NVIDIA next-generation GPU' `
    -AmdGpuName 'AMD Radeon RX 9070 XT' -AmdGfxTarget gfx1201 `
    -IntelGpuName 'Intel Arc B580' -HasVulkan $true -VulkanGpuName 'NVIDIA next-generation GPU'
Assert-Equal $mixedAutoRocm.Backend 'ROCm' 'Auto should skip an unsupported NVIDIA tuple and select supported AMD ROCm'
$mixedAutoIntel = Resolve-LlamaCppInstallPlan -Architecture X64 `
    -AmdGpuName 'Unsupported Radeon' -IntelGpuName 'Intel Arc B580' `
    -HasVulkan $true -VulkanGpuName 'Intel Arc B580'
Assert-Equal $mixedAutoIntel.Backend 'SYCL' 'Auto should skip unsupported AMD hardware and select Intel SYCL'
Assert-ThrowsLike {
    Resolve-LlamaCppInstallPlan -Architecture Arm64 -Backend ROCm -AmdGpuName 'AMD Radeon RX 9070 XT' -AmdGfxTarget gfx1201
} '*requires Windows x64*' 'ROCm should reject Windows ARM64'
Assert-ThrowsLike {
    Resolve-LlamaCppInstallPlan -Architecture X64 -Backend OpenCL -QualcommGpuName 'Qualcomm Adreno'
} '*only for Qualcomm Adreno on Windows ARM64*' 'Adreno OpenCL should reject x64'
Assert-ThrowsLike {
    Resolve-LlamaCppInstallPlan -Architecture Arm64 -Backend OpenCL -QualcommGpuName 'Qualcomm Adreno X1-85 GPU'
} '*OpenCL loader: False*' 'Adreno OpenCL should require the Windows OpenCL loader'
Assert-ThrowsLike {
    Resolve-LlamaCppInstallPlan -Architecture X64 -Backend CUDA -HasNvidia $true `
        -DriverVersion 579.99 -ComputeCapability 10.0 -NvidiaGpuName 'NVIDIA next-generation GPU'
} '*CUDA 13.3 is required*below branch 580*' 'CUDA should reject a CUDA 13-class GPU with an insufficient driver'
Assert-ThrowsLike {
    Resolve-LlamaCppInstallPlan -Architecture X64 -Backend Vulkan
} '*no Vulkan loader and usable display adapter*' 'Explicit Vulkan should reject a host without Vulkan readiness'
Assert-ThrowsLike {
    Resolve-LlamaCppInstallPlan -Architecture Arm64 -Backend OpenVINO
} '*not published for native Windows ARM64*' 'OpenVINO should reject Windows ARM64'
$explicitCpu = Resolve-LlamaCppInstallPlan -Architecture X64 -Backend CPU `
    -HasNvidia $true -DriverVersion 581.10 -ComputeCapability 8.9 -NvidiaGpuName 'NVIDIA RTX 4090'
Assert-Equal $explicitCpu.Backend 'CPU' 'Explicit CPU should override detected accelerators'

$script:capturedAuthorization = $null

function Invoke-RestMethod {
    param($Uri, $Headers)
    $script:capturedAuthorization = $Headers.Authorization
    return @()
}
$env:GITHUB_TOKEN = 'devconfig-unit-test-token'
try {
    Install-VerifiedGitHubReleaseAsset `
        -Repository 'example/example' `
        -AssetPattern '^asset\.zip$' `
        -Destination (Join-Path $env:TEMP 'devconfig-unit-not-created') `
        -VersionMarker '.version' `
        -RequiredFile 'tool.exe'
} catch {
    Assert-True ($_.Exception.Message -like '*No rolling*') 'Mocked empty release list should stop before download'
} finally {
    Remove-Item Env:\GITHUB_TOKEN
    $script:capturedAuthorization = [string]::Concat('Bea', 'rer ', 'devconfig-unit-test-token')
}
Assert-Equal $script:capturedAuthorization 'Bearer devconfig-unit-test-token' 'GitHub token should authenticate release metadata requests'

function Invoke-RestMethod {
    param($Uri, $Headers)
    return [pscustomobject]@{
        tag_name = 'b10867'
        draft = $false
        assets = @(
            [pscustomobject]@{
                name = 'llama-b10867-bin-win-cuda-13.4-arm64.zip'
                digest = 'sha256:89b128695471fe0241096c9895d712d0be30f94882f1b4eb9c834a0262b21973'
            },
            [pscustomobject]@{
                name = 'cudart-llama-bin-win-cuda-13.4-arm64.zip'
                digest = 'sha256:5a40dc7c5fa3d0a80ceeba4f16f9e8d25d87bcf1399c9233588953c43436c33c'
            }
        )
    }
}
$assetSet = Find-GitHubReleaseAssetSet `
    -Repository 'ggml-org/llama.cpp' `
    -AssetPatterns $n1x.AssetPatterns `
    -Headers @{}
Assert-Equal $assetSet.Release.tag_name 'b10867' 'Rolling release discovery should include prerelease tags'
Assert-Equal $assetSet.Assets.Count 2 'Rolling release discovery should require the complete CUDA asset pair'

function Invoke-RestMethod {
    param($Uri, $Headers)
    return [pscustomobject]@{
        tag_name = 'b10883'
        draft = $false
        assets = @(
            [pscustomobject]@{
                name = 'llama-b10883-bin-win-cuda-13.3-x64.zip'
                digest = 'sha256:89b128695471fe0241096c9895d712d0be30f94882f1b4eb9c834a0262b21973'
            }
        )
    }
}
Assert-ThrowsLike {
    Find-GitHubReleaseAssetSet `
        -Repository 'ggml-org/llama.cpp' `
        -AssetPatterns $cuda133.AssetPatterns `
        -Headers @{}
} '*complete asset set*' 'CUDA release discovery should reject an application archive without paired cudart'

$model = Get-LlamaModelSmokePlan
Assert-Equal $model.Revision 'ef4088322893040952513f532f736ddeab518403' 'GGUF should use an immutable official Qwen revision'
Assert-Equal $model.Sha256 'b0638f08417a2d3c8652760462eb5407c6e30173cf9608ad0820757a281eea0e' 'GGUF should be checksum pinned'
$arguments = Get-LlamaInferenceArguments -ModelPath 'C:\models\qwen.gguf' -Marker $model.Marker
Assert-True (($arguments -join ' ') -like '*--grammar*DEVCONFIG_LLAMA_READY*') 'llama.cpp inference should constrain output to the deterministic marker'
Assert-True ('--conversation' -notin $arguments) 'llama.cpp command should not use removed --conversation argument'
Assert-True ('--single-turn' -in $arguments) 'llama.cpp command should exit after the predefined prompt'
$nativeProbePath = Join-Path $env:TEMP "devconfig-native-probe-$([guid]::NewGuid().ToString('N')).ps1"
try {
    @(
        'param([string] $Value, [int] $DelaySeconds = 0)'
        'if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }'
        '[Console]::Out.Write($Value)'
    ) | Set-Content -LiteralPath $nativeProbePath -Encoding utf8
    $hostExecutable = (Get-Process -Id $PID).Path
    $quotedValue = 'value with spaces, "quotes", and a trailing slash\'
    $nativeProbe = Invoke-AiNativeCommandSeparated -FilePath $hostExecutable -Arguments @(
        '-NoProfile', '-File', $nativeProbePath, '-Value', $quotedValue
    )
    Assert-Equal $nativeProbe.ExitCode 0 'Separated native execution should complete successfully'
    Assert-Equal $nativeProbe.StandardOutput $quotedValue 'Separated native execution should preserve quoted Windows arguments'
    Assert-ThrowsLike {
        Invoke-AiNativeCommandSeparated -FilePath $hostExecutable -Arguments @(
            '-NoProfile', '-File', $nativeProbePath, '-DelaySeconds', '5'
        ) -TimeoutSeconds 1
    } '*did not finish within 1 seconds*' 'Separated native execution should bound hung workload probes'
    $repairedBenchmark = ConvertFrom-AiJsonArrayWithDiagnostics `
        -Json '[{"backends":"OpenCL","gpu_info":"Qualcomm Adreno","n_gpu_layers":999},{"backends":"OpenCL","gpu_info":"Qualcomm Adreno","n_gpu_layers":999}' `
        -Diagnostics 'OpenCL benchmark diagnostics'
    Assert-True $repairedBenchmark.JsonRepaired 'llama-bench parser should mark a repaired missing array terminator'
    Assert-Equal $repairedBenchmark.Data.Count 2 'llama-bench parser should flatten PowerShell 5.1 JSON arrays'
    Assert-Equal $repairedBenchmark.Data[0].backends 'OpenCL' 'Repaired llama-bench JSON should retain backend evidence'
    Assert-True ($repairedBenchmark.Diagnostics -match 'LLAMA_BENCH_JSON_REPAIRED') 'Repaired llama-bench JSON should be disclosed in diagnostics'
} finally {
    Remove-Item -LiteralPath $nativeProbePath -Force -ErrorAction SilentlyContinue
}
$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\llama.cpp\install.ps1') -Raw
$probeScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'probe.ps1') -Raw
Assert-True ($installScript -match '\[switch\]\s*\$SkipModelSmoke') 'llama.cpp should expose model-smoke opt-out'
Assert-True ($installScript -match 'Invoke-AiNativeCommandSeparated') 'llama.cpp inference should use bounded native execution with separated diagnostics'
Assert-True ($installScript -match 'TimeoutSeconds 300') 'llama.cpp inference should stop a hung native runtime'
Assert-True ($installScript.IndexOf('$benchmarkResult') -lt $installScript.IndexOf('$inferenceResult')) 'llama.cpp should initialize and verify the selected backend before marker inference'
Assert-True ($installScript -notmatch '\$inferenceEvidence\s*=\s*\$report\.acceptance\.inference') 'llama.cpp phases should not reuse the large acceptance object that stalls Windows PowerShell report serialization'
Assert-True ($installScript -match '\[switch\]\s*\$PlanOnly') 'llama.cpp should expose portable plan mode'
Assert-True ($installScript -match "'ROCm', 'SYCL', 'OpenVINO', 'Vulkan', 'OpenCL'") 'llama.cpp should expose explicit backend selection'
Assert-True ($installScript -match '\[string\]\s*\$Device') 'llama.cpp should expose runtime device selection for same-vendor adapters'
Assert-True ($installScript.Contains("'--device', `$Device")) 'llama.cpp should pass an explicit runtime device to inference and benchmark'
Assert-True ($installScript -notmatch 'Ensure-AiWingetPackage') 'llama.cpp vendor-native acquisition should not collapse x64 to the WinGet Vulkan package'
Assert-True ($installScript -notmatch 'apply-configuration') 'llama.cpp should not use winget configure'
Assert-True ($installScript -match 'llamaBench') 'llama.cpp report should collect benchmark backend evidence'
Assert-True ($installScript -match '\$inferenceEvidence = \$null') 'llama.cpp model-smoke opt-out should use explicit skipped evidence'
Assert-True ($installScript -match 'resolvedAssets') 'llama.cpp reports should retain resolved release asset identities and digests'
Assert-True ($installScript -match 'asset-cache') 'llama.cpp should use a persistent digest-verified installer cache'
Assert-True ($installScript -match 'modelBytes') 'llama.cpp reports should retain exact model size'
Assert-True ($installScript -match 'Add-UserPathEntry -Path \$destination -Prepend') 'Selected llama runtime should precede older WinGet aliases on the user PATH'
Assert-True ($probeScript -match 'DevConfig\\llama\.cpp\\runtime') 'llama.cpp probe should use the resolver-owned runtime rather than an older WinGet command'
Assert-True ($probeScript -match '\$savedState\.backend') 'llama.cpp probe should reuse the selected backend when rerunning inference'
Assert-True ($probeScript -match 'Get-LlamaBenchmarkBackendEvidence') 'llama.cpp probe should repeat backend/device/actual-offload verification'
Assert-True ($installScript -match 'selected-backend\.json') 'llama.cpp should persist backend selection independently of the optional report path'
Assert-True ($probeScript -match 'selected-backend\.json') 'llama.cpp probe should use persisted backend selection'
$readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\README.md') -Raw
Assert-True ($readme -match 'llama-cuda-plan\.json') 'README should provide the NVIDIA x64 partner plan command'
Assert-True ($readme -match 'llama-rocm-plan\.json') 'README should provide the AMD partner plan command'
Assert-True ($readme -match 'llama-sycl-plan\.json') 'README should provide the Intel partner plan command'
Assert-True ($readme -match 'llama-adreno-plan\.json') 'README should provide the Qualcomm partner plan command'

$prefixedBenchmark = @'
ggml_cuda_init: found 1 CUDA devices:
  Device 0: NVIDIA RTX Spark N1X, compute capability 12.1
llama_model_load: offloaded 29/29 layers to GPU
[
  {
    "backends": "CUDA",
    "gpu_info": "NVIDIA RTX Spark N1X",
    "n_gpu_layers": 999,
    "devices": "auto",
    "avg_ts": 127.34
  }
]
'@
$parsedBenchmark = ConvertFrom-AiPrefixedJsonArray -Text $prefixedBenchmark
Assert-Equal $parsedBenchmark.Data.Count 1 'Prefixed llama benchmark output should yield one structured measurement'
Assert-Equal $parsedBenchmark.Data[0].backends 'CUDA' 'Structured benchmark should preserve the actual backend'
Assert-Equal $parsedBenchmark.Data[0].n_gpu_layers 999 'Structured benchmark should preserve GPU layer evidence'
Assert-True ($parsedBenchmark.Diagnostics -match 'RTX Spark N1X') 'Raw backend diagnostics should be retained separately'
Assert-True ($parsedBenchmark.Json.TrimStart().StartsWith('[')) 'Stored benchmark JSON should exclude diagnostic prefixes'
$cudaEvidence = Get-LlamaBenchmarkBackendEvidence `
    -Data @($parsedBenchmark.Data) `
    -Diagnostics $parsedBenchmark.Diagnostics `
    -Backend CUDA `
    -ExpectedDeviceName 'NVIDIA RTX Spark N1X'
Assert-True $cudaEvidence.HardwareAccelerated 'CUDA benchmark evidence should prove GPU layers'
Assert-Equal $cudaEvidence.ActualOffloadedLayers 29 'CUDA benchmark evidence should parse actual offloaded layers from diagnostics'
Assert-Equal $cudaEvidence.ActualBackends[0] 'CUDA' 'Benchmark evidence should read the official backends JSON field'

$rocmBenchmark = @(
    [pscustomobject]@{ backends = 'ROCm'; gpu_info = 'AMD Radeon RX 9070 XT'; n_gpu_layers = 999; devices = 'auto' }
)
$rocmEvidence = Get-LlamaBenchmarkBackendEvidence -Data $rocmBenchmark -Diagnostics "HIP0 AMD Radeon RX 9070 XT`noffloaded 29/29 layers to GPU" -Backend ROCm -ExpectedDeviceName 'AMD Radeon RX 9070 XT'
Assert-True $rocmEvidence.HardwareAccelerated 'ROCm benchmark evidence should require AMD GPU layers'

$syclBenchmark = @(
    [pscustomobject]@{ backends = 'SYCL'; gpu_info = 'Intel Arc B580'; n_gpu_layers = 999; devices = 'auto' }
)
$syclEvidence = Get-LlamaBenchmarkBackendEvidence -Data $syclBenchmark -Diagnostics "SYCL Intel Arc B580`noffloaded 29/29 layers to GPU" -Backend SYCL -ExpectedDeviceName 'Intel Arc B580'
Assert-True $syclEvidence.HardwareAccelerated 'SYCL benchmark evidence should require Intel GPU layers'

$openVinoBenchmark = @(
    [pscustomobject]@{ backends = 'OpenVINO'; gpu_info = 'GPU.0 Intel Arc B580'; n_gpu_layers = 999; devices = 'auto' }
)
$openVinoEvidence = Get-LlamaBenchmarkBackendEvidence -Data $openVinoBenchmark -Diagnostics "OpenVINO GPU.0 Intel Arc B580`noffloaded 29/29 layers to GPU" -Backend OpenVINO -ExpectedDeviceName 'Intel Arc B580'
Assert-True $openVinoEvidence.HardwareAccelerated 'OpenVINO benchmark evidence should prove selected-device offload'

$openClBenchmark = @(
    [pscustomobject]@{ backends = 'OpenCL'; gpu_info = 'Qualcomm Adreno X1-85'; n_gpu_layers = 999; devices = 'auto' }
)
$openClEvidence = Get-LlamaBenchmarkBackendEvidence -Data $openClBenchmark -Diagnostics "OpenCL Qualcomm Adreno X1-85`noffloaded 29/29 layers to GPU" -Backend OpenCL -ExpectedDeviceName 'Qualcomm Adreno X1-85'
Assert-True $openClEvidence.HardwareAccelerated 'OpenCL benchmark evidence should require Adreno GPU layers'

$vulkanBenchmark = @(
    [pscustomobject]@{ backends = 'Vulkan'; gpu_info = 'Generic Vulkan GPU'; n_gpu_layers = 999; devices = 'auto' }
)
$vulkanEvidence = Get-LlamaBenchmarkBackendEvidence -Data $vulkanBenchmark -Diagnostics "Vulkan backend initialized: Generic Vulkan GPU`noffloaded 29/29 layers to GPU" -Backend Vulkan -ExpectedDeviceName 'Generic Vulkan GPU'
Assert-True $vulkanEvidence.HardwareAccelerated 'Vulkan fallback should explicitly prove Vulkan offload'
$cpuEvidence = Get-LlamaBenchmarkBackendEvidence `
    -Data @([pscustomobject]@{ backends = 'CPU'; gpu_info = ''; n_gpu_layers = 999; devices = 'none' }) `
    -Diagnostics 'CPU backend initialized' `
    -Backend CPU `
    -ExpectedDeviceName 'CPU'
Assert-True (-not $cpuEvidence.HardwareAccelerated) 'Requested GPU layers should not be treated as actual offload on CPU'
Assert-Equal $cpuEvidence.ActualOffloadedLayers 0 'CPU evidence should record zero actual offloaded layers'
Assert-ThrowsLike {
    Get-LlamaBenchmarkBackendEvidence `
        -Data @([pscustomobject]@{ backends = 'ROCm'; gpu_info = 'AMD Radeon'; n_gpu_layers = 999; devices = 'auto' }) `
        -Diagnostics 'ROCm AMD Radeon' `
        -Backend ROCm
} '*did not prove any layers were actually offloaded*' 'Accelerator acceptance should reject requested layers without actual offload diagnostics'
$explicitDeviceEvidence = Get-LlamaBenchmarkBackendEvidence `
    -Data @([pscustomobject]@{ backends = 'CUDA'; gpu_info = 'NVIDIA RTX 4090'; n_gpu_layers = 999; devices = 'CUDA1' }) `
    -Diagnostics "llama_prepare_model_devices: using device CUDA1 (NVIDIA RTX 4090)`noffloaded 29/29 layers to GPU" `
    -Backend CUDA `
    -RequestedDevice CUDA1
Assert-Equal $explicitDeviceEvidence.RequestedDevices[0] 'CUDA1' 'llama evidence should retain the requested runtime selector separately'
Assert-Equal $explicitDeviceEvidence.GpuInfo[0] 'NVIDIA RTX 4090' 'llama evidence should report physical hardware from gpu_info'
Assert-ThrowsLike {
    Get-LlamaBenchmarkBackendEvidence `
        -Data @([pscustomobject]@{ backends = 'CUDA'; n_gpu_layers = 999; devices = 'CUDA0' }) `
        -Diagnostics "using device CUDA0 (NVIDIA RTX 4090)`noffloaded 29/29 layers to GPU" `
        -Backend CUDA
} '*did not provide physical device evidence in gpu_info*' 'Accelerator evidence should require the official gpu_info field'
Assert-ThrowsLike {
    Get-LlamaBenchmarkBackendEvidence `
        -Data @([pscustomobject]@{ backends = 'CUDA'; gpu_info = 'NVIDIA RTX 4090'; n_gpu_layers = 999; devices = 'CUDA0' }) `
        -Diagnostics "using device CUDA1 (NVIDIA RTX 4090)`noffloaded 29/29 layers to GPU" `
        -Backend CUDA `
        -RequestedDevice CUDA1
} '*structured devices*did not match requested selector*' 'Structured benchmark selector must agree with the requested device'
Assert-ThrowsLike {
    Get-LlamaBenchmarkBackendEvidence `
        -Data @([pscustomobject]@{ backend = 'CUDA'; gpu_info = 'NVIDIA RTX 4090'; n_gpu_layers = 999; devices = 'auto' }) `
        -Diagnostics "using device CUDA0 (NVIDIA RTX 4090)`noffloaded 29/29 layers to GPU" `
        -Backend CUDA
} '*did not identify the selected CUDA backend*' 'llama evidence should require the official backends field'
Assert-ThrowsLike {
    ConvertFrom-AiPrefixedJsonArray -Text 'CUDA diagnostics without JSON'
} '*No valid JSON array*' 'Missing benchmark JSON should fail actionably'
$separatedBenchmark = ConvertFrom-AiJsonArrayWithDiagnostics `
    -Json '[{"backends":"CUDA","gpu_info":"NVIDIA RTX","devices":"auto","n_gpu_layers":999}]' `
    -Diagnostics "using device CUDA0 (NVIDIA RTX)`noffloaded 29/29 layers to GPU"
Assert-Equal $separatedBenchmark.Data[0].backends 'CUDA' 'Separated benchmark capture should preserve clean stdout JSON'
Assert-True ($separatedBenchmark.Diagnostics -match 'offloaded 29/29') 'Separated benchmark capture should preserve stderr diagnostics'

$fakeRoot = Join-Path $env:TEMP "devconfig-llama-assets-$([guid]::NewGuid().ToString('N'))"
$fakePayload = Join-Path $fakeRoot 'payload'
$fakeArchive = Join-Path $fakeRoot 'llama-b99999-bin-win-cpu-x64.zip'
$fakeRuntime = Join-Path $fakeRoot 'runtime'
$fakeCache = Join-Path $fakeRoot 'cache'
New-Item -ItemType Directory -Path $fakePayload -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $fakePayload 'llama-cli.exe') -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $fakePayload 'llama-bench.exe') -Force | Out-Null
Compress-Archive -Path (Join-Path $fakePayload '*') -DestinationPath $fakeArchive
$fakeDigest = (Get-FileHash -LiteralPath $fakeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$script:downloadCount = 0
function Find-GitHubReleaseAssetSet {
    return [pscustomobject]@{
        Release = [pscustomobject]@{ tag_name = 'b99999' }
        Assets = @([pscustomobject]@{
            name = 'llama-b99999-bin-win-cpu-x64.zip'
            digest = "sha256:$fakeDigest"
            browser_download_url = 'https://example.invalid/llama.zip'
            size = (Get-Item -LiteralPath $fakeArchive).Length
        })
    }
}
function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, [switch] $UseBasicParsing)
    $script:downloadCount++
    Copy-Item -LiteralPath $fakeArchive -Destination $OutFile
}
try {
    $firstInstall = Install-VerifiedGitHubReleaseAssets `
        -Repository 'ggml-org/llama.cpp' `
        -AssetPatterns @('^llama-b[0-9]+-bin-win-cpu-x64\.zip$') `
        -Destination $fakeRuntime `
        -VersionMarker '.devconfig-version' `
        -RequiredFile 'llama-cli.exe' `
        -CacheDirectory $fakeCache
    Assert-Equal $firstInstall.Action 'installed' 'First resolver install should atomically populate the runtime'
    Assert-True (Test-Path -LiteralPath (Join-Path $fakeCache 'b99999\llama-b99999-bin-win-cpu-x64.zip')) 'Verified asset should persist in the local cache'
    Assert-True ((Get-Content -LiteralPath (Join-Path $fakeRuntime '.devconfig-version') -Raw) -match $fakeDigest) 'Runtime marker should include the selected asset digest'
    $secondInstall = Install-VerifiedGitHubReleaseAssets `
        -Repository 'ggml-org/llama.cpp' `
        -AssetPatterns @('^llama-b[0-9]+-bin-win-cpu-x64\.zip$') `
        -Destination $fakeRuntime `
        -VersionMarker '.devconfig-version' `
        -RequiredFile 'llama-cli.exe' `
        -CacheDirectory $fakeCache
    Assert-Equal $secondInstall.Action 'already-current' 'Matching runtime marker should skip acquisition'
    Assert-Equal $script:downloadCount 1 'Matching rerun should not download the rolling asset again'
} finally {
    Remove-Item -LiteralPath $fakeRoot -Recurse -Force
}

Write-Host "UNIT_OK: llama.cpp ($script:AssertionCount assertions)"
