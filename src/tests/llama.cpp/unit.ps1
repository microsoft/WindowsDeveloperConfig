$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$x64 = Resolve-LlamaCppInstallPlan -Architecture X64
Assert-Equal $x64.Method 'WinGet' 'llama.cpp x64 should use WinGet'
Assert-Equal $x64.PackageId 'ggml.llamacpp' 'llama.cpp x64 should use the catalog package'
Assert-Equal $x64.Backend 'Vulkan' 'WinGet package backend should be explicit'
Assert-Equal $x64.AssetPatterns.Count 0 'llama.cpp x64 reporting should expose an empty asset set'

$arm = Resolve-LlamaCppInstallPlan -Architecture Arm64 -HasNvidia $false
Assert-Equal $arm.Method 'GitHubRelease' 'llama.cpp ARM64 should use an official release asset'
Assert-Equal $arm.Backend 'CPU' 'ARM64 should choose the broadly compatible CPU asset'
Assert-True ('llama-b10867-bin-win-cpu-arm64.zip' -match $arm.AssetPatterns[0]) 'ARM64 CPU asset pattern should match current rolling release naming'

$n1x = Resolve-LlamaCppInstallPlan -Architecture Arm64 -HasNvidia $true -DriverMajor 616 -ComputeCapability 12.1
Assert-Equal $n1x.Backend 'CUDA 13.4 Preview' 'N1X should select the ARM64 CUDA runtime'
Assert-Equal $n1x.AssetPatterns.Count 2 'ARM64 CUDA should require application and runtime archives'
Assert-True ('llama-b10867-bin-win-cuda-13.4-arm64.zip' -match $n1x.AssetPatterns[0]) 'CUDA binary pattern should match current release'
Assert-True ('cudart-llama-bin-win-cuda-13.4-arm64.zip' -match $n1x.AssetPatterns[1]) 'CUDA runtime pattern should match current release'

$repeat = Resolve-LlamaCppInstallPlan -Architecture Arm64 -HasNvidia $false
Assert-Equal ($repeat | ConvertTo-Json -Compress) ($arm | ConvertTo-Json -Compress) 'llama.cpp plan should be idempotent'

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

$model = Get-LlamaModelSmokePlan
Assert-Equal $model.Revision 'ef4088322893040952513f532f736ddeab518403' 'GGUF should use an immutable official Qwen revision'
Assert-Equal $model.Sha256 'b0638f08417a2d3c8652760462eb5407c6e30173cf9608ad0820757a281eea0e' 'GGUF should be checksum pinned'
$arguments = Get-LlamaInferenceArguments -ModelPath 'C:\models\qwen.gguf' -Marker $model.Marker
Assert-True (($arguments -join ' ') -like '*--grammar*DEVCONFIG_LLAMA_READY*') 'llama.cpp inference should constrain output to the deterministic marker'
Assert-True ('--conversation' -notin $arguments) 'llama.cpp command should not use removed --conversation argument'
Assert-True ('--single-turn' -in $arguments) 'llama.cpp command should exit after the predefined prompt'
$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\llama.cpp\install.ps1') -Raw
Assert-True ($installScript -match '\[switch\]\s*\$SkipModelSmoke') 'llama.cpp should expose model-smoke opt-out'
Assert-True ($installScript -match 'Invoke-DevConfigNativeCommand') 'llama.cpp failures should retain combined native diagnostics'
Assert-True ($installScript -match '\[switch\]\s*\$PlanOnly') 'llama.cpp should expose portable plan mode'
Assert-True ($installScript -match 'Ensure-AiWingetPackage') 'llama.cpp x64 should use direct package acquisition'
Assert-True ($installScript -notmatch 'apply-configuration') 'llama.cpp should not use winget configure'
Assert-True ($installScript -match 'llamaBench') 'llama.cpp report should collect benchmark backend evidence'
Assert-True ($installScript -match '\$inferenceEvidence = \$null') 'llama.cpp model-smoke opt-out should use explicit skipped evidence'

$prefixedBenchmark = @'
ggml_cuda_init: found 1 CUDA devices:
  Device 0: NVIDIA RTX Spark N1X, compute capability 12.1
[
  {
    "backend": "CUDA",
    "n_gpu_layers": 999,
    "devices": "CUDA0",
    "avg_ts": 127.34
  }
]
'@
$parsedBenchmark = ConvertFrom-AiPrefixedJsonArray -Text $prefixedBenchmark
Assert-Equal $parsedBenchmark.Data.Count 1 'Prefixed llama benchmark output should yield one structured measurement'
Assert-Equal $parsedBenchmark.Data[0].backend 'CUDA' 'Structured benchmark should preserve the actual backend'
Assert-Equal $parsedBenchmark.Data[0].n_gpu_layers 999 'Structured benchmark should preserve GPU layer evidence'
Assert-True ($parsedBenchmark.Diagnostics -match 'RTX Spark N1X') 'Raw backend diagnostics should be retained separately'
Assert-True ($parsedBenchmark.Json.TrimStart().StartsWith('[')) 'Stored benchmark JSON should exclude diagnostic prefixes'
Assert-ThrowsLike {
    ConvertFrom-AiPrefixedJsonArray -Text 'CUDA diagnostics without JSON'
} '*No valid JSON array*' 'Missing benchmark JSON should fail actionably'

Write-Host "UNIT_OK: llama.cpp ($script:AssertionCount assertions)"
