<#
.SYNOPSIS
  GitHub Copilot Windows Terminal profile, WinUI templates, and the win-dev-skills Copilot plugin.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:CopilotFragmentGuid = '{b1a4d2c8-6f3e-4a7b-9e2d-1c8f5a3b7d91}'

function Get-DevConfigCopilotFragmentDir {
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\DevConfig'
}

function Test-DevConfigCopilotTerminalProfile {
    $fragmentPath = Join-Path (Get-DevConfigCopilotFragmentDir) 'github-copilot.fragment.json'
    return Test-Path -LiteralPath $fragmentPath
}

function Set-DevConfigCopilotTerminalProfile {
    $fragmentsDir = Get-DevConfigCopilotFragmentDir
    New-Item -ItemType Directory -Path $fragmentsDir -Force | Out-Null

    # Icon lives alongside the fragment file so its relative path resolves correctly.
    $iconPath = Join-Path $fragmentsDir 'copilot.png'
    Invoke-WebRequest -Uri 'https://github.githubassets.com/favicons/favicon-dark.png' -OutFile $iconPath -UseBasicParsing

    $fragment = @{
        profiles = @(
            @{
                guid              = $Script:CopilotFragmentGuid
                name              = 'GitHub Copilot'
                commandline       = 'pwsh.exe -NoExit -Command "copilot"'
                icon              = 'copilot.png'
                startingDirectory = '%USERPROFILE%'
                hidden            = $false
                tabTitle          = 'Copilot'
            }
        )
    }

    $fragmentFile = Join-Path $fragmentsDir 'github-copilot.fragment.json'
    $fragment | ConvertTo-Json -Depth 8 | Out-File -FilePath $fragmentFile -Encoding Utf8

    # Touch settings.json so Windows Terminal's hot-reload re-scans Fragments\*.json.
    @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    ) | Where-Object { Test-Path $_ } | ForEach-Object {
        try { (Get-Item -LiteralPath $_).LastWriteTime = Get-Date } catch {}
    }

    Write-Host "GitHub Copilot profile fragment written to $fragmentFile"
    Write-Host "Open Windows Terminal: the 'GitHub Copilot' profile is available in the dropdown."
}

function Test-DevConfigWinUITemplatesInstalled {
    return [bool](dotnet new list 2>&1 | Select-String -Pattern 'winui' -CaseSensitive:$false)
}

function Install-DevConfigWinUITemplates {
    dotnet new install Microsoft.WindowsAppSDK.WinUI.CSharp.Templates
}

function Test-DevConfigWinSkillsMarketplaceAdded {
    return [bool](copilot plugin marketplace list 2>&1 | Select-String 'win-dev-skills')
}

function Add-DevConfigWinSkillsMarketplace {
    copilot plugin marketplace add microsoft/win-dev-skills
}

function Test-DevConfigWinUIPluginInstalled {
    return [bool](copilot plugin list 2>&1 | Select-String 'winui')
}

function Install-DevConfigWinUIPlugin {
    copilot plugin install winui@win-dev-skills
}

function Invoke-CopilotPhase {
    $steps = @(
        New-DevConfigStep -Name 'GitHubCopilotProfile' -Description 'Add a GitHub Copilot profile to Windows Terminal' `
            -Check { Test-DevConfigCopilotTerminalProfile } `
            -Apply { Set-DevConfigCopilotTerminalProfile }
        New-DevConfigStep -Name 'WinUITemplates' -Description 'Install WinUI dotnet-new templates' `
            -Check { Test-DevConfigWinUITemplatesInstalled } `
            -Apply { Install-DevConfigWinUITemplates }
        New-DevConfigStep -Name 'WinSkillsMarketplace' -Description 'Add win-dev-skills to the Copilot plugin marketplace' `
            -Check { Test-DevConfigWinSkillsMarketplaceAdded } `
            -Apply { Add-DevConfigWinSkillsMarketplace }
        New-DevConfigStep -Name 'WinUIPlugin' -Description 'Install the WinUI Copilot plugin from win-dev-skills' `
            -Check { Test-DevConfigWinUIPluginInstalled } `
            -Apply { Install-DevConfigWinUIPlugin }
    )

    Invoke-DevConfigSteps -Steps $steps
}
