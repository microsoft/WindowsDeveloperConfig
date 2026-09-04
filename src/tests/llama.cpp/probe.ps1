$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command llama-cli -ErrorAction SilentlyContinue)) {
    throw 'llama-cli was not found on PATH.'
}
& llama-cli --version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "llama-cli --version failed with exit code $LASTEXITCODE."
}
& llama-cli --help *> $null
if ($LASTEXITCODE -ne 0) {
    throw "llama-cli --help failed with exit code $LASTEXITCODE."
}

Write-Output 'llama.cpp ready'
