$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stepsRoot = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
. (Join-Path $PSScriptRoot 'ai-support.ps1')
. (Join-Path $stepsRoot '_environment.ps1')
. (Join-Path $stepsRoot '_elevation.ps1')
. (Join-Path $stepsRoot '_retry.ps1')
. (Join-Path $stepsRoot '_step-runner.ps1')
. (Join-Path $stepsRoot '_winget.ps1')

function Write-AiPhase {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Detail = ''
    )
    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    if ($Detail) {
        Write-Host $Detail -ForegroundColor DarkGray
    }
}

function Assert-AiAdministrator {
    if (-not (Test-DevConfigIsAdmin)) {
        throw 'This setup needs Administrator rights. Re-run it from an elevated PowerShell window, or launch it from Command Palette and accept the UAC prompt.'
    }
}

function Ensure-AiWingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [switch] $PlanOnly
    )

    if ($PlanOnly) {
        return [pscustomobject]@{ Id = $Id; Action = 'install-or-upgrade'; Source = 'winget' }
    }

    Initialize-DevConfigWinGet
    $action = Ensure-DevConfigWingetPackage -Id $Id
    Update-DevConfigSessionPath
    $evidence = Get-AiWingetPackageEvidence -Id $Id
    return [pscustomobject]@{ Id = $Id; Action = $action; Source = 'winget'; Evidence = $evidence }
}

function Get-AiWingetPackageAction {
    param([Parameter(Mandatory)] [ValidateSet('Absent', 'UpgradeAvailable', 'Current')] [string] $State)
    switch ($State) {
        'Absent' { return 'install' }
        'UpgradeAvailable' { return 'upgrade' }
        'Current' { return 'skip' }
    }
}

function Get-AiWingetPackageEvidence {
    param([Parameter(Mandatory)] [string] $Id)

    try {
        if ($Script:DevConfigWinGetMode -eq 'Cli') {
            return (Invoke-DevConfigWingetCli -Arguments @(
                'list', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements'
            )).Output
        }
        $package = Get-WinGetPackage -Id $Id -Source winget -MatchOption EqualsCaseInsensitive
        if (-not $package) { return $null }
        return ConvertTo-AiWingetPackageEvidence -Package $package -RequestedId $Id
    } catch {
        Write-Warning "Could not collect WinGet evidence for '$Id': $($_.Exception.Message)"
        return [ordered]@{ id = $Id; source = 'winget'; evidenceUnavailable = $true }
    }
}

function Get-AiObjectPropertyValue {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string[]] $Names
    )
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($property) { return $property.Value }
    }
    return $null
}

function ConvertTo-AiWingetPackageEvidence {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)] [string] $RequestedId
    )
    $resolvedId = Get-AiObjectPropertyValue -InputObject $Package -Names @('Id', 'PackageIdentifier', 'PackageId')
    if (-not $resolvedId) { $resolvedId = $RequestedId }
    return [ordered]@{
        id = [string]$resolvedId
        name = [string](Get-AiObjectPropertyValue -InputObject $Package -Names @('Name', 'PackageName'))
        installedVersion = [string](Get-AiObjectPropertyValue -InputObject $Package -Names @('InstalledVersion', 'Version'))
        availableVersion = [string](Get-AiObjectPropertyValue -InputObject $Package -Names @('AvailableVersion', 'LatestVersion'))
        updateAvailable = [bool](Get-AiObjectPropertyValue -InputObject $Package -Names @('IsUpdateAvailable', 'UpdateAvailable'))
        source = 'winget'
    }
}

