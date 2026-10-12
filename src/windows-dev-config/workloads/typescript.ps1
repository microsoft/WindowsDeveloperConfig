<#
.SYNOPSIS
  TypeScript: Node.js LTS and the global TypeScript compiler.

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
    Name    = 'TypeScript'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so node, npm, and tsc are on PATH.'
        'Compile a file with: tsc hello.ts'
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
            Parameters = @{ Packages = @('NodeJS') }
        }
        @{
            File     = 'typescript.ps1'
            Function = 'Invoke-TypeScriptPhase'
            Title    = 'TypeScript'
        }
    )
}
