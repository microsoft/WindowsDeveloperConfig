<#
.SYNOPSIS
  Install and manage Ollama, then run verified model inference.

.PARAMETER SkipModelSmoke
  Verify the CLI and local API without pulling or running the quick model.

.PARAMETER Uninstall
  Remove Ollama registration and runtime. ARM64 models are preserved by default.

.PARAMETER RemoveModels
  With -Uninstall, also remove the configured Ollama model directory.
#>
[CmdletBinding()]
param(
    [switch] $SkipModelSmoke,
    [switch] $Uninstall,
    [switch] $RemoveModels,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

if ($RemoveModels -and -not $Uninstall) {
    throw '-RemoveModels requires -Uninstall.'
}

$architecture = Get-DevConfigArchitecture
$plan = Resolve-OllamaInstallPlan -Architecture $architecture
$catalog = (Get-AiCatalog).Components
$component = if ($architecture -eq 'Arm64') { $catalog.OllamaArm64 } else { $catalog.OllamaX64 }
$paths = Get-OllamaManagedPaths
$modelRoot = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $HOME '.ollama\models' }
$report = New-AiWorkloadReport -Id 'ollama' -Request @{
    SkipModelSmoke = [bool]$SkipModelSmoke
    Uninstall = [bool]$Uninstall
    RemoveModels = [bool]$RemoveModels
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'ollama' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}

