[CmdletBinding()]
param([string] $OutputPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\Workloads\_common\ai-support.ps1')

$document = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    capabilities = @(Get-AiCapabilityMatrix)
}
$json = $document | ConvertTo-Json -Depth 20
if (-not $OutputPath) {
    $json
    return
}

$resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$parent = Split-Path -Parent $resolvedPath
if ($parent) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
[System.IO.File]::WriteAllText($resolvedPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "AI_CAPABILITY_REPORT: $resolvedPath"
