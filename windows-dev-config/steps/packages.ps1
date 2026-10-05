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

# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDEi5r1dqR6UhFe
# hBqcAgH9RnyqSZKoRNNBMGuWBJlE7aCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEINJEOls8gHTYteKL0lKXt3+ymB7BrB2a7J9nd9mvBT3bMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAjiDq32qEGwwkNxiM
# iJq6gPXD9SuGjPaHpxNIMt0VgRYZ2Urv2iFzhOFLtT5twwIR8J1MJaViUYi14Ftk
# U3JLCgbI2GYOOwRYRwZ67v0u43ECgXpKckB7MCEKg20omJ34b2KtdpWY+cnoF7Rn
# iLYhcYs1mP2cEvCZSWA/5aapXXgg9c8F7nbhMaoQ5+toOf0vWMl7y6w5gB/fPiiG
# dZDRFeb3NWkCq0xnF+SCCDvruDsY1TbSOcmyd4PU9loPX5xU5ZshBfww0hodCQT2
# flvqAYojWA6m/oud1U6swI5KGeclzXLgyskiQZzLyHelZBr1rANMKo6xZeDhFVDG
# DhVLOqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDR31UigXhHimlx
# Cz2ECk5h6CxzvUV6aLV8HPl5ibCrRQIGaqnQkeGRGBMyMDI2MTAwNDIzMDc0NS4x
# NjhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiQ7hCGwLKxkIgABAAACJDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTlaFw0yNzA1MTcxOTM5NTla
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCj
# 6W3UaQ2Zr4hNvSy7j7UMPFVys7aExGB+JFwykzzXg3jayYm9gOLXJ7tNhU2emhrL
# QCOZcgLvz6FkqmghzQxzmkgKtLYiKaEzhogO/ce0lThdLNdVtMwQOYgo+XtXAZcV
# iBX4LcHk38RusZiF7wxSa5t/Lxic04+Z/hly1gJQpIeFDqp4a9PuLt8rsfH05vW9
# pU9uriGdDxfJXn/lc49CxbXqA3EX17L24bc6t+mFuPDAJKKpai3XXqF2nJlpTPfd
# rA29sWTSNKig9CtBC5tzQj0flbsa/4wqO9u+RkuwpZb3b7qnW5FdFrDR1vQmXfjl
# yUP9ZO38839NwSuiHtvsFCNkTNIX8OL5XVq1nsKyu//GeIZ9YuxsfLBedqG024PD
# ERyrAs0pvfUWOLapVQajHPoCnuNSKvbEh7s5IQ0YgupGji+H7rIDx2/mIEI+6Q8W
# wBtk3Yxyhjj0GXw909i0EkTkVyy+1yADjwSC8bw2qM4+Mc4hyytlZzSc0IPUBq1Y
# GnYwCjIwa5/lMW0pFn/HpJdB6XeMuTtYTOpaPoo64FjQryLXWjd4ovpw5lOw7X+v
# 3E9kwN9VBC+wJESBECC1gZMCS5TaVwfE1w4pnXXb1qT9bjgRsPg4dklruUTdon/3
# SNt0a0Q5Nc2Ul+rMlQxXoP9isXwMNnKO5JJkqRDRVQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFHMfkX1u/zJLCMe0gqYitx1tAHeoMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA+wHSbmhIpM8CRVZ4tk624hQ+LdZXE4qoeQui77CeNa3jq1FOzi7MRKkko
# 6diEDHXPNWvAagxastCewPzm5TCNh1s4qCHh4R2G/r48wU/Mpc68/WDmJy5CIQn/
# Fwps1sbNUEu7Bzg004qULIVJ963jo/am4xwKgwh+vSVL7/dhsfT7dvhpRddbYLQT
# HZgwuNB6QhcEEsgogLVwNRj37VEWZDiwoMdxyC7YYrQu6MCVtizHnOtkSX7FqIoi
# 6jlcfqfo619uDH9r8k2qAOHCeEAqKXKymIXDMcGGlEdDFbYiDZgPCBM0IHgAeilU
# Son07wjHu0e0ssBmtBafPb4Gd+5FuRnWG3XGe91NCpLKqmFa/4GkVz9OMzZUg8oc
# zxC/4JT3Hf45JEtszToXwNskV3JNCcu2IItr6SJHmi3EDVADDRSNhdzFRpYmplGE
# lPl5GRoPtJiDEvRIbv5MFKIw2x9gnehf5IvBjC4ZkBg+4GTpqGE3mmnzF3nIekOk
# X4ug0/0mN2CSarhuSi9NmHIOpUN2eQHUtgTb/+Gmq7gktCMwIq/JOCYIiTYqpv1o
# bjAGKdWMPCrlSyNAs0jZYzkha535158NMx+wBGvsfFoVsCMG5Ocp6vW6CXyuWRbU
# VqMU1OrQbHfdyzJpbhJC1PbAZIyJCbN+VBgDTAzTKY8w4ISSwTCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCmCPHbmseASfe//bGtX9eQG+0+
# 46CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7m1YojAiGA8yMDI2MTAwNDIyNTg0MloYDzIwMjYxMDA1MjI1ODQy
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDubViiAgEAMAcCAQACAhkXMAcCAQAC
# AhMNMAoCBQDubqoiAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAGsi1P9t
# o7iNJjLznSf5AJdNvsFZbjDRdeEzT6ovALLcUpbQp+3x5GAG9/286gRPgtRWAVc3
# 7Sikzni4OUV/Ee0YttO7dTHKmpThDEW3sAgBoaZoNg3mvV+8B3PNgDs1y40EOC+4
# kEz2rCOEoUYvp+gv9fr8MkVkAcpQKnUTV/czwayxxtzpkNh8v27rnNqHnGjkPmfx
# 4nUvxO/s0c9jlpnna0hFGMLEIOkO2bpAS03vbe0AW0u4xDiok2wrihib/0DIU2yG
# WGwhm9El9xliCxFtAIhGsdozeX2Oe+CP8+HlwWyMGGWDKfWCth08UhPcF5L7DVDU
# 2tt4XZtmx0qFH40xggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiQ7hCGwLKxkIgABAAACJDANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCD4RY0M
# 8J7bTL1PacAM52pAsw5Tefb+jxTu75rm3//mnDCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIEghPTdqm/dRyZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCysZCIA
# AQAAAiQwIgQgU5mURO/zHrPYrcuVg2YCid3UmRN0SRCskRN3ZhvyOYkwDQYJKoZI
# hvcNAQELBQAEggIAGV0ntcIPbETb8ImLRJTcV7ocThYfC2vaxZRxR7FtCIQ8tStr
# SatBd0Nags1MNTGFxQFp3hNJuR3aJ99rjKzgiVftXfqC6VZqIc2jHrf8Bhh+dpQ6
# aKkphpNsTjcndmgB35+x6DrkVRVLe2QghAdCQoYk82Cq97BlTkapuQbY4lcJPTvk
# tvGEfc50m0H5A/6InWqAL031LiDzb8AS7N8YjhGB1lt9vvxrxx3VuJtvhK76TVZq
# FbKGOA/BkZy2VzVazjLzGKg4/lpgURJUHDwKg7+qbrhyVDJmYfplHvIznLW+nuHW
# aLI3/rH2Z7X5PE9l+tx3FukdpwBPHQ46WqKElniWKU1GikOCGd7J9iSF/YPYGoVF
# AeZmnAcWN7Ajn7/4a1EVIxqFv2pCC3ZisjQk9Rhbm5tMHy9P8/GDwg1OdaUmvv7v
# lNXMceV0KRwjNzGdGJZO4T3bPxY8U77z0KIlvTthZCqSV+YDH3m3QrW8bgKsiuzp
# c33GARxWqmaxbRfoP7E94CFKyxNau05VYerK/W/xORdbSg/THOlV2PobZWO9Hsv0
# rTTuH4s1GZkUhZBNKw0Od7omWeHrC8HfWbKHqPqucz9UN0ko6jZoBwHezTtSavce
# eXpvY6/vFHMi6plZA01l1E6y1UHfm6/XxhJpUQmJpHJy4zwwMyO+HDdiHwQ=
# SIG # End signature block