if ($Uninstall) {
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = $component.Component
        architecture = $architecture
        sourceType = $component.SourceType
        installPath = $(if ($architecture -eq 'Arm64') { $paths.InstallRoot } else { $component.InstallPath })
        modelsPreserved = -not $RemoveModels
        action = $(if ($PlanOnly) { 'planned-uninstall' } else { 'pending-uninstall' })
    })
    if ($PlanOnly) {
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_OK: ollama uninstall'
        return
    }

    if ($architecture -eq 'X64') {
        Assert-AiAdministrator
        Invoke-CheckedCommand -FilePath 'winget' -ArgumentList @(
            'uninstall', '--id', 'Ollama.Ollama', '--exact', '--source', 'winget',
            '--silent', '--disable-interactivity'
        ) -DisplayName 'Ollama application uninstall'
    } else {
        $removed = Remove-OllamaManagedInstallation `
            -Paths $paths `
            -ModelRoot $modelRoot `
            -RemoveModels:$RemoveModels
        $report.acceptance.uninstall = $removed
    }
    if ($architecture -eq 'X64' -and $RemoveModels) {
        Remove-Item -LiteralPath $modelRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $report.acquisitions[0].action = 'uninstalled'
    $report.acceptance.models = [ordered]@{
        path = $modelRoot
        preserved = -not $RemoveModels
    }
    Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
    Write-Host "OLLAMA_UNINSTALLED: models-preserved=$(-not $RemoveModels)"
    return
}

if ($architecture -eq 'X64') {
    if (-not $PlanOnly) { Assert-AiAdministrator }
    $acquisition = Ensure-AiWingetPackage -Id 'Ollama.Ollama' -PlanOnly:$PlanOnly
    if (-not $PlanOnly) {
        Update-DevConfigSessionPath
        $ollamaPath = (Get-Command ollama -ErrorAction Stop).Source
    }
} else {
    if ($PlanOnly) {
        $acquisition = [pscustomobject]@{
            Action = 'resolve-latest-stable-native-arm64-archive'
            Source = 'github'
            InstallType = $plan.InstallType
        }
    } else {
        $managedProcessIds = @(Stop-OllamaManagedProcesses -InstallRoot $paths.InstallRoot)
        $managedProcessIds += @(Stop-OllamaManagedProcesses -InstallRoot $paths.LegacyRoot)
        $resolved = Install-VerifiedGitHubLatestAsset `
            -Repository $component.Repository `
            -AssetPattern $component.AssetPattern `
            -Destination $paths.InstallRoot `
            -VersionMarker $paths.VersionMarker `
            -RequiredFile 'ollama.exe' `
            -CacheDirectory $paths.CacheDirectory
        $ollamaPath = $paths.Executable
        $binaryArchitecture = Get-AiPeArchitecture -Path $ollamaPath
        if ($binaryArchitecture -ne 'Arm64') {
            throw "Official ARM64 asset installed '$binaryArchitecture' ollama.exe; refusing emulated or incompatible runtime."
        }
        Add-UserPathEntry -Path $paths.InstallRoot -Prepend
        Remove-UserPathEntry -Path $paths.LegacyRoot
        Remove-OllamaManagedDirectory -Path $paths.LegacyRoot

        $startupCommand = Set-OllamaStartupRegistration `
            -RegistryPath $paths.StartupRegistryPath `
            -ValueName $paths.StartupValueName `
            -Executable $ollamaPath
        $installedFiles = @(Get-ChildItem -LiteralPath $paths.InstallRoot -Recurse -File |
            Where-Object Name -notin @('.devconfig-install.json') |
            ForEach-Object { $_.FullName.Substring($paths.InstallRoot.Length).TrimStart('\') } |
            Sort-Object)
        $installManifest = [ordered]@{
            schemaVersion = 1
            installedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            source = 'official native ARM64 archive'
            installType = $plan.InstallType
            repository = $component.Repository
            tag = $resolved.Tag
            asset = $resolved.Asset.name
            assetDigest = $resolved.Asset.digest
            cachePath = $resolved.CachePath
            installPath = $paths.InstallRoot
            executable = $ollamaPath
            architecture = $binaryArchitecture
            startup = [ordered]@{
                registryPath = $paths.StartupRegistryPath
                valueName = $paths.StartupValueName
                command = $startupCommand
            }
            installedFiles = $installedFiles
            modelsPath = $modelRoot
        }
        Write-DevConfigTextFile -Path $paths.InstallManifest -Content ($installManifest | ConvertTo-Json -Depth 8)
        $acquisition = [pscustomobject]@{
            Action = $resolved.Action
            Source = 'github'
            InstallType = $plan.InstallType
            Tag = $resolved.Tag
            Asset = $resolved.Asset.name
            Sha256 = $resolved.Asset.digest
            CachePath = $resolved.CachePath
            InstallManifest = $paths.InstallManifest
            stoppedManagedProcesses = @($managedProcessIds | Select-Object -Unique)
        }
        if ($resolved.PSObject.Properties['Warning']) {
            [void]$report.result.warnings.Add([string]$resolved.Warning)
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
    assetPattern = Get-AiCatalogValue -Entry $component -Name 'AssetPattern'
    installType = $(if ($architecture -eq 'Arm64') { $plan.InstallType } else { 'official-x64-installer' })
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $(if ($architecture -eq 'Arm64') { $paths.CacheDirectory } else { $component.CachePath })
    installPath = $(if ($architecture -eq 'Arm64') { $paths.InstallRoot } else { $component.InstallPath })
    installManifest = $(if ($architecture -eq 'Arm64') { $paths.InstallManifest } else { $null })
    startupRegistration = Get-AiCatalogValue -Entry $component -Name 'StartupRegistration'
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = $acquisition.Action
    resolvedTag = $(if ($architecture -eq 'Arm64' -and -not $PlanOnly) { $acquisition.Tag } else { $null })
    resolvedAsset = $(if ($architecture -eq 'Arm64' -and -not $PlanOnly) { $acquisition.Asset } else { $null })
    resolvedSha256 = $(if ($architecture -eq 'Arm64' -and -not $PlanOnly) { $acquisition.Sha256 } else { $null })
    packageEvidence = $(if ($architecture -eq 'X64' -and -not $PlanOnly) { $acquisition.Evidence } else { $null })
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'managed-runtime' -Status 'planned' -Evidence @{
        installPath = $(if ($architecture -eq 'Arm64') { $paths.InstallRoot } else { $component.InstallPath })
        startup = $(if ($architecture -eq 'Arm64') { $component.StartupRegistration } else { 'official installer managed' })
        modelsPreservedOnUninstall = $true
    }
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{ model = 'qwen3:0.6b' }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: ollama'
    return
}

Invoke-CheckedCommand -FilePath $ollamaPath -ArgumentList @('--version') -DisplayName 'Ollama CLI verification'
$oldHost = $env:OLLAMA_HOST
$validationServer = $null
$validationStdout = $null
$validationStderr = $null
try {
    if ($architecture -eq 'Arm64') {
        $port = Get-AiFreeTcpPort
        $env:OLLAMA_HOST = "127.0.0.1:$port"
        $apiBase = "http://127.0.0.1:$port"
        $validationStdout = Join-Path $paths.InstallRoot 'validation-server.stdout.log'
        $validationStderr = Join-Path $paths.InstallRoot 'validation-server.stderr.log'
        Remove-Item $validationStdout, $validationStderr -Force -ErrorAction SilentlyContinue
        Write-Host "Starting managed ARM64 validation server at $apiBase."
        $validationServer = Start-Process `
            -FilePath $ollamaPath `
            -ArgumentList 'serve' `
            -WindowStyle Hidden `
            -RedirectStandardOutput $validationStdout `
            -RedirectStandardError $validationStderr `
            -PassThru
        $version = Wait-JsonEndpoint -Uri ([uri]"$apiBase/api/version") -TimeoutSeconds 30
        $expectedVersion = ([string]$acquisition.Tag).TrimStart('v')
        if ([string]$version.version -ne $expectedVersion) {
            throw "Managed ARM64 API reported version '$($version.version)', expected '$expectedVersion'."
        }
    } else {
        $apiBase = 'http://localhost:11434'
        try {
            $version = Invoke-RestMethod -Uri "$apiBase/api/version" -TimeoutSec 3
        } catch {
            Write-Host "Ollama API is not running; starting 'ollama serve'."
            Start-Process -FilePath $ollamaPath -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
            $version = Wait-JsonEndpoint -Uri ([uri]"$apiBase/api/version") -TimeoutSeconds 30
        }
    }

    if (-not $version.version) {
        throw 'Ollama API responded without a version value.'
    }
    if ($architecture -eq 'Arm64') {
        $report.acceptance.server = [ordered]@{
            validationEndpoint = $apiBase
            processId = $validationServer.Id
            executable = $ollamaPath
            executableArchitecture = Get-AiPeArchitecture -Path $ollamaPath
            version = $version.version
            installManifest = $paths.InstallManifest
        }
    }

    $modelPlan = Get-OllamaModelSmokePlan
    $inferenceEvidence = $null
    if ($SkipModelSmoke) {
        Write-Warning 'OLLAMA_MODEL_SMOKE_SKIPPED: CLI and API are ready, but no model inference was performed.'
    } else {
        Write-Host "Pulling official Ollama library model $($modelPlan.Model) (approximately $($modelPlan.ApproximateDownloadMb) MB, $($modelPlan.License))."
        Invoke-CheckedCommand -FilePath $ollamaPath -ArgumentList @('pull', $modelPlan.Model) -DisplayName 'Ollama model pull'
        $manifestPath = Get-OllamaModelManifestPath -ModelRoot $modelRoot -Model $modelPlan.Model
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "Ollama pulled $($modelPlan.Model), but its local manifest was not found at '$manifestPath'."
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $modelLayer = @($manifest.layers | Where-Object { $_.mediaType -match 'model' } | Select-Object -First 1)
        $expectedDigest = "sha256:$($modelPlan.ModelBlobSha256)"
        if ($modelLayer.Count -ne 1 -or $modelLayer[0].digest -ne $expectedDigest) {
            throw "Ollama library tag $($modelPlan.Model) no longer references pinned model digest $expectedDigest."
        }
        $blobPath = Join-Path $modelRoot "blobs\sha256-$($modelPlan.ModelBlobSha256)"
        if (-not (Test-Path -LiteralPath $blobPath)) {
            throw "Ollama pulled $($modelPlan.Model), but its pinned model blob was not found at '$blobPath'."
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
            throw "Ollama model inference did not produce marker '$($modelPlan.Marker)'."
        }
        $processor = (& $ollamaPath ps 2>&1 | Out-String).Trim()
        $running = Invoke-RestMethod -Uri "$apiBase/api/ps" -TimeoutSec 30
        $loaded = @($running.models | Where-Object { $_.name -eq $modelPlan.Model } | Select-Object -First 1)
        $gpuFraction = if ($loaded.Count -eq 1 -and [double]$loaded[0].size -gt 0) {
            [math]::Round(([double]$loaded[0].size_vram / [double]$loaded[0].size), 4)
        } else { 0 }
        $serverEvidence = if ($validationStderr -and (Test-Path -LiteralPath $validationStderr)) {
            (Get-Content -LiteralPath $validationStderr -Tail 200 | Select-String 'inference compute|gpu memory|library=' | Out-String).Trim()
        } else {
            $serverLogPath = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
            if (Test-Path -LiteralPath $serverLogPath) {
                (Get-Content -LiteralPath $serverLogPath -Tail 200 | Select-String 'inference compute|gpu memory|library=' | Out-String).Trim()
            }
        }
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
} finally {
    if ($validationServer -and -not $validationServer.HasExited) {
        Stop-Process -Id $validationServer.Id -Force -ErrorAction SilentlyContinue
        $validationServer.WaitForExit()
    }
    if ($architecture -eq 'Arm64' -and $paths) {
        [void](Stop-OllamaManagedProcesses -InstallRoot $paths.InstallRoot)
    }
    $env:OLLAMA_HOST = $oldHost
}

if ($architecture -eq 'Arm64') {
    $defaultApi = 'http://127.0.0.1:11434'
    $persistentStdout = $null
    $persistentStderr = $null
    try {
        $existingDefault = Invoke-RestMethod -Uri "$defaultApi/api/version" -TimeoutSec 3
        $managedDefault = @(Get-OllamaManagedProcesses -InstallRoot $paths.InstallRoot)
        if ($managedDefault.Count -eq 0) {
            throw "Port 11434 is already served by an unmanaged Ollama instance. Stop it and rerun to activate the managed ARM64 installation."
        }
        $persistentVersion = $existingDefault
        $persistentProcess = $managedDefault | Select-Object -First 1
    } catch {
        if ($_.Exception.Message -match 'unmanaged Ollama') { throw }
        $oldHost = $env:OLLAMA_HOST
        try {
            $env:OLLAMA_HOST = '127.0.0.1:11434'
            $persistentStdout = Join-Path $paths.InstallRoot 'server.stdout.log'
            $persistentStderr = Join-Path $paths.InstallRoot 'server.stderr.log'
            Remove-Item $persistentStdout, $persistentStderr -Force -ErrorAction SilentlyContinue
            $persistentProcess = Start-Process `
                -FilePath $ollamaPath `
                -ArgumentList 'serve' `
                -WindowStyle Hidden `
                -RedirectStandardOutput $persistentStdout `
                -RedirectStandardError $persistentStderr `
                -PassThru
            $persistentVersion = Wait-JsonEndpoint -Uri ([uri]"$defaultApi/api/version") -TimeoutSeconds 30
        } finally {
            $env:OLLAMA_HOST = $oldHost
        }
    }
    $report.acceptance.managedRuntime = [ordered]@{
        installType = $plan.InstallType
        installPath = $paths.InstallRoot
        executable = $ollamaPath
        executableArchitecture = Get-AiPeArchitecture -Path $ollamaPath
        startupRegistryPath = $paths.StartupRegistryPath
        startupValueName = $paths.StartupValueName
        persistentEndpoint = $defaultApi
        persistentProcessId = Get-AiProcessId -ProcessObject $persistentProcess
        version = $persistentVersion.version
        modelsPath = $modelRoot
        stdoutLog = $(if ($persistentStdout) { $persistentStdout } else { $null })
        stderrLog = $(if ($persistentStderr) { $persistentStderr } else { $null })
    }
}

Add-AiReportPhase -Report $report -Name 'ollama-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: ollama'
