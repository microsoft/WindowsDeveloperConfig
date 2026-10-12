<#
.SYNOPSIS
  Lightweight SQL developer workload.

.DESCRIPTION
  Installs SQL Server Developer, sqlcmd, VS Code, and the SQL Database
  Projects extension without installing Visual Studio or SSDT.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

@{
    Name    = 'SQL Developer'
    Actions = @('Full')
    Notes   = @(
        'Open a new terminal so sqlcmd is on PATH.'
        'Connect to a local server with: sqlcmd -S localhost -E'
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
            Parameters = @{ Packages = @('PowerShell', 'VSCode', 'Sqlcmd', 'SQLServerDeveloper') }
        }
        @{
            File       = 'vscode-extensions.ps1'
            Function   = 'Invoke-VSCodeExtensionsPhase'
            Title      = 'VS Code extensions'
            Parameters = @{ Extensions = @('ms-mssql.sql-database-projects-vscode') }
        }
    )
}
