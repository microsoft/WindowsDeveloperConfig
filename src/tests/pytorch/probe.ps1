$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$python = Join-Path $env:LOCALAPPDATA 'DevConfig\pytorch\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    throw "PyTorch environment was not found at '$python'."
}
& $python -c "import torch; x=torch.tensor([1.,2.]); assert (x*2).tolist()==[2.,4.]" *> $null
if ($LASTEXITCODE -ne 0) {
    throw "PyTorch CPU tensor probe failed with exit code $LASTEXITCODE."
}

Write-Output 'PyTorch ready'
