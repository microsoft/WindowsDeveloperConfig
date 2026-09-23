<#
.SYNOPSIS
  GitHub Copilot Windows Terminal profile, WinUI templates, and the win-dev-skills Copilot plugin.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigWinUITemplatePackage = 'Microsoft.WindowsAppSDK.WinUI.CSharp.Templates'
$Script:DevConfigWinSkillsMarketplace = 'win-dev-skills'
$Script:DevConfigWinUIPlugin = "winui@$Script:DevConfigWinSkillsMarketplace"

function Test-DevConfigCopilotTerminalProfile {
    $fragmentsDir = Get-DevConfigCopilotFragmentDir
    $fragmentPath = Join-Path $fragmentsDir 'github-copilot.fragment.json'
    if (-not (Test-Path -LiteralPath $fragmentPath)) {
        return $false
    }
    $fragment = (Read-DevConfigTextFile -Path $fragmentPath) | ConvertFrom-Json
    $profiles = @($fragment.profiles | Where-Object { $_.guid -eq $Script:CopilotFragmentGuid })
    if ($profiles.Count -ne 1) {
        return $false
    }
    $icon = $profiles[0].PSObject.Properties['icon']
    return (-not $icon) -or ($icon.Value -eq (Join-Path $fragmentsDir 'copilot.png'))
}

function Set-DevConfigCopilotTerminalProfile {
    $fragmentsDir = Get-DevConfigCopilotFragmentDir
    New-Item -ItemType Directory -Path $fragmentsDir -Force | Out-Null

    $iconPath = Join-Path $fragmentsDir 'copilot.png'
    $icon = $null
    try {
        Invoke-WebRequest -Uri 'https://github.githubassets.com/favicons/favicon-dark.png' -OutFile $iconPath -UseBasicParsing -TimeoutSec 60
        $icon = $iconPath
    } catch {
        Write-Host "  (Couldn't download the Copilot icon -- the profile will use the default one.)"
    }

    $profileEntry = [ordered]@{
        guid              = $Script:CopilotFragmentGuid
        name              = 'GitHub Copilot'
        commandline       = 'pwsh.exe -NoExit -Command "copilot"'
        startingDirectory = '%USERPROFILE%'
        hidden            = $false
        tabTitle          = 'Copilot'
    }
    if ($icon) {
        $profileEntry['icon'] = $icon
    }
    $fragment = @{ profiles = @($profileEntry) }

    $fragmentFile = Join-Path $fragmentsDir 'github-copilot.fragment.json'
    Write-DevConfigTextFile -Path $fragmentFile -Content ($fragment | ConvertTo-Json -Depth 8)

    # Touch settings.json so Windows Terminal hot reload re-scans Fragments\*.json.
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
    if (-not (Get-Command 'dotnet' -ErrorAction SilentlyContinue)) {
        return $false
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'dotnet' -Arguments @('new', 'list')
    return $r.ExitCode -eq 0 -and $r.Output -match '(?i)winui'
}

function Install-DevConfigWinUITemplates {
    if (-not (Get-Command 'dotnet' -ErrorAction SilentlyContinue)) {
        throw 'dotnet is not on PATH yet, so the WinUI templates cannot be installed. Re-run once the .NET SDK is in place.'
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'dotnet' -Arguments @('new', 'install', $Script:DevConfigWinUITemplatePackage)
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Output
        throw "dotnet new install failed with exit code $($r.ExitCode)"
    }
}

function Test-DevConfigWinSkillsMarketplaceAdded {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        return $false
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'list')
    return $r.ExitCode -eq 0 -and $r.Output -match [regex]::Escape($Script:DevConfigWinSkillsMarketplace)
}

function Add-DevConfigWinSkillsMarketplace {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        throw 'The copilot command is not on PATH yet, so its marketplace cannot be configured. Re-run once GitHub Copilot CLI is in place.'
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'add', "microsoft/$Script:DevConfigWinSkillsMarketplace")
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Output
        throw "copilot plugin marketplace add failed with exit code $($r.ExitCode)"
    }
}

function Test-DevConfigWinUIPluginInstalled {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        return $false
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'list')
    return $r.ExitCode -eq 0 -and $r.Output -match '(?i)winui'
}

function Install-DevConfigWinUIPlugin {
    if (-not (Get-Command 'copilot' -ErrorAction SilentlyContinue)) {
        throw 'The copilot command is not on PATH yet, so the WinUI plugin cannot be installed. Re-run once GitHub Copilot CLI is in place.'
    }
    $r = Invoke-DevConfigNativeCommand -FilePath 'copilot' -Arguments @('plugin', 'install', $Script:DevConfigWinUIPlugin)
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Output
        throw "copilot plugin install winui failed with exit code $($r.ExitCode)"
    }
}

function Get-DevConfigInstalledWinUIPlugin {
    if (-not (Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue)) {
        return
    }

    $result = Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'list', '--json')
    # Assignment avoids nesting the JSON array in Windows PowerShell 5.1.
    $plugins = $result.Output | ConvertFrom-Json
    foreach ($plugin in $plugins) {
        $id = "$($plugin.name)@$($plugin.marketplace)"
        if ($id -in @($Script:DevConfigWinUIPlugin, 'winui@awesome-copilot')) {
            $id
        }
    }
}

