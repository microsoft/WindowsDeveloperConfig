$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-support.ps1')

if (-not (Get-Command llama-cli -ErrorAction SilentlyContinue)) {
    throw 'llama-cli was not found on PATH.'
}
& llama-cli --version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "llama-cli --version failed with exit code $LASTEXITCODE."
}
$plan = Get-LlamaModelSmokePlan
$modelPath = Join-Path $env:LOCALAPPDATA "DevConfig\llama.cpp\models\$($plan.FileName)"
if (-not (Test-Path -LiteralPath $modelPath)) {
    throw "Pinned llama.cpp smoke model was not found at '$modelPath'."
}
$arguments = Get-LlamaInferenceArguments -ModelPath $modelPath -Marker $plan.Marker
$output = (& llama-cli @arguments 2>$null | Out-String)
if ($LASTEXITCODE -ne 0 -or $output -notmatch [regex]::Escape($plan.Marker)) {
    throw "llama.cpp cached-model inference failed with exit code $LASTEXITCODE."
}

Write-Output 'llama.cpp ready'
