<#
.SYNOPSIS
  Install Foundry Local and verify its CLI and local server without downloading a model.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-FoundryInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
Write-Host "Foundry Local plan: $($plan.Architecture), WinML, CUDA dependency: $($plan.RequiresCuda)"

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id 'foundry' `
    -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('foundry') `
    -DeferSentinel

Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('--version') -DisplayName 'Foundry Local CLI verification'
& foundry server status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Foundry Local server is not ready; restarting it once.'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'restart') -DisplayName 'Foundry Local server restart'
    Invoke-CheckedCommand -FilePath 'foundry' -ArgumentList @('server', 'status') -DisplayName 'Foundry Local server readiness'
}

Write-Host 'FOUNDRY_READY: CLI and local server are available; no model was downloaded.'
Write-Host 'INSTALL_OK: foundry'
