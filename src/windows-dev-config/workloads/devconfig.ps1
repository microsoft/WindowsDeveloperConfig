<#
.SYNOPSIS
  Windows Dev Config: developer tools, Windows settings, fonts, Terminal, and WSL + Ubuntu.

.DESCRIPTION
  Workload definition read by dev-config.ps1. It only lists phases; the phase files under
  steps\ do the work. This is the default workload behind setup-full.ps1,
  setup-standard.ps1 (Partial), and uninstall.ps1.
#>

[CmdletBinding()]
param(
    [string] $Action = 'Full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# WSL stays last so its required reboot happens after other phases.
$phases = @(
    @{
        File     = 'prerequisites.ps1'
        Function = 'Invoke-PrerequisitesPhase'
        Title    = 'Getting ready'
    }
    @{
        File       = 'packages.ps1'
        Function   = 'Invoke-PackagesPhase'
        Title      = 'Packages'
        Uninstall  = $true
        # Install order; names refer to the package catalog in steps\packages.ps1.
        Parameters = @{
            Packages = @(
                'Terminal'
                'IntelligentTerminal'
                'PowerShell'
                'Git'
                'GitHubCLI'
                'AzureCLI'
                'GitHubCopilot'
                'VSCode'
                'DotnetSdk'
                'Python'
                'VCRedist'
                'UV'
                'NodeJS'
                'nvmForNode'
                'Coreutils'
                'OhMyPosh'
                'winappCli'
                'PowerToys'
            )
        }
    }
    @{
        File      = 'registry-system.ps1'
        Function  = 'Invoke-RegistrySystemPhase'
        Title     = 'System settings'
        Uninstall = $true
    }
    @{
        File      = 'registry-explorer.ps1'
        Function  = 'Invoke-RegistryExplorerPhase'
        Title     = 'File Explorer tweaks'
        Uninstall = $true
    }
    @{
        File      = 'registry-taskbar-search.ps1'
        Function  = 'Invoke-RegistryTaskbarSearchPhase'
        Title     = 'Taskbar, search & start tweaks'
        Uninstall = $true
    }
    @{
        File      = 'edge.ps1'
        Function  = 'Invoke-EdgePhase'
        Title     = 'Microsoft Edge tweaks'
        Uninstall = $true
    }
    @{
        File     = 'fonts.ps1'
        Function = 'Invoke-FontsPhase'
        Title    = 'Fonts'
    }
    @{
        File      = 'terminal.ps1'
        Function  = 'Invoke-TerminalPhase'
        Title     = 'Windows Terminal'
        Uninstall = $true
    }
    @{
        File      = 'powershell-profile.ps1'
        Function  = 'Invoke-PowerShellProfilePhase'
        Title     = 'PowerShell profile'
        Uninstall = $true
    }
    @{
        File      = 'copilot.ps1'
        Function  = 'Invoke-CopilotPhase'
        Title     = 'GitHub Copilot'
        Uninstall = $true
    }
    @{
        File      = 'wsl.ps1'
        Function  = 'Invoke-WslPhase'
        Title     = 'WSL + Ubuntu'
        Uninstall = $true
    }
)
if ($Action -eq 'Partial') {
    $phases = @($phases | Where-Object { $_.File -ne 'edge.ps1' })
    ($phases | Where-Object { $_.File -eq 'registry-taskbar-search.ps1' }).Title = 'Taskbar & Start tweaks'
} elseif ($Action -eq 'Uninstall') {
    $phases = @($phases | Where-Object { $_['Uninstall'] })
    # Reset Terminal after removing the tools and WSL fragments that can recreate profiles.
    $phases = @($phases | Where-Object { $_.File -notin @('packages.ps1', 'terminal.ps1') }) +
        @($phases | Where-Object { $_.File -eq 'packages.ps1' }) +
        @($phases | Where-Object { $_.File -eq 'terminal.ps1' })
}

@{
    Name             = 'Calm OS'
    Actions          = @('Full', 'Partial', 'Uninstall')
    SetupNote        = 'one reboot expected along the way'
    UninstallWarning = 'Ubuntu and its files will be deleted. Targeted tools are removed even if they predate setup.'
    Notes            = @('A few Explorer and taskbar changes appear once you sign out and back in.')
    Phases           = $phases
}
