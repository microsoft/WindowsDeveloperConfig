<#
.SYNOPSIS
  PowerShell 7, VS Code, PowerShell tooling, and analyzer settings.

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
    Name    = 'PowerShell'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so pwsh is on PATH.'
        'Start PowerShell with: pwsh'
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
            Parameters = @{ Packages = @('PowerShell', 'VSCode') }
        }
        @{
            File       = 'vscode-extensions.ps1'
            Function   = 'Invoke-VSCodeExtensionsPhase'
            Title      = 'VS Code extensions'
            Parameters = @{ Extensions = @('ms-vscode.powershell', 'pspester.pester-test') }
        }
        @{
            File     = 'powershell-analyzer.ps1'
            Function = 'Invoke-PowerShellAnalyzerPhase'
            Title    = 'PSScriptAnalyzer settings'
        }
    )
}
