<#
.SYNOPSIS
  Installs the Calm OS package set via winget.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-PackagesPhase {
    # See prerequisites.ps1: header first so any WinGet setup message lands under it, but not on the
    # resumed leg, where this phase collapses into the running "already OK" count.
    if (-not $Script:DevConfigResumed) {
        Show-DevConfigPhaseHeader
    }
    Initialize-DevConfigWinGet

    $packages = @(
        @{ Name = 'Terminal';      Id = 'Microsoft.WindowsTerminal' }
        @{ Name = 'PowerShell';    Id = 'Microsoft.PowerShell' }
        @{ Name = 'Git';           Id = 'Git.Git' }
        @{ Name = 'GitHubCLI';     Id = 'GitHub.cli' }
        @{ Name = 'GitHubCopilot'; Id = 'GitHub.Copilot' }
        @{ Name = 'VSCode';        Id = 'Microsoft.VisualStudioCode'; Large = $true }
        @{ Name = 'DotnetSdk';     Id = 'Microsoft.DotNet.SDK.10';    Large = $true }
        @{ Name = 'Python';        Id = 'Python.Python.3.14' }
        @{ Name = 'UV';            Id = 'astral-sh.uv' }
        @{ Name = 'NodeJS';        Id = 'OpenJS.NodeJS.LTS' }
        @{ Name = 'nvmForNode';    Id = 'CoreyButler.NVMforWindows' }
        @{ Name = 'Coreutils';     Id = 'Microsoft.Coreutils' }
        @{ Name = 'OhMyPosh';      Id = 'JanDeDobbeleer.OhMyPosh' }
        @{ Name = 'winappCli';     Id = 'Microsoft.WinAppCli' }
        @{ Name = 'PowerToys';     Id = 'Microsoft.PowerToys';        Large = $true }
    )

    # ArgumentList binds each package's Id at call time instead of relying on closure capture.
    # BestEffort: one package having a bad day upstream is no reason to abandon the other fourteen and
    # the phases behind them. Everything that depends on a package checks for it first, and the
    # summary names whatever was flagged. A WinGet that is broken outright is caught before this,
    # where it can be reported once rather than fifteen times.
    $steps = foreach ($pkg in $packages) {
        New-DevConfigStep -Name $pkg.Name -Description "winget install $($pkg.Id)" -BestEffort `
            -Check { param($Id, $Large) Test-DevConfigWingetPackageInstalled -Id $Id } `
            -Apply {
                param($Id, $Large)
                # WinGet gives no progress back while it downloads, and these three take long enough
                # that a bare "->" line reads as a hung console. Say so before the quiet starts.
                if ($Large) { Write-Host '  (Large download -- several quiet minutes here are normal.)' -ForegroundColor DarkGray }
                Install-DevConfigWingetPackage -Id $Id
                Wait-DevConfigWingetPackageSettled -Id $Id
            } `
            -ArgumentList @($pkg.Id, $pkg.ContainsKey('Large'))
    }

    $steps += New-DevConfigStep -Name 'PowerToysAOT' -Description 'Turn off PowerToys always-on-top notifications' `
        -Check { Test-DevConfigRegistryValue -KeyPath 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\PowerToys' -ValueName 'Enabled' -Value 0 } `
        -Apply { Set-DevConfigRegistryValue -KeyPath 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\PowerToys' -ValueName 'Enabled' -Value 0 }

    Invoke-DevConfigSteps -Steps $steps
}
