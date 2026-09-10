<#
.SYNOPSIS
  Install Ollama, pull a small official-library model, and run text inference.

.PARAMETER SkipModelSmoke
  Skip the default qwen3:0.6b pull and inference. The install then verifies only
  the CLI and local API and does not claim workload readiness.
#>
[CmdletBinding()]
param(
    [switch] $SkipModelSmoke,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-OllamaInstallPlan -Architecture $architecture
$catalog = (Get-AiCatalog).Components
$component = if ($architecture -eq 'Arm64') { $catalog.OllamaArm64 } else { $catalog.OllamaX64 }
$report = New-AiWorkloadReport -Id 'ollama' -Request @{
    SkipModelSmoke = [bool]$SkipModelSmoke
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'ollama' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
if (-not $PlanOnly) { Assert-AiAdministrator }

if ($architecture -eq 'X64') {
    $acquisition = Ensure-AiWingetPackage -Id 'Ollama.Ollama' -PlanOnly:$PlanOnly
    if (-not $PlanOnly) {
        Update-DevConfigSessionPath
        $ollamaPath = (Get-Command ollama -ErrorAction Stop).Source
    }
} else {
    if ($PlanOnly) {
        $acquisition = [pscustomobject]@{ Action = 'resolve-latest-stable-arm64-asset'; Source = 'github' }
    } else {
        $destination = Join-Path $env:LOCALAPPDATA 'DevConfig\ollama\runtime'
        $managedProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'ollama.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($destination, [StringComparison]::OrdinalIgnoreCase) })
        $managedProcessIds = @(Get-AiProcessIds -ProcessObjects $managedProcesses)
        foreach ($process in $managedProcesses) {
            $processId = Get-AiProcessId -ProcessObject $process
            if ($null -eq $processId) {
                [void]$report.result.warnings.Add('A managed Ollama process was detected without a usable process id; cleanup evidence was skipped.')
                continue
            }
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        foreach ($processId in $managedProcessIds) {
            $deadline = (Get-Date).AddSeconds(30)
            while (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
                if ((Get-Date) -ge $deadline) {
                    throw "Managed Ollama process $processId did not exit before runtime upgrade."
                }
                Start-Sleep -Milliseconds 250
            }
        }
        $resolved = Install-VerifiedGitHubLatestAsset `
            -Repository $component.Repository `
            -AssetPattern $component.AssetPattern `
            -Destination $destination `
            -VersionMarker '.devconfig-version' `
            -RequiredFile 'ollama.exe'
        Add-UserPathEntry -Path $destination
        $ollamaPath = Join-Path $destination 'ollama.exe'
        $acquisition = [pscustomobject]@{
            Action = $resolved.Action
            Source = 'github'
            Tag = $resolved.Tag
            Asset = $resolved.Asset.name
            Sha256 = $resolved.Asset.digest
            stoppedManagedProcesses = $managedProcessIds
        }
    }
}
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $component.Vendor
    architecture = $architecture
    maturity = $component.Maturity
    sourceType = $component.SourceType
    packageId = Get-AiCatalogValue -Entry $component -Name 'PackageId'
    repository = Get-AiCatalogValue -Entry $component -Name 'Repository'
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = $component.InstallPath
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = $acquisition.Action
    packageEvidence = $(if ($architecture -eq 'X64' -and -not $PlanOnly) { $acquisition.Evidence } else { $null })
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{ model = 'qwen3:0.6b' }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: ollama'
    return
}

Invoke-CheckedCommand -FilePath $ollamaPath -ArgumentList @('--version') -DisplayName 'Ollama CLI verification'
$apiBase = 'http://localhost:11434'
$ownedServer = $null
if ($architecture -eq 'Arm64') {
    $port = Get-AiFreeTcpPort
    $env:OLLAMA_HOST = "127.0.0.1:$port"
    $apiBase = "http://127.0.0.1:$port"
    Write-Host "Starting resolver-owned ARM64 Ollama server at $apiBase."
    $ownedServer = Start-Process -FilePath $ollamaPath -ArgumentList 'serve' -WindowStyle Hidden -PassThru
    $versionUri = [uri]"$apiBase/api/version"
    $version = Wait-JsonEndpoint -Uri $versionUri -TimeoutSeconds 30
} else {
    $versionUri = [uri]"$apiBase/api/version"
    try {
        $version = Invoke-RestMethod -Uri $versionUri -TimeoutSec 3
    } catch {
        Write-Host "Ollama API is not running; starting 'ollama serve'."
        Start-Process -FilePath $ollamaPath -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
        $version = Wait-JsonEndpoint -Uri $versionUri -TimeoutSeconds 30
    }
}

if (-not $version.version) {
    throw 'Ollama API responded without a version value.'
}
if ($architecture -eq 'Arm64') {
    $expectedVersion = ([string]$acquisition.Tag).TrimStart('v')
    if ([string]$version.version -ne $expectedVersion) {
        throw "Resolver-owned ARM64 Ollama API reported version '$($version.version)', expected '$expectedVersion' from release '$($acquisition.Tag)'."
    }
    $report.acceptance.server = [ordered]@{
        endpoint = $apiBase
        processId = $ownedServer.Id
        executable = $ollamaPath
        version = $version.version
    }
}

$modelPlan = Get-OllamaModelSmokePlan
$inferenceEvidence = $null
if ($SkipModelSmoke) {
    Write-Warning 'OLLAMA_MODEL_SMOKE_SKIPPED: CLI and API are ready, but no model inference was performed.'
} else {
    Write-Host "Pulling official Ollama library model $($modelPlan.Model) (approximately $($modelPlan.ApproximateDownloadMb) MB, $($modelPlan.License))."
    Invoke-CheckedCommand -FilePath $ollamaPath -ArgumentList @('pull', $modelPlan.Model) -DisplayName 'Ollama model pull'

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
        -Uri "$apiBase/api/generate" `
        -ContentType 'application/json' `
        -Body ($request | ConvertTo-Json -Depth 8) `
        -TimeoutSec 300
    $result = $response.response | ConvertFrom-Json
    if ($result.marker -ne $modelPlan.Marker) {
        throw "Ollama model inference did not produce marker '$($modelPlan.Marker)'. Response: $($response.response)"
    }
    $processor = (& $ollamaPath ps 2>&1 | Out-String).Trim()
    $running = Invoke-RestMethod -Uri "$apiBase/api/ps" -TimeoutSec 30
    $loaded = @($running.models | Where-Object { $_.name -eq $modelPlan.Model } | Select-Object -First 1)
    $gpuFraction = if ($loaded.Count -eq 1 -and [double]$loaded[0].size -gt 0) {
        [math]::Round(([double]$loaded[0].size_vram / [double]$loaded[0].size), 4)
    } else { 0 }
    $serverLogPath = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
    $serverEvidence = if (Test-Path -LiteralPath $serverLogPath) {
        (Get-Content -LiteralPath $serverLogPath -Tail 200 | Select-String 'inference compute|gpu memory|library=' | Out-String).Trim()
    } else { $null }
    $report.acceptance.inference = [ordered]@{
        model = $modelPlan.Model
        digest = $expectedDigest
        marker = $modelPlan.Marker
        sizeBytes = if ($loaded.Count) { $loaded[0].size } else { $null }
        sizeVramBytes = if ($loaded.Count) { $loaded[0].size_vram } else { $null }
        gpuFraction = $gpuFraction
        processTable = $processor
        backendLogEvidence = $serverEvidence
    }
    $inferenceEvidence = $report.acceptance.inference
    $report.result.fallbackUsed = $gpuFraction -eq 0
    Write-Host $processor
    Write-Host "OLLAMA_READY: version=$($version.version), architecture=$architecture, model=$($modelPlan.Model), verified-blob=$($modelPlan.ModelBlobSha256)."
}
Add-AiReportPhase -Report $report -Name 'ollama-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: ollama'