function Test-DevConfigWinUITemplatePackageInstalled {
    if (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue) {
        $sdks = Invoke-DevConfigCleanupCommand -FilePath 'dotnet' -Arguments @('--list-sdks')
        if (-not [string]::IsNullOrWhiteSpace($sdks.Output)) {
            $result = Invoke-DevConfigCleanupCommand -FilePath 'dotnet' -Arguments @('new', 'uninstall')
            return @($result.Output -split '\r?\n' | Where-Object { $_.Trim() -eq $Script:DevConfigWinUITemplatePackage }).Count -gt 0
        }
    }

    $cliHome = if ($env:DOTNET_CLI_HOME) { $env:DOTNET_CLI_HOME } else { $env:USERPROFILE }
    $packages = Join-Path $cliHome '.templateengine\packages'
    if ((Test-Path -LiteralPath $packages) -and
        @(Get-ChildItem -LiteralPath $packages -Filter "$Script:DevConfigWinUITemplatePackage.*.nupkg" -File).Count -gt 0) {
        throw 'The WinUI template package remains, but no .NET SDK is available. Repair the SDK and retry cleanup.'
    }
    return $false
}

function Test-DevConfigWinSkillsMarketplaceRegistered {
    if (-not (Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue)) {
        return $false
    }
    $result = Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'list', '--json')
    $marketplaces = $result.Output | ConvertFrom-Json
    return @($marketplaces | Where-Object { $_.name -eq $Script:DevConfigWinSkillsMarketplace }).Count -gt 0
}

function Invoke-CopilotPhase {
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $fragmentsDir = Get-DevConfigCopilotFragmentDir
        $fragmentPaths = @(
            (Join-Path $fragmentsDir 'github-copilot.fragment.json')
            (Join-Path $fragmentsDir 'copilot.png')
        )
        $steps = @(
            New-DevConfigStep -Name 'CopilotFragmentCleanup' -Description 'Remove the Copilot Terminal fragment and icon' -BestEffort `
                -Check { param($Paths) @($Paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 } `
                -Apply {
                    param($Paths)
                    foreach ($path in $Paths) {
                        if (Test-Path -LiteralPath $path) {
                            Remove-Item -LiteralPath $path -Force
                        }
                    }
                } `
                -ArgumentList @(, $fragmentPaths)
            New-DevConfigStep -Name 'WinUIPluginCleanup' -Description 'Uninstall the WinUI Copilot plugin' -BestEffort `
                -Check { @(Get-DevConfigInstalledWinUIPlugin).Count -eq 0 } `
                -Apply {
                    foreach ($plugin in @(Get-DevConfigInstalledWinUIPlugin)) {
                        Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'uninstall', $plugin) | Out-Null
                    }
                }
            New-DevConfigStep -Name 'WinSkillsMarketplaceCleanup' -Description 'Remove the win-dev-skills Copilot marketplace' -BestEffort `
                -Check { -not (Test-DevConfigWinSkillsMarketplaceRegistered) } `
                -Apply {
                    Invoke-DevConfigCleanupCommand -FilePath 'copilot' -Arguments @('plugin', 'marketplace', 'remove', $Script:DevConfigWinSkillsMarketplace) | Out-Null
                }
            New-DevConfigStep -Name 'WinUITemplatesCleanup' -Description 'Uninstall the WinUI dotnet-new template package' -BestEffort `
                -Check { -not (Test-DevConfigWinUITemplatePackageInstalled) } `
                -Apply {
                    Invoke-DevConfigCleanupCommand -FilePath 'dotnet' -Arguments @('new', 'uninstall', $Script:DevConfigWinUITemplatePackage) | Out-Null
                }
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    # BestEffort keeps network-dependent integrations from blocking the WSL and reboot phase.
    $steps = @(
        New-DevConfigStep -Name 'GitHubCopilotProfile' -Description 'Add a GitHub Copilot profile to Windows Terminal' `
            -Check { Test-DevConfigCopilotTerminalProfile } `
            -Apply { Set-DevConfigCopilotTerminalProfile } `
            -BestEffort
        New-DevConfigStep -Name 'WinUITemplates' -Description 'Install WinUI dotnet-new templates' `
            -Check { Test-DevConfigWinUITemplatesInstalled } `
            -Apply { Install-DevConfigWinUITemplates } `
            -BestEffort
        New-DevConfigStep -Name 'WinSkillsMarketplace' -Description 'Add win-dev-skills to the Copilot plugin marketplace' `
            -Check { Test-DevConfigWinSkillsMarketplaceAdded } `
            -Apply { Add-DevConfigWinSkillsMarketplace } `
            -BestEffort
        New-DevConfigStep -Name 'WinUIPlugin' -Description 'Install the WinUI Copilot plugin from win-dev-skills' `
            -Check { Test-DevConfigWinUIPluginInstalled } `
            -Apply { Install-DevConfigWinUIPlugin } `
            -BestEffort
    )
    if ($Script:DevConfigAction -eq 'Partial') {
        $steps = @($steps | Where-Object { $_.Name -ne 'WinUITemplates' })
    }

    Invoke-DevConfigSteps -Steps $steps
}
