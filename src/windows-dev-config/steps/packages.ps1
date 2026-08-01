<#
.SYNOPSIS
  Installs the Calm OS package set via winget.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Required: every check/install below is a Microsoft.WinGet.Client cmdlet, so the module has to load.
function Install-DevConfigWinGetModule {
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Write-Host '  Setting up the WinGet PowerShell module...' -ForegroundColor DarkCyan
        Write-Host '  (First time only. This can take a few minutes.)' -ForegroundColor DarkGray
        # A fresh machine can prompt to install the NuGet provider on first use; bootstrap it non-interactively first.
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
        }
        Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
    }
    Import-Module -Name Microsoft.WinGet.Client -ErrorAction Stop
}

# Best-effort: fixes the odd App Execution Alias glitches winget occasionally hits, before any real installs start.
# Get-WinGetVersion is a quick health check -- only pay for the slower repair when it says WinGet isn't responding.
function Repair-DevConfigWinget {
    try {
        $version = Get-WinGetVersion -ErrorAction Stop
        Write-Host "  WinGet $version looks healthy -- skipping repair." -ForegroundColor DarkGray
        return
    } catch {
        Write-Host '  WinGet is not responding as expected -- repairing...' -ForegroundColor DarkCyan
        Write-Host '  (This can take a few minutes.)' -ForegroundColor DarkGray
    }

    try {
        Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop | Out-Null
        Write-Host '  WinGet repair finished.' -ForegroundColor DarkGray
    } catch {
        Write-Warning "WinGet repair skipped: $($_.Exception.Message) (continuing anyway)"
    }
}

function Test-DevConfigWingetPackageInstalled {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    # EqualsCaseInsensitive avoids ambiguous substring matches (e.g. an MSIX-correlated entry sharing the same Id text).
    $pkg = Get-WinGetPackage -Id $Id -Source winget -MatchOption EqualsCaseInsensitive
    if (-not $pkg) {
        return $false
    }

    # useLatest: true in the original -- an available upgrade means this step isn't satisfied yet.
    return -not $pkg.IsUpdateAvailable
}

function Install-DevConfigWingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    Invoke-DevConfigRetry -Name "winget install $Id" -ScriptBlock {
        $result = Install-WinGetPackage -Id $Id -Source winget -Mode Silent -MatchOption EqualsCaseInsensitive
        # NoApplicableUpgrade: already installed and up to date, not a failure (module's equivalent of the
        # CLI's APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE exit code).
        if (-not $result.Succeeded() -and $result.Status -ne 'NoApplicableUpgrade') {
            throw "winget install $Id failed: $($result.ErrorMessage())"
        }
    }
}

function Invoke-PackagesPhase {
    Show-DevConfigPhaseHeader
    Install-DevConfigWinGetModule
    Repair-DevConfigWinget

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
