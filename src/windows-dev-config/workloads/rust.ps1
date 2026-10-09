<#
.SYNOPSIS
  Rust: Rustup, Visual Studio Community's C++ desktop workload (for the msvc toolchain's linker),
  and the stable Rust toolchain.

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

# The workload marks MSVC and the Windows SDK as recommended, so --add alone skips them.
$architecture = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE'
$msvcTools = switch ($architecture) {
    'AMD64' { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
    'ARM64' { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
    default { throw "Unsupported Windows architecture: $architecture" }
}
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
                    $msvcTools
                    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
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