function Ensure-AiVisualCppTools {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [switch] $PlanOnly
    )

    $package = Ensure-AiWingetPackage -Id 'Microsoft.VisualStudio.2022.BuildTools' -PlanOnly:$PlanOnly
    if ($PlanOnly) {
        return [pscustomobject]@{
            Package = $package
            Action = 'ensure-vctools-workload'
            Architecture = $Architecture
        }
    }

    try {
        $compiler = Get-MsvcCompilerPath -Architecture $Architecture
        return [pscustomobject]@{ Package = $package; Action = 'already-current'; Compiler = $compiler }
    } catch {
        Write-Host "  Adding the $Architecture C++ Build Tools workload..." -ForegroundColor DarkCyan
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installPath = [string](& $vswhere -latest -products Microsoft.VisualStudio.Product.BuildTools -property installationPath |
        Select-Object -First 1)
    $installPath = $installPath.Trim()
    if (-not $installPath) {
        throw 'Visual Studio Build Tools installation path could not be determined.'
    }

    $stagingRoot = Join-Path $env:ProgramFiles 'WindowsDeveloperConfig\Installers'
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    $bootstrapper = Join-Path $stagingRoot "vs_BuildTools-$([guid]::NewGuid().ToString('N')).exe"
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $bootstrapper -UseBasicParsing
    $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
    $signerName = $signature.SignerCertificate.GetNameInfo(
        [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($signature.Status -ne 'Valid' -or $signerName -ne 'Microsoft Corporation') {
        throw "Visual Studio bootstrapper signature validation failed: $($signature.Status), $signerName"
    }
    $arguments = @(
        'modify', '--installPath', "`"$installPath`"",
        '--channelId', 'VisualStudio.17.Release',
        '--productId', 'Microsoft.VisualStudio.Product.BuildTools',
        '--add', 'Microsoft.VisualStudio.Workload.VCTools'
    )
    if ($Architecture -eq 'Arm64') {
        $arguments += @('--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64')
    }
    $arguments += @('--includeRecommended', '--quiet', '--wait', '--norestart', '--nocache')
    try {
        $exitCode = Invoke-DevConfigProcess -FilePath $bootstrapper -Arguments $arguments -TimeoutSeconds 5400
        if ($exitCode -notin @(0, 3010)) {
            throw "Visual Studio Build Tools bootstrapper exited with code $exitCode. Review $env:TEMP\dd_*.log."
        }
    } finally {
        [void](Remove-TemporaryFileWithRetry -Path $bootstrapper)
    }

    $compiler = Get-MsvcCompilerPath -Architecture $Architecture
    return [pscustomobject]@{ Package = $package; Action = 'workload-added'; Compiler = $compiler }
}

function Ensure-AiCudaToolkit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('X64', 'Arm64')] [string] $Architecture,
        [switch] $PlanOnly
    )

    $plan = Resolve-CudaInstallPlan -Architecture $Architecture -WindowsBuild (Get-WindowsBuildNumber)
    if ($Architecture -eq 'X64') {
        $package = Ensure-AiWingetPackage -Id 'Nvidia.CUDA' -PlanOnly:$PlanOnly
        $nvcc = if ($PlanOnly) { $null } else { Get-CudaNvccPath -ToolkitVersion $null }
        $versionOutput = if ($nvcc) { (& $nvcc --version 2>&1 | Out-String).Trim() } else { $null }
        return [pscustomobject]@{
            Action = $package.Action
            ToolkitVersion = $null
            Source = 'winget'
            Nvcc = $nvcc
            VersionEvidence = $versionOutput
            PackageEvidence = $(if ($PlanOnly) { $null } else { $package.Evidence })
        }
    }
    if ($PlanOnly) {
        return [pscustomobject]@{
            Action = 'install-or-verify-preview'
            ToolkitVersion = $plan.ToolkitVersion
            Source = 'direct'
            Uri = $plan.InstallerUrl
            Sha256 = $plan.InstallerSha256
        }
    }

    try {
        $existingNvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
        return [pscustomobject]@{
            Action = 'already-current'
            ToolkitVersion = $plan.ToolkitVersion
            Source = 'direct'
            Nvcc = $existingNvcc
        }
    } catch {
        Write-Host '  Installing NVIDIA CUDA Toolkit 13.4 Developer Preview for Windows ARM64...' -ForegroundColor DarkCyan
    }

    $cacheRoot = Join-Path $env:ProgramData 'WindowsDeveloperConfig\cache\nvidia-cuda\13.4.0'
    $installer = Join-Path $cacheRoot 'cuda_13.4.0_windows_arm64.exe'
    Install-VerifiedDownload -Uri $plan.InstallerUrl -Destination $installer -Sha256 $plan.InstallerSha256
    Invoke-VerifiedLocalInstaller `
        -Path $installer `
        -Sha256 $plan.InstallerSha256 `
        -SignerPattern 'NVIDIA' `
        -ArgumentList @('-s') `
        -SuccessExitCodes @(0, 3010)
    $nvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
    return [pscustomobject]@{
        Action = 'installed'
        ToolkitVersion = $plan.ToolkitVersion
        Source = 'direct'
        Nvcc = $nvcc
    }
}
