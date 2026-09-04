$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command nvcc -ErrorAction SilentlyContinue)) {
    throw 'nvcc was not found on PATH.'
}
& nvcc --version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "nvcc --version failed with exit code $LASTEXITCODE."
}
& nvidia-smi *> $null
if ($LASTEXITCODE -ne 0) {
    throw "nvidia-smi failed with exit code $LASTEXITCODE."
}

Write-Output 'CUDA ready'
