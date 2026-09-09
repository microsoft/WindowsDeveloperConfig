$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$x64 = Resolve-OllamaInstallPlan -Architecture X64
Assert-Equal $x64.PackageId 'Ollama.Ollama' 'Ollama x64 should use the current desktop package'
Assert-Equal $x64.LaunchMode 'Desktop' 'Ollama x64 should use desktop background behavior'

$arm = Resolve-OllamaInstallPlan -Architecture Arm64
Assert-Equal $arm.Method 'GitHubRelease' 'Ollama ARM64 should use the current official release'
Assert-Equal $arm.PackageId $null 'Ollama ARM64 should not use the stale WinGet portable package'
Assert-Equal $arm.LaunchMode 'Serve' 'Portable Ollama requires an explicit server launch'
$repeat = Resolve-OllamaInstallPlan -Architecture Arm64
Assert-Equal ($repeat | ConvertTo-Json -Compress) ($arm | ConvertTo-Json -Compress) 'Ollama plan should be idempotent'

Assert-ThrowsLike {
    Assert-CommandAvailable -CommandName 'devconfig-command-that-does-not-exist' -Remediation 'Install the missing tool.'
} '*Install the missing tool.*' 'Missing tools should produce actionable errors'

$model = Get-OllamaModelSmokePlan
Assert-Equal $model.Model 'qwen3:0.6b' 'Ollama should use the tested small library model'
Assert-Equal $model.ModelBlobSha256 '7f4030143c1c477224c5434f8272c662a8b042079a0a584f0a27a1684fe2e1fa' 'Ollama model blob should be pinned'
$request = New-OllamaGenerateRequest -Model $model.Model -Marker $model.Marker
Assert-Equal $request.stream $false 'Ollama inference should be non-streaming'
Assert-Equal $request.format.properties.marker.enum[0] $model.Marker 'Ollama JSON schema should constrain the marker'
Assert-Equal $request.options.seed 42 'Ollama inference should use a fixed seed'
$manifestPath = Get-OllamaModelManifestPath -ModelRoot 'C:\models' -Model 'qwen3:0.6b'
Assert-Equal $manifestPath 'C:\models\manifests\registry.ollama.ai\library\qwen3\0.6b' 'Ollama digest verification should target the pulled tag manifest'
$installScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\ollama\install.ps1') -Raw
Assert-True ($installScript -match '\[switch\]\s*\$SkipModelSmoke') 'Ollama should expose model-smoke opt-out'
Assert-True ($installScript -match '\[switch\]\s*\$PlanOnly') 'Ollama should expose portable plan mode'
Assert-True ($installScript -match 'Ensure-AiWingetPackage') 'Ollama x64 should use direct package acquisition'
Assert-True ($installScript -notmatch 'apply-configuration') 'Ollama should not use winget configure'
Assert-True ($installScript -match '/api/ps') 'Ollama report should use machine-readable VRAM allocation evidence'
Assert-True ($installScript -match '\$inferenceEvidence = \$null') 'Ollama model-smoke opt-out should use explicit skipped evidence'
Assert-True ($installScript -match 'Stop-Process -Id \$process\.ProcessId') 'Ollama should stop only resolver-owned portable servers before swapping the runtime'

Write-Host "UNIT_OK: ollama ($script:AssertionCount assertions)"
