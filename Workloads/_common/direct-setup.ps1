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
# MIInQQYJKoZIhvcNAQcCoIInMjCCJy4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDxd3/aNG2yog6Z
# OJrejNq+6h0Bk5Pe8ou89/AEKWK4XqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEICPGlZjdyfYME131+nbW1Ma2E8ZgqT4mlR0YdRD8kHoyMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAslW2bYPSiuZoinls
# 1NlP4Jq241yEMJQjyoeWL9w8/ThFKP/Byyvtx0LOkeFAeCO4S5ngZG/Jyuwquy+O
# DtYaf+Z8qtZln2a1NqCEZw7Zga8X0L1fbYO2BSBCU839lZWrmVm+zgNy820aq9B2
# 7c04zX8fTAtDMXXoQOMUqX1pTVkyisfgw4UtweTWKLQLEdv0WiPY7NEpsZpfuzdI
# 3+0BVR5lwYwMNWaYRslY6pwHfQ9yvPZ5G6ipJioi3lEK0BaZi4v9PlnmpY1X9t9G
# LPfkS6sS4YRCP95QcnWx9drPlSb992QYd6sfxwat0FbuN3HkVIXhJF6t2yFavz2b
# 10/2+KGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4Yw
# gheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCApJBYw8JRS1sQV
# vw94G7l1Vk4+rQkrRyQny+p3aTc9vgIGargHQpmSGBMyMDI2MTAwOTIxNDQ1Mi4y
# MjdaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIF
# EKADAgECAhMzAAACF3H7LqWvAR3qAAEAAAIXMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyM1oXDTI2MTEx
# MzE4NDgyM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjUyMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAwM82sEw+39vYR7iGCIFDnYNhRM+BzF2AYiq5dUpZpJFP
# RjCcipQ6RUbI+RAYNRApExx5ygrXbaWtuwvqsqAVSWbU/W6fecujjILkPqn9pngt
# WRkfQgbYgvaXALl6PY2yOH9f72MD+6AyxQenSpAMdUzY/Qk/jtjsHdFXVBe+tshl
# IkSJ3GZw8VVKqTg3GZElztwbJWNtrhBEvhf6anxMegQMJP7tO8/BJ7ITs4/AV3D2
# bv8eHk81Y+fOmQ8mQ61WLq2wItvlzIT5bzelK9LvEycf5x1lXxAwEw5a7dpS+CKT
# anhtv+Q2mwebAybjf9io4k48stTaq1rtcrOiDwddqVm1S9e8h1TszXFzjLLvE9Em
# jnNfIewsY+RChUaHnY4FFwwJEnEv/JS76oHT0oGdy7+J60fGOl7A1UoUyAkhpb2B
# ja+SwSIiHbQ4FDyJiLlZ6drZZ84MoJ852JSxM0hBjGO6FZlPO8iuNyk680Di8Vnb
# SNpIdJN+DhlepeTUMBDHqCmd0mVWRWZPm1pvgty93asNt/Ng6o4m2dnooWOdM3yK
# sJaWjyHqic9gfTrZBM+PCXqeTaO1oEiaQ+h4w0nHVdV+XSvI2m1yN4iibqjm5HPa
# AO3OJ+OmNLftNVmr4Z6U2T6pIcLBysoKcDUvCqycXj4C/+n1KFBpDGdDMw9gmu8C
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBRQrN9jlwNOoeE5ZQqnF5x8S1bJQzAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEARmgFdhB7xIAIHEEg5I/5S+gx67aR6RiW8ZAw
# tE3mz8o0dyn+pIP+lidNR1IKQQ0r+RjYgI9cZ6mbvAyvh3e2q/BV8rjHE3ud9PyY
# yq32euFgdZ3vX4b5QXePWlpBAYrdziR27rHz6WwpH5dZsSypbXDBbQkWkNl6g82y
# Ty3AbBbKDXBdzxZsEauaOplatK7Er4dhglKBex8JQ2dMSkSZweCNDXqd9r/9W2Vd
# RZsDJKP/Xc4UyQlVsboBotKtYESXFkjwR1HVsH+Q0C69/N5CP/Tq3YgI1ub4b9+3
# MJFKWhJXCcJGFZkcLwUmYwoFg1XLo7DLJdGjrIH1jsI2NFXJFQHef6AdRe1ERvYQ
# eqtyrBvxIvR+P/83FNYyzx04inUT9TF2AwTOuqCC6Z67oNwR4pEEJyAIEREvkdhj
# jfWcgsk/nGTlfahvNY/SOHrNRKo49KDlccNzRCJQyQ+D59r7/qebNSyQPTfwI9++
# jEY0Q/UWKVNLhio55GYBseJ99s7NzkdxOr9Uftp597HEovbA69qGlZ3OpUE3H1RB
# GDVp/FvM2uXTum8LrMkPXx5Ap/kbPASsC9ju9oMCe2IEXO2SeD1aD3IqvAOdHFKH
# g1vpbPUQSWb6g2xfBV30wFcqaPYgzcbxPWPyZqK+S8l7zw64aO5hmJ7eQwoMfTu0
# Vay6r48wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCC
# Aj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1MjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAabKAFaKt2haUdqkHfFYzAzfgSMuggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO5zp8kwIhgPMjAyNjEw
# MDkxNzUwMDFaGA8yMDI2MTAxMDE3NTAwMVowdDA6BgorBgEEAYRZCgQBMSwwKjAK
# AgUA7nOnyQIBADAHAgEAAgIF5TAHAgEAAgIT5DAKAgUA7nT5SQIBADA2BgorBgEE
# AYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYag
# MA0GCSqGSIb3DQEBCwUAA4IBAQA7pw9ZttIR7wWJYYMxAR6AnGVVVhEstNkQd9Th
# 6MftmGzYl41cwp2kV9UdikJSBb+uB20MFyvobtobAwpGuw6yIjorZpnR+wTXvzFR
# G+4U3NAiAxdIoY7RjDYJ0XIJAzOxYE8cBbaeMn1Yq3JKiJkWT8lJl/qkTtx/ytir
# sC9gf56NybUIoeiPQnPgPvnZNVY3zxA1YpOfXuvzcBZ0ogGTWzo818tZfnTLmPOp
# o1HeiKbV7vSWOKCf3ycpcIx0ym6nTYc4i/KiqcmfnME7kfUeGZoy6jQQUpCBWhv4
# 2ql7P86d4vGP7nh6ImdK0Ya4POsJcEGq0mpcD4Q1YV0FwA56MYIEDTCCBAkCAQEw
# gZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIXcfsupa8BHeoA
# AQAAAhcwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0B
# CRABBDAvBgkqhkiG9w0BCQQxIgQg4LLx8HGaZsbEXI0jhYj75xeuxAUGU6OmipaV
# FhONdCkwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCDQ8lBgPl23yZ0SzUSt
# 5phOIegHPywrkNwevxe2k+RaWzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACF3H7LqWvAR3qAAEAAAIXMCIEIGimmxmuSXKXzzoqo7DD
# SU7Cbko0MVNcKniiA4PT/LvMMA0GCSqGSIb3DQEBCwUABIICAGBuGUm+aIp61tV7
# 4X5sn4C+MkcGsIJSMON4WMoxif91lhNJgyWlKEKf9RKqqxmeE2JrFO3sDeVzADH6
# HsTK/HG7n6VxR8rYIumyifwmDRNah5jVln/MQVpqkrPTbIUnhOehojWmItLC0LC5
# /b5YTHnsB9tJ45Hrbvv72MXRaK4lg7T69s/qdYLY/o4C7KPXO4KG2n+0bmg38P2h
# SQJNpoYgcSLBfK3m3EH1VmSA7MI2LeQPIDIo8JcHAMAOfCw5YrS96Xg9BBuv77gN
# 0YyPuPiBPO8euBvD9wvfpJ07eInv2qgUbqleeY6rSZ3AId0m8OkpWYz8an7qmaIb
# hmRg2G8ktRPU1qkD7DvkNxfAj6nLWF/D81ZINO62HH5xj5rpkSvSLqRI2J50sd5N
# IuuxP9CiisOtn1yCuWQt6+DPnZYFH7IsvKjYM5zPLQuUaWD5m1qc8gx2auBoFBaT
# Oocd9R+DUVHQpGGpWZwgiXVoh8GRa0MG+OjxJjAUAhe2Vz3SUrstlkftbTXJhqOe
# 5BbQTSDOTESScl5qRxSw/he7qpJb9RNmPT4exLK5hhqQG79hF4P2plrEisjjO1Yy
# +zAM0Lu6xXxbryFMHJ+2IJ0YPYFf46l0GhfWnDhrvrOZf0pcakd+e/bFYj0zx3lP
# 6GbVOlhWuSEtWhjHvwULU+Pb9Bca
# SIG # End signature block
