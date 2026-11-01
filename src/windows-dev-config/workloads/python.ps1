<#
.SYNOPSIS
  Python: CPython 3.14 and uv.

.DESCRIPTION
  Workload definition read by dev-config.ps1. The phase files under steps\ do
  the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name    = 'Python'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so python, pip, and uv are on PATH.'
        'Create a project with: uv init'
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
            Parameters = @{ Packages = @('Python', 'UV') }
        }
    )
}
