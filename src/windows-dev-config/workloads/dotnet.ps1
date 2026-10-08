<#
.SYNOPSIS
  .NET SDK: Developer Mode and .NET SDK 10.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It follows the same shape as the WinUI
  workload, trimmed to the .NET SDK only: no Visual Studio, Windows App Development CLI,
  or UI framework templates. The phase files under steps\ do the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name    = '.NET SDK'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so dotnet is on PATH.'
        'Create an app with: dotnet new console -n MyApp, or any other dotnet new template.'
    )
    Phases  = @(
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
            Parameters = @{ Packages = @('PowerShell', 'DotnetSdk') }
        }
    )
}
