$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

$x64 = Resolve-OllamaInstallPlan -Architecture X64
Assert-Equal $x64.PackageId 'Ollama.Ollama' 'Ollama x64 should use the current desktop package'
Assert-Equal $x64.LaunchMode 'Desktop' 'Ollama x64 should use desktop background behavior'

$arm = Resolve-OllamaInstallPlan -Architecture Arm64
Assert-Equal $arm.PackageId 'Ollama.Ollama.Portable' 'Ollama ARM64 should use the WinGet portable package'
Assert-Equal $arm.ConfigurationName 'configuration.arm64.winget' 'Ollama ARM64 should select its compatible configuration'
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

Write-Host "UNIT_OK: ollama ($script:AssertionCount assertions)"
