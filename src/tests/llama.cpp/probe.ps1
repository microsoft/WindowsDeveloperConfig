$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1')

$runtime = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\runtime'
$llamaCli = Join-Path $runtime 'llama-cli.exe'
$llamaBench = Join-Path $runtime 'llama-bench.exe'
if (-not (Test-Path -LiteralPath $llamaCli) -or -not (Test-Path -LiteralPath $llamaBench)) {
    throw "The resolver-owned llama.cpp runtime was not complete at '$runtime'."
}
& $llamaCli --version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "llama-cli --version failed with exit code $LASTEXITCODE."
}
$plan = Get-LlamaModelSmokePlan
$modelPath = Join-Path $env:LOCALAPPDATA "DevConfig\llama.cpp\models\$($plan.FileName)"
if (-not (Test-Path -LiteralPath $modelPath)) {
    throw "Pinned llama.cpp smoke model was not found at '$modelPath'."
}
$arguments = Get-LlamaInferenceArguments -ModelPath $modelPath -Marker $plan.Marker
$statePath = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\selected-backend.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "llama.cpp selected backend state was not found at '$statePath'. Rerun the installer."
}
$savedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$backend = $savedState.backend
$runtimeDevice = [string]$savedState.requestedDevice
$arguments += @('-ngl', $(if ($backend -eq 'CPU') { '0' } else { '999' }))
if ($backend -eq 'CPU') { $arguments += @('--device', 'none') }
elseif ($runtimeDevice) { $arguments += @('--device', $runtimeDevice) }
$output = (& $llamaCli @arguments 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $output -notmatch [regex]::Escape($plan.Marker)) {
    throw "llama.cpp cached-model inference failed with exit code $LASTEXITCODE. Output: $output"
}
$benchArguments = @(
    '-m', $modelPath,
    '-ngl', $(if ($backend -eq 'CPU') { '0' } else { '999' }),
    '-p', '32', '-n', '1', '-r', '1', '-o', 'json', '-v'
)
if ($backend -eq 'CPU') { $benchArguments += @('--device', 'none') }
elseif ($runtimeDevice) { $benchArguments += @('--device', $runtimeDevice) }
$benchmarkResult = Invoke-AiNativeCommandSeparated -FilePath $llamaBench -Arguments $benchArguments
if ($benchmarkResult.ExitCode -ne 0) {
    throw "llama-bench verification failed: $($benchmarkResult.StandardError)"
}
$parsedBenchmark = ConvertFrom-AiJsonArrayWithDiagnostics `
    -Json $benchmarkResult.StandardOutput `
    -Diagnostics $benchmarkResult.StandardError
$expectedDevice = [string]$savedState.expectedDevice
[void](Get-LlamaBenchmarkBackendEvidence `
    -Data @($parsedBenchmark.Data) `
    -Diagnostics $parsedBenchmark.Diagnostics `
    -Backend $backend `
    -ExpectedDeviceName $(if ($runtimeDevice) { $null } else { $expectedDevice }) `
    -RequestedDevice $runtimeDevice)

Write-Output 'llama.cpp ready'
