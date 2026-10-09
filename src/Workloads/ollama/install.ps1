<#
.SYNOPSIS
  Install the architecture-applicable Ollama WinGet application and run verified model inference.

.PARAMETER SkipModelSmoke
  Verify the CLI and local API without pulling or running the quick model.

.PARAMETER Uninstall
  Remove the Ollama application. Models are preserved by default.

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
$component = if ($architecture -eq 'Arm64') {
    (Get-AiCatalog).Components.OllamaArm64
} else {
    (Get-AiCatalog).Components.OllamaX64
}
$legacyPaths = Get-OllamaManagedPaths
$modelRoot = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $HOME '.ollama\models' }
$report = New-AiWorkloadReport -Id 'ollama' -Request @{
    Architecture = $architecture
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

function Add-OllamaAcquisition {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [AllowNull()] $PackageEvidence,
        [AllowNull()] $MigrationEvidence
    )
    $entry = [ordered]@{
        component = $component.Component
        vendor = $component.Vendor
        architecture = $architecture
        maturity = $component.Maturity
        sourceType = $component.SourceType
        packageId = $component.PackageId
        versionPolicy = $component.VersionPolicy
        integrity = $component.Integrity
        installPath = $component.InstallPath
        reasonNormalChannelInsufficient = $component.NormalChannelLimitation
        expectedStableSource = $component.ExpectedStableSource
        migrationTrigger = $component.MigrationTrigger
        cleanupUpgrade = $component.CleanupUpgrade
        legacyManagedArchiveMigration = $MigrationEvidence
        action = $Action
        packageEvidence = $PackageEvidence
    }
    if (-not $Uninstall) {
        $entry.selectedInstaller = [ordered]@{
            applicable = $manifestEvidence.Applicable
            architecture = $manifestEvidence.Architecture
            version = $manifestEvidence.Version
            url = $manifestEvidence.InstallerUrl
            sha256 = $manifestEvidence.InstallerSha256
        }
    }
    Add-AiReportAcquisition -Report $report -Entry $entry
}

function Remove-OllamaPortablePackage {
    [CmdletBinding()]
    param([switch] $PlanOnly)

    if ($PlanOnly) {
        return [pscustomobject]@{ Action = 'not-selected-cleanup-if-possible'; PackageId = 'Ollama.Ollama.Portable' }
    }
    $listed = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'list', '--id', 'Ollama.Ollama.Portable', '--exact', '--source', 'winget',
        '--disable-interactivity', '--accept-source-agreements'
    )
    if ($listed.ExitCode -eq $Script:DevConfigWingetNotFound) {
        return [pscustomobject]@{ Action = 'already-absent'; PackageId = 'Ollama.Ollama.Portable' }
    }
    if ($listed.ExitCode -ne 0) {
        throw "Could not query the retired Ollama.Ollama.Portable package (exit $($listed.ExitCode))."
    }
    $result = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'uninstall', '--id', 'Ollama.Ollama.Portable', '--exact', '--source', 'winget',
        '--silent', '--disable-interactivity', '--accept-source-agreements'
    )
    if ($result.ExitCode -ne 0) {
        if ($result.Output -match 'user scope cannot be uninstalled when running with administrator privileges') {
            return [pscustomobject]@{
                Action = 'retained-user-scope-not-selected'
                PackageId = 'Ollama.Ollama.Portable'
                Warning = 'A pre-existing user-scope Ollama.Ollama.Portable package remains because WinGet refuses to uninstall it from an elevated process. The official Ollama.Ollama application is selected and verified.'
            }
        }
        throw "Could not uninstall the retired Ollama.Ollama.Portable package (exit $($result.ExitCode)): $($result.Output)"
    }
    $remaining = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'list', '--id', 'Ollama.Ollama.Portable', '--exact', '--source', 'winget',
        '--disable-interactivity', '--accept-source-agreements'
    )
    if ($remaining.ExitCode -ne $Script:DevConfigWingetNotFound) {
        throw 'WinGet still lists the retired Ollama.Ollama.Portable package.'
    }
    return [pscustomobject]@{
        Action = 'removed'
        PackageId = 'Ollama.Ollama.Portable'
    }
}

