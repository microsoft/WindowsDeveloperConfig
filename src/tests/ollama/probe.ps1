$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    throw 'ollama was not found on PATH.'
}
& ollama --version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "ollama --version failed with exit code $LASTEXITCODE."
}
$version = Invoke-RestMethod -Uri 'http://localhost:11434/api/version' -TimeoutSec 10
$models = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 10
if (-not $version.version -or $null -eq $models.models) {
    throw 'Ollama API readiness response was incomplete.'
}

Write-Output 'Ollama ready'
