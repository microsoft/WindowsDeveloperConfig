$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$python = Join-Path $env:LOCALAPPDATA 'DevConfig\pytorch\.venv\Scripts\python.exe'
$statePath = Join-Path $env:LOCALAPPDATA 'DevConfig\pytorch\install-state.json'
if (-not (Test-Path -LiteralPath $python)) {
    throw "PyTorch environment was not found at '$python'."
}
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "PyTorch install state was not found at '$statePath'."
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
& $python (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\smoke.py') --backend $state.backend *> $null
if ($LASTEXITCODE -ne 0) {
    throw "PyTorch $($state.backend) tensor probe failed with exit code $LASTEXITCODE."
}

Write-Output 'PyTorch ready'
