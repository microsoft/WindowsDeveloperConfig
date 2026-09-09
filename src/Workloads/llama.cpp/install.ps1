<#
.SYNOPSIS
  Install llama.cpp, acquire a pinned small GGUF, and run text inference.

.PARAMETER SkipModelSmoke
  Skip the default Qwen3-0.6B GGUF download and inference. The install then
  verifies only the CLI and does not claim workload readiness.
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
$driver = Get-NvidiaDriverInfo
$plan = Resolve-LlamaCppInstallPlan `
    -Architecture $architecture `
    -HasNvidia ([bool]$driver) `
    -DriverMajor $(if ($driver) { $driver.DriverMajor } else { 0 }) `
    -ComputeCapability $(if ($driver) { $driver.ComputeCapability } else { [version]'0.0' })
$component = (Get-AiCatalog).Components.LlamaCppRolling
$report = New-AiWorkloadReport -Id 'llama.cpp' -Request @{
    SkipModelSmoke = [bool]$SkipModelSmoke
    PlanOnly = [bool]$PlanOnly
    SelectedBackend = $plan.Backend
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'llama.cpp' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
if (-not $PlanOnly) { Assert-AiAdministrator }
if ($plan.Method -eq 'WinGet') {
    $acquisition = Ensure-AiWingetPackage -Id 'ggml.llamacpp' -PlanOnly:$PlanOnly
    if (-not $PlanOnly) {
        Update-DevConfigSessionPath
        $llamaCli = (Get-Command llama-cli -ErrorAction Stop).Source
        $llamaBench = (Get-Command llama-bench -ErrorAction Stop).Source
    }
} else {
    $legacyDestination = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp'
    $destination = Join-Path $legacyDestination 'runtime'
    if ($PlanOnly) {
        $acquisition = [pscustomobject]@{ Action = 'resolve-rolling-release'; Source = 'github' }
    } else {
        $tag = Install-VerifiedGitHubReleaseAssets `
            -Repository 'ggml-org/llama.cpp' `
            -AssetPatterns $plan.AssetPatterns `
            -Destination $destination `
            -VersionMarker '.devconfig-version' `
            -RequiredFile 'llama-cli.exe'
        Remove-UserPathEntry -Path $legacyDestination
        Add-UserPathEntry -Path $destination
        $llamaCli = Join-Path $destination 'llama-cli.exe'
        $llamaBench = Join-Path $destination 'llama-bench.exe'
        if (-not (Test-Path -LiteralPath $llamaCli) -or -not (Test-Path -LiteralPath $llamaBench)) {
            throw "The verified $tag ARM64 archive was extracted to '$destination', but required llama.cpp executables were not found."
        }
        $acquisition = [pscustomobject]@{ Action = 'resolved'; Source = 'github'; Tag = $tag }
    }
}
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $component.Vendor
    architecture = $architecture
    maturity = $(if ($plan.Method -eq 'WinGet') { 'stable-community-winget' } else { $component.Maturity })
    sourceType = $(if ($plan.Method -eq 'WinGet') { 'winget' } else { $component.SourceType })
    packageId = $(if ($plan.Method -eq 'WinGet') { 'ggml.llamacpp' } else { $null })
    repository = $component.Repository
    backend = $plan.Backend
    assetPatterns = $plan.AssetPatterns
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = $component.InstallPath
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = $acquisition.Action
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{
        model = 'Qwen3-0.6B-Q4_K_M.gguf'
        backend = $plan.Backend
    }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: llama.cpp'
    return
}

Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--version') -DisplayName 'llama.cpp CLI verification'
Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--help') -DisplayName 'llama.cpp help verification'

$modelPlan = Get-LlamaModelSmokePlan
$inferenceEvidence = $null
if ($SkipModelSmoke) {
    Write-Warning 'LLAMA_CPP_MODEL_SMOKE_SKIPPED: CLI is ready, but no model inference was performed.'
} else {
    $modelDirectory = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\models'
    $modelPath = Join-Path $modelDirectory $modelPlan.FileName
    Write-Host "Downloading pinned $($modelPlan.Repository) model $($modelPlan.FileName) (approximately $([math]::Round($modelPlan.Size / 1MB)) MB, $($modelPlan.License))."
    Install-VerifiedDownload `
        -Uri $modelPlan.Url `
        -Destination $modelPath `
        -Sha256 $modelPlan.Sha256 `
        -ExpectedSize $modelPlan.Size
    $arguments = Get-LlamaInferenceArguments -ModelPath $modelPath -Marker $modelPlan.Marker
    $output = (& $llamaCli @arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $output -notmatch [regex]::Escape($modelPlan.Marker)) {
        throw "llama.cpp model inference did not produce marker '$($modelPlan.Marker)' (exit $LASTEXITCODE). Output: $output"
    }
    $benchArguments = @(
        '-m', $modelPath,
        '-ngl', $(if ($plan.Backend -eq 'CPU') { '0' } else { '999' }),
        '-p', '32', '-n', '1', '-r', '1', '-o', 'json'
    )
    if ($plan.Backend -eq 'CPU') {
        $benchArguments += @('--device', 'none')
    }
    $benchmark = (& $llamaBench @benchArguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "llama-bench failed while collecting backend evidence (exit $LASTEXITCODE): $benchmark"
    }
    $report.acceptance.inference = [ordered]@{
        model = $modelPlan.FileName
        modelSha256 = $modelPlan.Sha256
        marker = $modelPlan.Marker
        backendPlan = $plan.Backend
        benchmarkJson = $benchmark
    }
    $inferenceEvidence = $report.acceptance.inference
    try {
        $benchData = $benchmark | ConvertFrom-Json
        $measurements = @($benchData)
        $gpuMeasurements = @($measurements | Where-Object { [int]$_.n_gpu_layers -gt 0 })
        $report.result.fallbackUsed = $plan.Backend -ne 'CPU' -and $gpuMeasurements.Count -eq 0
    } catch {
        [void]$report.result.warnings.Add('llama-bench output could not be parsed as JSON; inspect acceptance.benchmarkJson.')
    }
    Write-Host "LLAMA_CPP_READY: architecture=$architecture, backend=$($plan.Backend), model=$($modelPlan.FileName), sha256=$($modelPlan.Sha256)."
}
Add-AiReportPhase -Report $report -Name 'llama-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: llama.cpp'
