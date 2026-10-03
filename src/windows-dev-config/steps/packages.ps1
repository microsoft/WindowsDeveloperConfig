<#
.SYNOPSIS
  Installs or removes a workload's packages via winget, from one shared package catalog.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DevConfigUvCleanupPath {
    foreach ($name in @('uv', 'uvx', 'uvw')) {
        Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath $_.Source } |
            Select-Object -ExpandProperty Source
    }
    foreach ($root in @($env:LOCALAPPDATA, $env:APPDATA)) {
        $path = Join-Path $root 'uv'
        if (Test-Path -LiteralPath $path) {
            $path
        }
    }
}

function Remove-DevConfigUv {
    param(
        [Parameter(Mandatory)] [string] $Id
    )
    $uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue
    if ($uv) {
        Invoke-DevConfigCleanupCommand -FilePath 'uv' -Arguments @('cache', 'clean') | Out-Null
    }
    try {
        Invoke-DevConfigPackageCleanup -Ids @($Id)
    } finally {
        foreach ($path in @(Get-DevConfigUvCleanupPath | Select-Object -Unique)) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Remove-DevConfigNvm {
    $uninstallers = @(
        foreach ($scope in @('User', 'Machine')) {
            $nvmHome = [Environment]::GetEnvironmentVariable('NVM_HOME', $scope)
            if ($nvmHome) {
                $path = Join-Path ([Environment]::ExpandEnvironmentVariables($nvmHome)) 'unins000.exe'
                if (Test-Path -LiteralPath $path) { $path }
            }
        }
    ) | Select-Object -Unique
    if (-not $uninstallers) {
        throw 'The NVM uninstaller was not found under NVM_HOME. Repair its installation and retry.'
    }
    foreach ($path in $uninstallers) {
        Invoke-DevConfigCleanupCommand -FilePath $path `
            -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') | Out-Null
    }
}

# Every package any workload installs; a workload lists the names it wants, in its own install order.
# KeepOnUninstall, AdditionalUninstallIds, UninstallOrder, and InnoUninstall shape cleanup. Settings are
# registry values that go with the package: applied after installs and reset first during cleanup.
function Get-DevConfigPackageCatalog {
    # PowerShell's process architecture can differ from Windows' native architecture.
    $architecture = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE'
    $vcRedistId = switch ($architecture) {
        'AMD64' { 'Microsoft.VCRedist.2015+.x64' }
        'ARM64' { 'Microsoft.VCRedist.2015+.arm64' }
        default { throw "Unsupported Windows architecture: $architecture" }
    }

    @(
        @{
            Name            = 'Terminal'
            Id              = 'Microsoft.WindowsTerminal'
            KeepOnUninstall = $true
        }
        @{
            Name           = 'IntelligentTerminal'
            Id             = 'Microsoft.IntelligentTerminal'
            UninstallOrder = 12
        }
        @{
            Name           = 'PowerShell'
            Id             = 'Microsoft.PowerShell'
            UninstallOrder = 16
        }
        @{
            Name           = 'Git'
            Id             = 'Git.Git'
            UninstallOrder = 6
            InnoUninstall  = @{ DisplayName = 'Git'; Publisher = 'The Git Development Community' }
        }
        @{
            Name           = 'GitHubCLI'
            Id             = 'GitHub.cli'
            UninstallOrder = 7
        }
        @{
            Name           = 'AzureCLI'
            Id             = 'Microsoft.AzureCLI'
            UninstallOrder = 9
        }
        @{
            Name                   = 'GitHubCopilot'
            Id                     = 'GitHub.Copilot'
            UninstallOrder         = 4
            AdditionalUninstallIds = @('XPDC8MMRVCF73P', 'GitHub Copilot CLI')
        }
        @{
            Name           = 'VSCode'
            Id             = 'Microsoft.VisualStudioCode'
            Large          = $true
            UninstallOrder = 14
            InnoUninstall  = @{ DisplayName = 'Microsoft Visual Studio Code'; Publisher = 'Microsoft Corporation' }
        }
        @{
            Name           = 'DotnetSdk'
            Id             = 'Microsoft.DotNet.SDK.10'
            Large          = $true
            UninstallOrder = 11
        }
        @{
            Name                   = 'Python'
            Id                     = 'Python.Python.3.14'
            UninstallOrder         = 5
            AdditionalUninstallIds = @('Python.Launcher', 'Python.PythonInstallManager')
        }
        @{
            Name            = 'VCRedist'
            Id              = $vcRedistId
            KeepOnUninstall = $true
        }
        @{
            Name           = 'UV'
            Id             = 'astral-sh.uv'
            UninstallOrder = 1
        }
        @{
            Name                   = 'NodeJS'
            Id                     = 'OpenJS.NodeJS.LTS'
            UninstallOrder         = 3
            AdditionalUninstallIds = @('OpenJS.NodeJS')
        }
        @{
            Name           = 'nvmForNode'
            Id             = 'CoreyButler.NVMforWindows'
            UninstallOrder = 2
        }
        @{
            Name           = 'Coreutils'
            Id             = 'Microsoft.Coreutils'
            UninstallOrder = 10
        }
        @{
            Name           = 'OhMyPosh'
            Id             = 'JanDeDobbeleer.OhMyPosh'
            UninstallOrder = 8
        }
        @{
            Name           = 'winappCli'
            Id             = 'Microsoft.WinAppCli'
            UninstallOrder = 15
        }
        @{
            Name           = 'PowerToys'
            Id             = 'Microsoft.PowerToys'
            Large          = $true
            UninstallOrder = 13
            Settings       = @(
                @{
                    Name        = 'PowerToysAOT'
                    KeyPath     = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.PowerToysWin32'
                    ValueName   = 'Enabled'
                    Value       = 0
                    Description = 'Turn off PowerToys always-on-top notifications'
                }
            )
        }
        # Visual Studio Community 2026 (18.x). steps\visual-studio.ps1 adds workloads to this instance.
        @{
            Name       = 'VisualStudioCommunity'
            Id         = 'Microsoft.VisualStudio.Community'
            Large      = $true
            # Visual Studio updates itself, so a rerun must not start a multi-GB upgrade that needs it closed.
            AnyVersion = $true
        }
    )
}

# Returns catalog entries in the requested order so each workload controls its own install order.
function Get-DevConfigPackage {
    param(
        [Parameter(Mandatory)] [string[]] $Name
    )
    $duplicates = @($Name | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($duplicates.Count -gt 0) {
        throw "Packages listed more than once: $($duplicates -join ', ')."
    }
    $catalog = @(Get-DevConfigPackageCatalog)
    $selected = foreach ($packageName in $Name) {
        $match = @($catalog | Where-Object { $_.Name -eq $packageName })
        if ($match.Count -ne 1) {
            throw "Package '$packageName' is not in the package catalog in steps\packages.ps1."
        }
        $match[0]
    }
    return $selected
}

function Invoke-PackagesPhase {
    param(
        [Parameter(Mandatory)] [string[]] $Packages
    )
    if ($Script:DevConfigAction -ne 'Uninstall') {
        # Show the header before WinGet setup; skip it when a resumed run summarizes this phase.
        if (-not $Script:DevConfigResumed) {
            Show-DevConfigPhaseHeader
        }
        Initialize-DevConfigWinGet
        Confirm-DevConfigWinGetReady
    }

    $selected = @(Get-DevConfigPackage -Name $Packages)
    $settings = @(foreach ($package in $selected) { if ($package['Settings']) { $package['Settings'] } })

    if ($Script:DevConfigAction -eq 'Uninstall') {
        $cleanupPackages = $selected | Where-Object { -not $_['KeepOnUninstall'] } |
            Sort-Object { [int]$_['UninstallOrder'] }
        $steps = @(
            foreach ($setting in $settings) {
                New-DevConfigRegistryStep -Setting $setting -Reset
            }
            foreach ($package in $cleanupPackages) {
                switch ($package.Name) {
                    'UV' {
                        New-DevConfigStep -Name 'UvCleanup' -Description 'Remove uv executables, caches, and local data' -BestEffort `
                            -Check {
                                param($Id)
                                @(Get-DevConfigUvCleanupPath).Count -eq 0 -and
                                    (Invoke-DevConfigPackageCleanup -Ids @($Id) -CheckOnly)
                            } `
                            -Apply { param($Id) Remove-DevConfigUv -Id $Id } `
                            -ArgumentList @($package.Id)
                    }
                    'nvmForNode' {
                        New-DevConfigStep -Name 'NvmCleanup' -Description 'Uninstall NVM for Windows' -BestEffort `
                            -Check { param($Id) Invoke-DevConfigPackageCleanup -Ids @($Id) -CheckOnly } `
                            -Apply { param($Id) Remove-DevConfigNvm } `
                            -ArgumentList @($package.Id)
                    }
                    default {
                        $ids = @($package.Id)
                        if ($package['AdditionalUninstallIds']) {
                            $ids += $package.AdditionalUninstallIds
                        }
                        New-DevConfigStep -Name "$($package.Name)Cleanup" -Description "Uninstall $($package.Name) (user, machine, and MSIX)" -BestEffort `
                            -Check { param($Ids, $InnoUninstall) Invoke-DevConfigPackageCleanup -Ids $Ids -InnoUninstall $InnoUninstall -CheckOnly } `
                            -Apply { param($Ids, $InnoUninstall) Invoke-DevConfigPackageCleanup -Ids $Ids -InnoUninstall $InnoUninstall } `
                            -ArgumentList @($ids, $package['InnoUninstall'])
                    }
                }
            }
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    # ArgumentList binds each package's Id at call time instead of relying on closure capture.
    # BestEffort lets independent packages continue; dependent phases verify packages before use.
    $steps = @(
        foreach ($package in $selected) {
            New-DevConfigStep -Name $package.Name -Description "winget install $($package.Id)" -BestEffort `
                -Check { param($Id, $Large, $AnyVersion) Test-DevConfigWingetPackageInstalled -Id $Id -AnyVersion:$AnyVersion } `
                -Apply {
                    param($Id, $Large, $AnyVersion)
                    # Large packages can have several quiet download minutes because WinGet reports no progress here.
                    if ($Large) { Write-Host '  (Large download -- several quiet minutes here are normal.)' -ForegroundColor DarkGray }
                    Install-DevConfigWingetPackage -Id $Id
                    Wait-DevConfigWingetPackageSettled -Id $Id -AnyVersion:$AnyVersion
                } `
                -ArgumentList @($package.Id, $package.ContainsKey('Large'), [bool]$package['AnyVersion'])
        }
        foreach ($setting in $settings) {
            New-DevConfigRegistryStep -Setting $setting
        }
    )

    Invoke-DevConfigSteps -Steps $steps
}
