<#
.SYNOPSIS
  Install Ollama and verify CLI plus local API readiness without pulling a model.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-OllamaInstallPlan -Architecture $architecture
$configFile = Join-Path $PSScriptRoot $plan.ConfigurationName

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id 'ollama' `
    -ConfigFile $configFile `
    -RequireCommands @('ollama') `
    -DeferSentinel

Invoke-CheckedCommand -FilePath 'ollama' -ArgumentList @('--version') -DisplayName 'Ollama CLI verification'
$versionUri = [uri]'http://localhost:11434/api/version'
try {
    $version = Invoke-RestMethod -Uri $versionUri -TimeoutSec 3
} catch {
    Write-Host "Ollama API is not running; starting 'ollama serve'."
    Start-Process -FilePath (Get-Command ollama).Source -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    $version = Wait-JsonEndpoint -Uri $versionUri -TimeoutSeconds 30
}

$models = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 10
if (-not $version.version) {
    throw 'Ollama API responded without a version value.'
}
if ($null -eq $models.models) {
    throw 'Ollama API tags response did not include the models collection.'
}

Write-Host "OLLAMA_READY: version=$($version.version), architecture=$architecture, local-model-count=$(@($models.models).Count); no model was downloaded."
Write-Host 'INSTALL_OK: ollama'
