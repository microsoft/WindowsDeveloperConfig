$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stepsRoot = Join-Path $PSScriptRoot '..\..\windows-dev-config\steps'
. (Join-Path $PSScriptRoot 'ai-support.ps1')
. (Join-Path $stepsRoot '_environment.ps1')
. (Join-Path $stepsRoot '_elevation.ps1')
. (Join-Path $stepsRoot '_retry.ps1')
. (Join-Path $stepsRoot '_step-runner.ps1')
. (Join-Path $stepsRoot '_winget.ps1')

Enable-AiUtf8Console

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
    Confirm-DevConfigWinGetReady -AllowCliFallback
    $action = Ensure-DevConfigWingetPackage -Id $Id -AllowCliFallback -DisableInteractivity
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
        $versionResult = Invoke-DevConfigNativeCommand -FilePath $existingNvcc -Arguments @('--version')
        if ($versionResult.ExitCode -ne 0) {
            throw "nvcc version check failed with exit code $($versionResult.ExitCode)."
        }
        return [pscustomobject]@{
            Action = 'already-current'
            ToolkitVersion = $plan.ToolkitVersion
            Source = 'direct'
            Nvcc = $existingNvcc
            VersionEvidence = $versionResult.Output.Trim()
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
    $versionResult = Invoke-DevConfigNativeCommand -FilePath $nvcc -Arguments @('--version')
    if ($versionResult.ExitCode -ne 0) {
        throw "Installed nvcc version check failed with exit code $($versionResult.ExitCode)."
    }
    return [pscustomobject]@{
        Action = 'installed'
        ToolkitVersion = $plan.ToolkitVersion
        Source = 'direct'
        Nvcc = $nvcc
        VersionEvidence = $versionResult.Output.Trim()
    }
}

