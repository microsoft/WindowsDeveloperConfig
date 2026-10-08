<#
.SYNOPSIS
  Windows App Development CLI: Developer Mode, .NET SDK 10, and the Windows App
  Development CLI (winapp).

.DESCRIPTION
  Workload definition read by dev-config.ps1. It follows the same shape as the WinUI
  workload, trimmed to the command-line tooling only: no Visual Studio. The phase files
  under steps\ do the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name             = 'Windows App Development CLI'
    Actions          = @('Full')
    MinimumOSVersion = '10.0.17763'
    Notes            = @(
        'Open a new terminal so dotnet and winapp are on PATH.'
    )
    Phases           = @(
        @{
            File     = 'prerequisites.ps1'
            Function = 'Invoke-PrerequisitesPhase'
            Title    = 'Getting ready'
        }
        @{
            File     = 'registry-system.ps1'
            Function = 'Invoke-RegistrySystemPhase'
            Title    = 'Developer Mode'
            Steps    = @('DeveloperMode')
        }
        @{
            File       = 'packages.ps1'
            Function   = 'Invoke-PackagesPhase'
            Title      = 'Packages'
            Parameters = @{ Packages = @('PowerShell', 'DotnetSdk', 'winappCli') }
        }
    )
}
