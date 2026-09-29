<#
.SYNOPSIS
  WinUI 3: Developer Mode, .NET SDK 10, the Windows App Development CLI, Visual Studio
  Community 2026 with the WinUI workloads, and the WinUI dotnet-new templates.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It follows the Microsoft Learn WinUI onboarding
  (https://learn.microsoft.com/windows/apps/get-started/start-here) and installs what
  Workloads\winui\configuration.winget does, without needing winget configure. The phase
  files under steps\ do the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name             = 'WinUI'
    Actions          = @('Full')
    # The Windows App SDK requires Windows 10 version 1809 or later.
    MinimumOSVersion = '10.0.17763'
    SetupNote        = 'Visual Studio alone is a multi-GB download'
    Notes            = @(
        'Open a new terminal so dotnet and winapp are on PATH.'
        'Create an app with: dotnet new winui -n MyApp, or the WinUI Blank App (Packaged) template in Visual Studio.'
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
            # Visual Studio is last so the quick installs finish before its long download.
            Parameters = @{ Packages = @('PowerShell', 'DotnetSdk', 'winappCli', 'VisualStudioCommunity') }
        }
        @{
            File       = 'visual-studio.ps1'
            Function   = 'Invoke-VisualStudioPhase'
            Title      = 'Visual Studio workloads'
            Parameters = @{
                Components = @(
                    'Microsoft.VisualStudio.Workload.ManagedDesktop'
                    'Microsoft.VisualStudio.Workload.Universal'
                    # .NET WinUI app development tools. The VS 2022 ID ComponentGroup.WindowsAppSDK.Cs is not in 18.x.
                    'Microsoft.VisualStudio.Component.WindowsAppSdkSupport.CSharp'
                )
            }
        }
        @{
            # The WinUI dotnet-new templates step is shared with Dev Config's GitHub Copilot phase.
            File     = 'copilot.ps1'
            Function = 'Invoke-CopilotPhase'
            Title    = 'WinUI templates'
            Steps    = @('WinUITemplates')
        }
    )
}