if ($Uninstall) {
    if ($PlanOnly) {
        Add-OllamaAcquisition -Action 'planned-uninstall' -PackageEvidence $null -MigrationEvidence ([ordered]@{
            legacyManagedArchive = $null
            portablePackage = Remove-OllamaPortablePackage -PlanOnly
        })
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_OK: ollama uninstall'
        return
    }

    Assert-AiAdministrator
    $migration = Remove-OllamaLegacyManagedInstallation -Paths $legacyPaths
    $portableCleanup = Remove-OllamaPortablePackage
    if ($portableCleanup.PSObject.Properties['Warning']) {
        [void]$report.result.warnings.Add([string]$portableCleanup.Warning)
    }
    $registeredApplication = Get-OllamaRegisteredApplicationEvidence
    $installedCommand = Get-Command ollama -ErrorAction SilentlyContinue
    if ($installedCommand) {
        [void](Stop-OllamaManagedProcesses -InstallRoot (Split-Path -Parent $installedCommand.Source))
    }
    $uninstallResult = Invoke-DevConfigNativeCommand -FilePath 'winget.exe' -Arguments @(
        'uninstall', '--id', $component.PackageId, '--exact', '--source', 'winget',
        '--silent', '--disable-interactivity', '--accept-source-agreements'
    )
    if ($uninstallResult.Output) { Write-Host $uninstallResult.Output.TrimEnd() }
    $uninstallMethod = 'winget'
    if ($uninstallResult.ExitCode -notin @(0, $Script:DevConfigWingetNotFound)) {
        if ($uninstallResult.Output -match 'user scope cannot be uninstalled when running with administrator privileges' -and
            $registeredApplication) {
            $registeredCommand = ConvertFrom-OllamaUninstallString -UninstallString $registeredApplication.UninstallString
            $registeredArguments = @()
            if ($registeredCommand.Arguments) { $registeredArguments += $registeredCommand.Arguments }
            $registeredArguments += @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
            $exitCode = Invoke-DevConfigProcess `
                -FilePath $registeredCommand.FilePath `
                -Arguments $registeredArguments `
                -TimeoutSeconds 1800
            if ($exitCode -ne 0) {
                throw "Ollama registered uninstaller exited with code $exitCode."
            }
            $uninstallMethod = 'winget-registered-uninstaller'
        } else {
            throw "Could not uninstall $($component.PackageId) (exit $($uninstallResult.ExitCode)): $($uninstallResult.Output)"
        }
    }
    $remaining = Invoke-DevConfigCleanupCommand -FilePath 'winget' -Arguments @(
        'list', '--id', $component.PackageId, '--exact', '--source', 'winget',
        '--disable-interactivity', '--accept-source-agreements'
    ) -SuccessCodes @(0, $Script:DevConfigWingetNotFound)
    if ($remaining.ExitCode -ne $Script:DevConfigWingetNotFound) {
        throw "WinGet still lists $($component.PackageId) after uninstall."
    }
    if ($RemoveModels) {
        Remove-OllamaManagedDirectory -Path $modelRoot
    }
    Add-OllamaAcquisition -Action 'uninstalled' -PackageEvidence $null -MigrationEvidence ([ordered]@{
        legacyManagedArchive = $migration
        portablePackage = $portableCleanup
    })
    $report.acceptance.uninstall = [ordered]@{
        packageAbsent = $true
        method = $uninstallMethod
        registeredApplication = $registeredApplication
        legacyManagedArchive = $migration
        portablePackage = $portableCleanup
        modelsPath = $modelRoot
        modelsPreserved = -not $RemoveModels
    }
    Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
    Write-Host "OLLAMA_UNINSTALLED: models-preserved=$(-not $RemoveModels)"
    return
}

$manifestEvidence = Get-OllamaWingetManifestEvidence -Architecture $architecture

try {
    $configuredApi = Get-OllamaLocalEndpoint
} catch {
    if (-not $PlanOnly) { throw }
    [void]$report.result.blockers.Add($_.Exception.Message)
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_UNSUPPORTED: ollama'
    return
}
$report.request.Endpoint = $configuredApi

if ($PlanOnly) {
    $acquisition = Ensure-AiWingetPackage -Id $plan.PackageId -PlanOnly
    Add-OllamaAcquisition -Action $acquisition.Action -PackageEvidence $null -MigrationEvidence ([ordered]@{
        legacyManagedArchive = [ordered]@{
            requiredWhenLegacyMarkerExists = $architecture -eq 'Arm64'
            preservesModels = $true
        }
        portablePackage = Remove-OllamaPortablePackage -PlanOnly
    })
    Add-AiReportPhase -Report $report -Name 'installed-application' -Status 'planned' -Evidence @{
        packageId = $plan.PackageId
        architecture = $architecture
        installerUrl = $manifestEvidence.InstallerUrl
        nativeExecutableRequired = $true
    }
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{ model = 'qwen3:0.6b' }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: ollama'
    return
}

Assert-AiAdministrator
$migration = Remove-OllamaLegacyManagedInstallation -Paths $legacyPaths
$portableCleanup = Remove-OllamaPortablePackage
if ($portableCleanup.PSObject.Properties['Warning']) {
    [void]$report.result.warnings.Add([string]$portableCleanup.Warning)
}
if ($migration.Migrated) {
    try {
        $unexpectedEndpoint = Invoke-RestMethod -Uri "$configuredApi/api/version" -TimeoutSec 3
        if ($unexpectedEndpoint.version) {
            throw "Endpoint $configuredApi remained active after removing the Dev Config-managed Ollama runtime. Stop the unmanaged instance and rerun."
        }
    } catch {
        if ($_.Exception.Message -match 'remained active') { throw }
    }
}

$acquisition = Ensure-AiWingetPackage -Id $plan.PackageId
Update-DevConfigSessionPath
$ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCommand) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $candidate) {
        $ollamaPath = $candidate
    } else {
        throw 'WinGet installed Ollama.Ollama, but ollama.exe could not be resolved.'
    }
} else {
    $ollamaPath = $ollamaCommand.Source
}
$binaryArchitecture = Get-AiPeArchitecture -Path $ollamaPath
if ($binaryArchitecture -ne $architecture) {
    throw "Ollama.Ollama installed '$binaryArchitecture' ollama.exe on $architecture Windows; refusing emulated or incompatible runtime."
}
Add-OllamaAcquisition -Action $acquisition.Action -PackageEvidence $acquisition.Evidence -MigrationEvidence ([ordered]@{
    legacyManagedArchive = $migration
    portablePackage = $portableCleanup
})
$registeredApplication = Get-OllamaRegisteredApplicationEvidence
if (-not $registeredApplication) {
    throw 'Ollama.Ollama is installed, but its registered application/uninstaller state was not found.'
}

$oldHost = $env:OLLAMA_HOST
$serverProcess = $null
$serverStdout = Join-Path $env:LOCALAPPDATA 'DevConfig\ollama\server.stdout.log'
$serverStderr = Join-Path $env:LOCALAPPDATA 'DevConfig\ollama\server.stderr.log'
try {
    $apiBase = $configuredApi
    try {
        $version = Invoke-RestMethod -Uri "$apiBase/api/version" -TimeoutSec 3
        $serverProcess = Get-CimInstance Win32_Process -Filter "Name = 'ollama.exe'" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    } catch {
        New-Item -ItemType Directory -Path (Split-Path -Parent $serverStdout) -Force | Out-Null
        Remove-Item $serverStdout, $serverStderr -Force -ErrorAction SilentlyContinue
        $env:OLLAMA_HOST = $apiBase
        $serverProcess = Start-Process `
            -FilePath $ollamaPath `
            -ArgumentList 'serve' `
            -WindowStyle Hidden `
            -RedirectStandardOutput $serverStdout `
            -RedirectStandardError $serverStderr `
            -PassThru
        # The API waits for GPU discovery, which can take over 40 seconds on CPU-only machines.
        Write-Host 'Waiting for the Ollama server to start. This can take up to 2 minutes.'
        try {
            $version = Wait-JsonEndpoint -Uri ([uri]"$apiBase/api/version") -TimeoutSeconds 120 -Process $serverProcess
        } catch {
            $serverLog = (Get-Content -LiteralPath $serverStderr -Tail 10 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
            throw "$($_.Exception.Message) Server log ($serverStderr):$([Environment]::NewLine)$serverLog"
        }
    }
    if ([string]$version.version -ne [string]$manifestEvidence.Version) {
        throw "Ollama API reported version '$($version.version)', expected WinGet installer version '$($manifestEvidence.Version)'."
    }

    $env:OLLAMA_HOST = $apiBase
    Invoke-CheckedCommand -FilePath $ollamaPath -ArgumentList @('--version') -DisplayName 'Ollama CLI verification'
    $report.acceptance.server = [ordered]@{
        endpoint = $apiBase
        processId = Get-AiProcessId -ProcessObject $serverProcess
        executable = $ollamaPath
        executableArchitecture = $binaryArchitecture
        version = $version.version
        packageId = $plan.PackageId
        installerUrl = $manifestEvidence.InstallerUrl
        installerSha256 = $manifestEvidence.InstallerSha256
        registeredPackage = $acquisition.Evidence
        registeredApplication = $registeredApplication
        stdoutLog = $serverStdout
        stderrLog = $serverStderr
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
        $serverEvidence = if (Test-Path -LiteralPath $serverStderr) {
            (Get-Content -LiteralPath $serverStderr -Tail 200 | Select-String 'inference compute|gpu memory|library=' | Out-String).Trim()
        } else { '' }
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
    $env:OLLAMA_HOST = $oldHost
}

Add-AiReportPhase -Report $report -Name 'ollama-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: ollama'
