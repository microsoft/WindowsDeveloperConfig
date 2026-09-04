$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
    throw 'foundry was not found on PATH.'
}
& foundry --version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "foundry --version failed with exit code $LASTEXITCODE."
}
& foundry server status *> $null
if ($LASTEXITCODE -ne 0) {
    throw "foundry server status failed with exit code $LASTEXITCODE."
}

Write-Output 'Foundry Local ready'
