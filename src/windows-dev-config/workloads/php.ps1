<#
.SYNOPSIS
  PHP: the PHP runtime/CLI.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It follows the same shape as the WinUI
  workload, trimmed to the PHP runtime only. PHP has no app-packaging/sideloading
  story, so the Developer Mode phase is skipped. The phase files under steps\ do
  the work.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name    = 'PHP'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so php is on PATH.'
        'Run a script with: php -S localhost:8000, or php yourscript.php'
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
            Parameters = @{ Packages = @('PowerShell', 'Php') }
        }
    )
}
