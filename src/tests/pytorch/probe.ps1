$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\_environment.ps1')

$python = Join-Path $env:LOCALAPPDATA 'DevConfig\pytorch\.venv\Scripts\python.exe'
$statePath = Join-Path $env:LOCALAPPDATA 'DevConfig\pytorch\install-state.json'
if (-not (Test-Path -LiteralPath $python)) {
    throw "PyTorch environment was not found at '$python'."
}
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "PyTorch install state was not found at '$statePath'."
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$deviceIndex = if ($state.PSObject.Properties['deviceIndex']) { [int]$state.deviceIndex } else { 0 }
$result = Invoke-DevConfigNativeCommand -FilePath $python -Arguments @(
    (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\smoke.py'), '--backend', $state.backend, '--device-index', $deviceIndex
)
if ($result.ExitCode -ne 0) {
    throw "PyTorch $($state.backend) tensor probe failed with exit code $($result.ExitCode). $($result.Output)"
}

Write-Output 'PyTorch ready'
