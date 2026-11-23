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

# The Python install manager's execution alias exists before a refreshed PATH reaches this session.
function Get-DevConfigPyManagerPath {
    $path = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pymanager.exe'
    if (Test-Path -LiteralPath $path) {
        return $path
    }
    return $null
}

# Holds pip.exe and versioned commands such as python3.14.exe; pymanager install leaves it off PATH.
function Get-DevConfigPythonCommandsPath {
    return (Join-Path $env:LOCALAPPDATA 'Python\bin')
}

# pymanager can print notices around its JSON, so only the JSON line is parsed.
function Get-DevConfigPyManagerList {
    param(
        [Parameter(Mandatory)] [string] $PyManager,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    $result = Invoke-DevConfigNativeCommand -FilePath $PyManager -Arguments (@('list', '--format=json') + $Arguments) -TimeoutSeconds 300
    $json = @(([string]$result.Output -split '\r?\n') | Where-Object { $_.StartsWith('{"versions"') }) | Select-Object -Last 1
    if ($result.ExitCode -ne 0 -or -not $json) {
        throw "pymanager list $($Arguments -join ' ') failed ($($result.ExitCode)): $(([string]$result.Output).Trim())"
    }
    return @(($json | ConvertFrom-Json).versions)
}

# Like a winget package, the runtime counts as done only when it is the newest release in its line.
function Test-DevConfigPythonRuntime {
    param(
        [Parameter(Mandatory)] [string] $Version
    )
    $pymanager = Get-DevConfigPyManagerPath
    if (-not $pymanager) {
        return $false
    }
    $installed = @(Get-DevConfigPyManagerList -PyManager $pymanager -Arguments @('--only-managed', $Version))
    if ($installed.Count -eq 0) {
        return $false
    }
    $latest = @(Get-DevConfigPyManagerList -PyManager $pymanager -Arguments @('--online', '--one', $Version))
    if ($latest.Count -eq 0) {
        throw "The Python install manager found no Python $Version release online."
    }
    $current = @($installed | Where-Object { $_.id -eq $latest[0].id -and $_.'sort-version' -eq $latest[0].'sort-version' })
    return $current.Count -gt 0 -and (Test-DevConfigUserPathEntry -Directory (Get-DevConfigPythonCommandsPath))
}

function Install-DevConfigPythonRuntime {
    param(
        [Parameter(Mandatory)] [string] $Version
    )
    $pymanager = Get-DevConfigPyManagerPath
    if (-not $pymanager) {
        throw 'The pymanager command is missing because the Python install manager did not install. Re-run setup to retry.'
    }
    # --update installs the release when it is missing and replaces an older patch release.
    $result = Invoke-DevConfigNativeCommand -FilePath $pymanager -Arguments @('install', '--update', '--yes', $Version) -TimeoutSeconds 1800
    if ($result.ExitCode -ne 0) {
        throw "pymanager install $Version failed ($($result.ExitCode)): $(([string]$result.Output).Trim())"
    }
    Add-DevConfigUserPathEntry -Directory (Get-DevConfigPythonCommandsPath)
}

function Remove-DevConfigPython {
    param(
        [Parameter(Mandatory)] [string[]] $Ids
    )
    # Uninstalling the manager leaves its runtimes, so purge them while pymanager still exists.
    # Purge also removes the commands directory from the user PATH.
    $pymanager = Get-DevConfigPyManagerPath
    if ($pymanager) {
        Invoke-DevConfigCleanupCommand -FilePath $pymanager -Arguments @('uninstall', '--purge', '--yes') | Out-Null
    }
    Invoke-DevConfigPackageCleanup -Ids $Ids
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
            Id                     = 'Python.PythonInstallManager'
            # Installed with pymanager after the manager itself; see Install-DevConfigPythonRuntime.
            PythonVersion          = '3.14'
            UninstallOrder         = 5
            # Cleanup also removes the per-version installer and legacy py launcher that earlier setup versions used.
            AdditionalUninstallIds = @('Python.Python.3.14', 'Python.Launcher')
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
            Name           = 'Go'
            Id             = 'GoLang.Go'
            UninstallOrder = 17
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
            Name           = 'Rustup'
            Id             = 'Rustlang.Rustup'
            UninstallOrder = 19
        }
        @{
            Name           = 'Java'
            Id             = 'Microsoft.OpenJDK.25'
            UninstallOrder = 20
        }
        @{
            Name           = 'Sqlcmd'
            Id             = 'Microsoft.Sqlcmd'
            UninstallOrder = 21
        }
        @{
            Name           = 'SQLServerDeveloper'
            Id             = 'Microsoft.SQLServer.2025.Developer'
            Large          = $true
            # SQL Setup reports an unknown version to WinGet; don't reinstall and create another instance.
            AnyVersion     = $true
            UninstallOrder = 22
        }
        @{
            Name           = 'SSMS'
            Id             = 'Microsoft.SQLServerManagementStudio.22'
            Large          = $true
            # SSMS updates itself through the Visual Studio Installer, so a rerun must not start an upgrade that needs it closed.
            AnyVersion     = $true
            UninstallOrder = 23
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
        try {
            Confirm-DevConfigWinGetReady
        } catch {
            if (-not $Script:DevConfigWingetSourceFailure) { throw }
            Write-Host "  $Script:DevConfigWingetSourceFailure" -ForegroundColor Yellow
        }
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
                    'Python' {
                        New-DevConfigStep -Name 'PythonCleanup' -Description 'Remove Python runtimes and uninstall Python (user, machine, and MSIX)' -BestEffort `
                            -Check { param($Ids) Invoke-DevConfigPackageCleanup -Ids $Ids -CheckOnly } `
                            -Apply { param($Ids) Remove-DevConfigPython -Ids $Ids } `
                            -ArgumentList @(, @(@($package.Id) + $package.AdditionalUninstallIds))
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
            if ($package['PythonVersion']) {
                New-DevConfigStep -Name 'PythonRuntime' -Description "pymanager install $($package.PythonVersion)" -BestEffort `
                    -Check { param($Version) Test-DevConfigPythonRuntime -Version $Version } `
                    -Apply { param($Version) Install-DevConfigPythonRuntime -Version $Version } `
                    -ArgumentList @($package.PythonVersion)
            }
        }
        foreach ($setting in $settings) {
            New-DevConfigRegistryStep -Setting $setting
        }
    )

    Invoke-DevConfigSteps -Steps $steps
}
