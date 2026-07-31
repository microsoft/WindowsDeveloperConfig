<#
.SYNOPSIS
  Installs the Calm OS package set via winget.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigWingetPackageInstalled {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    $listOutput = & winget list --id $Id --exact --source winget --accept-source-agreements 2>&1 | Out-String
    if ($listOutput -match 'No installed package found') {
        return $false
    }

    # useLatest: true in the original -- an available upgrade means this step isn't satisfied yet.
    $upgradeOutput = & winget list --id $Id --exact --upgrade-available --source winget --accept-source-agreements 2>&1 | Out-String
    return $upgradeOutput -match 'No installed package found'
}

function Install-DevConfigWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    Invoke-DevConfigRetry -Name "winget install $Id" -ScriptBlock {
        & winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "winget install $Id failed with exit code $LASTEXITCODE"
        }
    }
}

function Invoke-PackagesPhase {
    $packages = @(
        @{ Name = 'Terminal';      Id = 'Microsoft.WindowsTerminal' }
        @{ Name = 'PowerShell';    Id = 'Microsoft.PowerShell' }
        @{ Name = 'Git';           Id = 'Git.Git' }
        @{ Name = 'GitHubCLI';     Id = 'GitHub.cli' }
        @{ Name = 'GitHubCopilot'; Id = 'GitHub.Copilot' }
        @{ Name = 'VSCode';        Id = 'Microsoft.VisualStudioCode' }
        @{ Name = 'DotnetSdk';     Id = 'Microsoft.DotNet.SDK.10' }
        @{ Name = 'Python';        Id = 'Python.Python.3.14' }
        @{ Name = 'UV';            Id = 'astral-sh.uv' }
        @{ Name = 'NodeJS';        Id = 'OpenJS.NodeJS.LTS' }
        @{ Name = 'nvmForNode';    Id = 'CoreyButler.NVMforWindows' }
        @{ Name = 'Coreutils';     Id = 'Microsoft.Coreutils' }
        @{ Name = 'OhMyPosh';      Id = 'JanDeDobbeleer.OhMyPosh' }
        @{ Name = 'winappCli';     Id = 'Microsoft.WinAppCli' }
        @{ Name = 'PowerToys';     Id = 'Microsoft.PowerToys' }
    )

    # ArgumentList binds each package's Id at call time instead of relying on closure capture.
    $steps = foreach ($pkg in $packages) {
        New-DevConfigStep -Name $pkg.Name -Description "winget install $($pkg.Id)" `
            -Check { param($Id) Test-DevConfigWingetPackageInstalled -Id $Id } `
            -Apply { param($Id) Install-DevConfigWingetPackage -Id $Id } `
            -ArgumentList @($pkg.Id)
    }

    $steps += New-DevConfigStep -Name 'PowerToysAOT' -Description 'Turn off PowerToys always-on-top notifications' `
        -Check { Test-DevConfigRegistryValue -KeyPath 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\PowerToys' -ValueName 'Enabled' -Value 0 } `
        -Apply { Set-DevConfigRegistryValue -KeyPath 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\PowerToys' -ValueName 'Enabled' -Value 0 }

    Invoke-DevConfigSteps -Steps $steps
}
