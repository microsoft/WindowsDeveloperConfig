<#
.SYNOPSIS
  Go: the Go toolchain.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It follows the same shape as the WinUI
  workload, trimmed to the Go toolchain only. The phase files under steps\ do the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name    = 'Go'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so go is on PATH.'
        'Create a module with: go mod init example.com/myapp'
    )
    Phases  = @(
        @{
            File     = 'prerequisites.ps1'
            Function = 'Invoke-PrerequisitesPhase'
            Title    = 'Getting ready'
        }
        @{
            File       = 'packages.ps1'
            Function   = 'Invoke-PackagesPhase'
            Title      = 'Packages'
            Parameters = @{ Packages = @('PowerShell', 'Go') }
        }
    )
}