# SIG # Begin signature block
# MIInOgYJKoZIhvcNAQcCoIInKzCCJycCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDxd3/aNG2yog6Z
# OJrejNq+6h0Bk5Pe8ou89/AEKWK4XqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEICPGlZjdyfYME131+nbW1Ma2E8Zg
# qT4mlR0YdRD8kHoyMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAqfstGwUGRza8x2C7MaTw4ITnVP7imPAAHEu3tfAYEUUHUGXwvsIVBarqabql
# OqcsPlsVxO96mud8hp6R3angBJOtPK+gcM/kgDEI76W90X8SSY44w0Hj/oAs2Axj
# 1oxTVmorL32zRIyPGnkN1+3fquif/XUZN6CJilMNjTpMAiQpUIAagK79ZzYLNed8
# sea6e7YWxF5EPpD42iQsaksNb+rh+8TFWkimO5zUA6bVXvCq9tq9HHua5ykODQ4s
# 3+ihIu3fv0B3v+WJXnbI6D5w/Dq0Bcf51nXnhXKtsV4CfYDvKY4u0DzZX6HVIkLO
# 2c7x36q+voY6ykbTwVDYNIhxvKGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38G
# CSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCBAxZ6jS2mgmYf19CPL3ztjUIss3E8ngUOpjgrNkWXMxgIGaqqnObV5GBMy
# MDI2MTAwOTAwMTc0MS40NjNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RTAwMi0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHt
# MIIHIDCCBQigAwIBAgITMwAAAikO1WQqtJfyGgABAAACKTANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDda
# Fw0yNzA1MTcxOTQwMDdaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RTAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCeItFq4z1oCYSmUZmpYDsbJWEu++1bbc/Mz7Pa3I0ZX5EO
# N+WirB0FvnGlyFRUylzO5TJXZfU8QFPOU95P1Y1OZ8J+quA5G+AWSBOr/48scl0s
# 9RBpqgTMq/lbyqBz4CMmvVR2QevAgVp4a1hbmOm9G7YWey68N5F5rSDYV0wMlg4I
# y8YRuFgRN2eBpVXt9IvFaFmBnQLZfo22KZ3L8PWEHUhXU5dLOSZoTfqqQ/B+deW5
# 6ACMnnHjPxZu+szHhZMLUrMWTgs9J7Cn8DtelcKj9aM+0Zq7tkSDHCrwo6eCSfw3
# clktXRRrdmsccal8RCDiNFFgZsypwF2aGAF6kg41+Ql+thXpnOMUH4mPCAJZWp0z
# DWowsK/Yo5jHL1pT/AgbL3FoAy4cbhOI4Pb1eQFG+jT7skS2F/b+ZACUA1EDZ830
# K+Bu0yw+FpSGy8tpd1szk3cUYjIpzIG4z3oFNmiSJN8YdNd4SHsER5Dks5bxiKbp
# vmfrOA39jTb7EW2TT7ySWgJISfvTezuLmQsTVSzNsvapVlHhE2zBqDw409nvOtit
# CFbnhhXNfatzb2+Gf2tX2s6YBa151CC/8+emJvvegXbWNudzYt8cFRom0PZ+fJRh
# hBfdSqCqr8QeOGJ8VYlmxFXqx1SdDSkTCSgpsskGqZwh/6umA1g4L7zeGBNngQID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFCdNRaSL9AW8QvaQ21WjRAXKN4M7MB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQA9wc72lf/czDhp09T3PGAMOQhxl/x04jpE7t39
# FeqQSn2Up6DVzhgwnzCqY3NIhLtUaWrd7NxvrhZDca+J4xzvrRQNPHeRQpnJVeHs
# yTu53gTBlUB1TRI6OnZt/AVmR9oMJ/NBOqB+d+SOb8Px6zRgRwk62sFkOkB5lig/
# DMnYEeR/amW9Hdo8vXcKmaa/DbSOAHSdfZFt+iqMZfNlkEOn71/RAKTNv4Qpq/2F
# hcjMMmSkIhshBdBVB0VjmkwFfhVUf5TTuLJ9sDR4EyCvOZJ3B6g7Iw6WjQxycjwk
# fzsVMTpfusJ5SwdOHL8yGPWZOePjwa8ISXWs6kiVK/6S0/JVb1LpxpyYKREQjnU/
# 5OecKt2OXlHdwFWZrwAi98RPZa6EExcb/LGLf10tNHju1eTlohY0jzNZQ0BDgSuM
# ZgMU+8EEjtMQMIDnlPGEUON7LHXHH0KL0FA01PEWVZKrr/LUOuuDTNFzw543FPMp
# 4gkCIFlKdRuciR1IXOk+Xse6rj9tJFYgVn+44BHou2XQe5RX30ef3AQWa0mxyGDq
# JzGsV3X5+bNQeMV88iWulJPq5sgnGG9O/H1/HH4HsO9ZKGX/WrJpQmFuQrTOR49X
# jveaC0xaFmGsNg+RhbtD5qTkn+ISDvw0IJ/E/VXNdz/yWgol6r507hT8sAMupnhk
# F2uw1DCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEw
# MB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk
# 4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9c
# T8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWG
# UNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6Gnsz
# rYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2
# LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLV
# wIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
# EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0
# gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFph
# AXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJ
# YfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXb
# GjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJ
# KwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnP
# EP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMw
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggr
# BgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
# xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
# BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0B
# AQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U5
# 18JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgAD
# sAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo
# 32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZ
# iefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZK
# PmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RI
# LLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
# ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9
# af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzba
# ukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIIC
# OAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkUwMDItMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQC3v9iS
# O22xob7ZxN5dXCEq+9Iv/6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nIjDzAiGA8yMDI2MTAwODE0MTEyN1oY
# DzIwMjYxMDA5MTQxMTI3WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuciMPAgEA
# MAoCAQACAjcqAgH/MAcCAQACAhM0MAoCBQDuc3SPAgEAMDYGCisGAQQBhFkKBAIx
# KDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZI
# hvcNAQELBQADggEBABkPckwtiXlCBu/Tbr4X2yW1IW1t2q/ieQ98HHmHb+9NptgP
# vnwmW5d+T1NQpmFADpNGZakgGbXaJD2wUIfJfSHvjK1EFrEGzSy+smVbwAIijJh5
# O2hRvxdU17gHezN6zMA0s3xhm5TZ05jXl5m1n2g05jwBPdZ0bh4Xl186JoWwFluB
# h0jM6iMnIz+3UNQsKTvK3PoccSOyaQjRb0SyfWbvdj54LQg8ZRDrttjitOOVYqQp
# zQbqfNsHU7sYTV/vYIec8aP6R2oQpqvCX4bTJJCOSZ/z5cvINSe9+VX/vTUFw6z0
# uto/+X++FRFgfJ47feNcYCnSAJau3HAEllDp5OwxggQNMIIECQIBATCBkzB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAikO1WQqtJfyGgABAAACKTAN
# BglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8G
# CSqGSIb3DQEJBDEiBCBnc3FohCOrm/cALbttmwDqvwWcDKxH/yx/YYEjhJ2jOjCB
# +gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EILfKPfEitvD/lSvEumxqPkkeOEtg
# kmKFEVMuel9oOrqSMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIpDtVkKrSX8hoAAQAAAikwIgQg3vSd0FAOuCm4uahWwcPWUg1+f5ET
# ydKzGqxxwJT5HvwwDQYJKoZIhvcNAQELBQAEggIAjo77bb8HewgZduXeeAIkuLi8
# kyhnSCcZZU0k+8hOqKYbonUBvVuH8lGMoKzk8WZk/AeCf647XfvWm/IlJUCdrdxT
# 2Q0Pd+vM+Bwqj8qlIWhkgwMysaeZs5/7qY6y2ugety4wMty2Niu2rknSkBV4Q9q+
# uhDaegmp2qSljVmmGMjDQo3RxkjzfS+Uue2R8oWgc+o97m9NCqVZPYiCrNCn9mY9
# o20Erb42OL3HeTcoKHoxG5aDNB7qvOud9URblHvHfoT9On8bBcPPk1N7yRdSds+r
# mPMqyTQ6NuM96NkwLujb54mi9bXkVAr1jliwsrUKHaXrjU+t6TOAGsRmO/9pPsOh
# PBBTNkDerWS9GJtDHUFMiywk3Tg1NM+P+c0OFnbyC8+oluyVVMAC8P7pDgSWMGuQ
# /6KWhiUDWIyPYt0sqYoTY5d6AJ4rz7chUf9cI0Jn57lIumFFlmpW9LG1jjpt4HI3
# n380piEnqmDC308Ac+wLSRcdmrfIgTlrWHpbEn594DhL5qGtmT2vUP7AoCksuPem
# i1EXxji3hSMxYFZ6pjHEG9cL041ddAIMPOs/6+ktqKfRUi8hzx+UEB+YV5RupmFp
# TLuhduzfH9SMQXVszYd4bTkiuCoWsMVca1q2A5yX+A1YxrJpiMcM452m8iXhK4HE
# /YvYDaKbcxDDmwq7dSk=
# SIG # End signature block
