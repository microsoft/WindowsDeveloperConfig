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

Write-Host "UNIT_OK: ollama ($script:AssertionCount assertions)"
