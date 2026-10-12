<#
.SYNOPSIS
  Java: Microsoft OpenJDK 25.

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
    Name    = 'Java'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so java and javac are on PATH.'
        'Run a source file with: java Hello.java'
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
            Parameters = @{ Packages = @('Java') }
        }
    )
}
