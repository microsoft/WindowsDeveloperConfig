$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$x64 = Resolve-LlamaCppInstallPlan -Architecture X64
Assert-Equal $x64.Method 'WinGet' 'llama.cpp x64 should use WinGet'
Assert-Equal $x64.PackageId 'ggml.llamacpp' 'llama.cpp x64 should use the catalog package'
Assert-Equal $x64.Backend 'Vulkan' 'WinGet package backend should be explicit'

$arm = Resolve-LlamaCppInstallPlan -Architecture Arm64
Assert-Equal $arm.Method 'GitHubRelease' 'llama.cpp ARM64 should use an official release asset'
Assert-Equal $arm.Backend 'CPU' 'ARM64 should choose the broadly compatible CPU asset'
Assert-True ('llama-b10795-bin-win-cpu-arm64.zip' -match $arm.AssetPattern) 'ARM64 asset pattern should match official release naming'

$repeat = Resolve-LlamaCppInstallPlan -Architecture Arm64
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
    Assert-True ($_.Exception.Message -like '*No published*') 'Mocked empty release list should stop before download'
} finally {
    Remove-Item Env:\GITHUB_TOKEN
}
Assert-Equal $script:capturedAuthorization 'Bearer devconfig-unit-test-token' 'GitHub token should authenticate release metadata requests'

Write-Host "UNIT_OK: llama.cpp ($script:AssertionCount assertions)"
