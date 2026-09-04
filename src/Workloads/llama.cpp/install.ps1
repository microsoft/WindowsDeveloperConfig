<#
.SYNOPSIS
  Install and verify llama.cpp without downloading a model.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

$architecture = Get-DevConfigArchitecture
$plan = Resolve-LlamaCppInstallPlan -Architecture $architecture
if ($plan.Method -eq 'WinGet') {
    & (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
        -Id 'llama.cpp' `
        -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
        -RequireCommands @('llama-cli') `
        -DeferSentinel
} else {
    $destination = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp'
    $tag = Install-VerifiedGitHubReleaseAsset `
        -Repository 'ggml-org/llama.cpp' `
        -AssetPattern $plan.AssetPattern `
        -Destination $destination `
        -VersionMarker '.devconfig-version' `
        -RequiredFile 'llama-cli.exe'
    Add-UserPathEntry -Path $destination
    Assert-CommandAvailable -CommandName 'llama-cli' -Remediation "The verified $tag ARM64 archive was extracted to '$destination', but llama-cli.exe was not found." | Out-Null
}

Invoke-CheckedCommand -FilePath 'llama-cli' -ArgumentList @('--version') -DisplayName 'llama.cpp CLI verification'
Invoke-CheckedCommand -FilePath 'llama-cli' -ArgumentList @('--help') -DisplayName 'llama.cpp help verification'
Write-Host "LLAMA_CPP_READY: architecture=$architecture, backend=$($plan.Backend); no model was downloaded."
Write-Host 'INSTALL_OK: llama.cpp'
