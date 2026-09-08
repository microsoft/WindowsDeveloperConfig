<#
.SYNOPSIS
  Install Ollama, pull a small official-library model, and run text inference.

.PARAMETER SkipModelSmoke
  Skip the default qwen3:0.6b pull and inference. The install then verifies only
  the CLI and local API and does not claim workload readiness.
#>
[CmdletBinding()]
param([switch] $SkipModelSmoke)

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

if (-not $version.version) {
    throw 'Ollama API responded without a version value.'
}

$modelPlan = Get-OllamaModelSmokePlan
if ($SkipModelSmoke) {
    Write-Warning 'OLLAMA_MODEL_SMOKE_SKIPPED: CLI and API are ready, but no model inference was performed.'
} else {
    Write-Host "Pulling official Ollama library model $($modelPlan.Model) (approximately $($modelPlan.ApproximateDownloadMb) MB, $($modelPlan.License))."
    Invoke-CheckedCommand -FilePath 'ollama' -ArgumentList @('pull', $modelPlan.Model) -DisplayName 'Ollama model pull'

    $modelRoot = if ($env:OLLAMA_MODELS) {
        $env:OLLAMA_MODELS
    } else {
        Join-Path $HOME '.ollama\models'
    }
    $manifestPath = Get-OllamaModelManifestPath -ModelRoot $modelRoot -Model $modelPlan.Model
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Ollama pulled $($modelPlan.Model), but its local manifest was not found at '$manifestPath'."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $modelLayer = @($manifest.layers | Where-Object { $_.mediaType -match 'model' } | Select-Object -First 1)
    $expectedDigest = "sha256:$($modelPlan.ModelBlobSha256)"
    if ($modelLayer.Count -ne 1 -or $modelLayer[0].digest -ne $expectedDigest) {
        throw "Ollama library tag $($modelPlan.Model) no longer references pinned model digest $expectedDigest. Review the upstream model update before changing this pin."
    }
    $blobPath = Join-Path $modelRoot "blobs\sha256-$($modelPlan.ModelBlobSha256)"
    if (-not (Test-Path -LiteralPath $blobPath)) {
        throw "Ollama pulled $($modelPlan.Model), but its pinned model blob was not found at '$blobPath'. The mutable library tag may have changed; review and update the expected digest."
    }
    $blobHash = (Get-FileHash -LiteralPath $blobPath -Algorithm SHA256).Hash
    if ($blobHash -ne $modelPlan.ModelBlobSha256) {
        throw "Ollama model blob checksum mismatch. Expected $($modelPlan.ModelBlobSha256); got $blobHash."
    }

    $request = New-OllamaGenerateRequest -Model $modelPlan.Model -Marker $modelPlan.Marker
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri 'http://localhost:11434/api/generate' `
        -ContentType 'application/json' `
        -Body ($request | ConvertTo-Json -Depth 8) `
        -TimeoutSec 300
    $result = $response.response | ConvertFrom-Json
    if ($result.marker -ne $modelPlan.Marker) {
        throw "Ollama model inference did not produce marker '$($modelPlan.Marker)'. Response: $($response.response)"
    }
    $processor = (& ollama ps 2>&1 | Out-String).Trim()
    Write-Host $processor
    Write-Host "OLLAMA_READY: version=$($version.version), architecture=$architecture, model=$($modelPlan.Model), verified-blob=$($modelPlan.ModelBlobSha256)."
}
Write-Host 'INSTALL_OK: ollama'
