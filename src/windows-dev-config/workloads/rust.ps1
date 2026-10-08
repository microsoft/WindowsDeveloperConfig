<#
.SYNOPSIS
  Rust: Developer Mode, Rustup, Visual Studio Community's C++ desktop workload (for the
  msvc toolchain's linker), and the stable Rust toolchain.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It follows the same shape as the WinUI workload:
  Visual Studio provides the C++ build tools Rust's default msvc toolchain needs, reusing the
  same shared Visual Studio Community instance instead of a separate Build Tools SKU. The phase
  files under steps\ do the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name      = 'Rust'
    Actions   = @('Full')
    SetupNote = 'Visual Studio is a multi-GB download'
    Notes     = @(
        'Open a new terminal so rustc and cargo are on PATH.'
        'Create a project with: cargo new myapp'
    )
    Phases    = @(
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
            Parameters = @{ Packages = @('PowerShell', 'Rustup', 'VisualStudioCommunity') }
        }
        @{
            File       = 'visual-studio.ps1'
            Function   = 'Invoke-VisualStudioPhase'
            Title      = 'Visual Studio workloads'
            Parameters = @{
                Components = @(
                    'Microsoft.VisualStudio.Workload.NativeDesktop'
                )
            }
        }
        @{
            File     = 'rust-toolchain.ps1'
            Function = 'Invoke-RustToolchainPhase'
            Title    = 'Rust toolchain'
        }
    )
}
