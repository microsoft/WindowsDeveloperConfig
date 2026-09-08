<#
.SYNOPSIS
  Install llama.cpp, acquire a pinned small GGUF, and run text inference.

.PARAMETER SkipModelSmoke
  Skip the default Qwen3-0.6B GGUF download and inference. The install then
  verifies only the CLI and does not claim workload readiness.
#>
[CmdletBinding()]
param([switch] $SkipModelSmoke)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
$driver = Get-NvidiaDriverInfo
$plan = Resolve-LlamaCppInstallPlan `
    -Architecture $architecture `
    -HasNvidia ([bool]$driver) `
    -DriverMajor $(if ($driver) { $driver.DriverMajor } else { 0 }) `
    -ComputeCapability $(if ($driver) { $driver.ComputeCapability } else { [version]'0.0' })
if ($plan.Method -eq 'WinGet') {
    & (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
        -Id 'llama.cpp' `
        -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
        -RequireCommands @('llama-cli') `
        -DeferSentinel
    $llamaCli = (Get-Command llama-cli -ErrorAction Stop).Source
} else {
    $legacyDestination = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp'
    $destination = Join-Path $legacyDestination 'runtime'
    $tag = Install-VerifiedGitHubReleaseAssets `
        -Repository 'ggml-org/llama.cpp' `
        -AssetPatterns $plan.AssetPatterns `
        -Destination $destination `
        -VersionMarker '.devconfig-version' `
        -RequiredFile 'llama-cli.exe'
    Remove-UserPathEntry -Path $legacyDestination
    Add-UserPathEntry -Path $destination
    $llamaCli = Join-Path $destination 'llama-cli.exe'
    if (-not (Test-Path -LiteralPath $llamaCli)) {
        throw "The verified $tag ARM64 archive was extracted to '$destination', but llama-cli.exe was not found."
    }
}

Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--version') -DisplayName 'llama.cpp CLI verification'
Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--help') -DisplayName 'llama.cpp help verification'

$modelPlan = Get-LlamaModelSmokePlan
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
    Write-Host "LLAMA_CPP_READY: architecture=$architecture, backend=$($plan.Backend), model=$($modelPlan.FileName), sha256=$($modelPlan.Sha256)."
}
Write-Host 'INSTALL_OK: llama.cpp'
