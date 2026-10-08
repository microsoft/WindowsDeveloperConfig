<#
.SYNOPSIS
  WinForms: Developer Mode, .NET SDK 10, and Visual Studio Community 2026 with the
  .NET desktop development workload.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It follows the same shape as the WinUI
  workload, trimmed to what a Windows Forms app needs: no Windows App SDK component,
  Windows App Development CLI, or WinUI templates. The phase files under steps\ do the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Visual Studio 2026 supports Windows 11 and Windows Server 2019 or later.
$isClient = (Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType') -eq 'Client'

@{
    Name             = 'WinForms'
    Actions          = @('Full')
    MinimumOSVersion = if ($isClient) { '10.0.22000' } else { '10.0.17763' }
    SetupNote        = 'Visual Studio is a multi-GB download'
    Notes            = @(
        'Open a new terminal so dotnet is on PATH.'
        'Create an app with: dotnet new winforms -n MyApp, or the Windows Forms App template in Visual Studio.'
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
            Parameters = @{ Packages = @('PowerShell', 'DotnetSdk', 'VisualStudioCommunity') }
        }
        @{
            File       = 'visual-studio.ps1'
            Function   = 'Invoke-VisualStudioPhase'
            Title      = 'Visual Studio workloads'
            Parameters = @{
                Components = @(
                    'Microsoft.VisualStudio.Workload.ManagedDesktop'
                )
            }
        }
    )
}
