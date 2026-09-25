<#
.SYNOPSIS
  Installs or removes the Calm OS package set via winget.
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
        Invoke-DevConfigCleanupCommand -FilePath $path -Unelevated `
            -Arguments @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') | Out-Null
    }
}

function Invoke-PackagesPhase {
    if ($Script:DevConfigAction -ne 'Uninstall') {
        # Show the header before WinGet setup; skip it when a resumed run summarizes this phase.
        if (-not $Script:DevConfigResumed) {
            Show-DevConfigPhaseHeader
        }
        Initialize-DevConfigWinGet
        Confirm-DevConfigWinGetReady
    }

    # PowerShell's process architecture can differ from Windows' native architecture.
    $architecture = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE'
    $vcRedistId = switch ($architecture) {
        'AMD64' { 'Microsoft.VCRedist.2015+.x64' }
        'ARM64' { 'Microsoft.VCRedist.2015+.arm64' }
        default { throw "Unsupported Windows architecture: $architecture" }
    }

    $packages = @(
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
        }
    )
    $powerToysNotifications = @{
        Name        = 'PowerToysAOT'
        KeyPath     = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.PowerToysWin32'
        ValueName   = 'Enabled'
        Value       = 0
        Description = 'Turn off PowerToys always-on-top notifications'
    }

    if ($Script:DevConfigAction -eq 'Uninstall') {
        $cleanupPackages = $packages | Where-Object { -not $_['KeepOnUninstall'] } |
            Sort-Object { [int]$_['UninstallOrder'] }
        $steps = @(
            New-DevConfigRegistryStep -Setting $powerToysNotifications -Reset
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
    $steps = foreach ($package in $packages) {
        New-DevConfigStep -Name $package.Name -Description "winget install $($package.Id)" -BestEffort `
            -Check { param($Id, $Large) Test-DevConfigWingetPackageInstalled -Id $Id } `
            -Apply {
                param($Id, $Large)
                # Large packages can have several quiet download minutes because WinGet reports no progress here.
                if ($Large) { Write-Host '  (Large download -- several quiet minutes here are normal.)' -ForegroundColor DarkGray }
                Install-DevConfigWingetPackage -Id $Id
                Wait-DevConfigWingetPackageSettled -Id $Id
            } `
            -ArgumentList @($package.Id, $package.ContainsKey('Large'))
    }

    $steps += New-DevConfigRegistryStep -Setting $powerToysNotifications

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInJwYJKoZIhvcNAQcCoIInGDCCJxQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDmoxsSU6uMiwMS
# Zzu2MAi1snT2EP2DGieid4uEZ0bMKqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnDMIIZvwIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIFlNX6bt4TLXzlWd8J8wuDpYft+exS1UwK1STHxUJ8APMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAOMklk3hBBTjP5UBA
# 1EKypOCaj8iRNIBAq+f6q6z9WIPh5OvLPztJjBhr47iImJJx2k5ZmB3LnEWNoAaU
# Ch3QnVMhKDHx6qTatRpgrbDvsLXAVUHb1sSheeHinFFOO39bqD7Y18JAuUdm1w+5
# xADKMxUIwNgWTmRYgvAGqK7GxLMUUM2fKmQb4Fnlg+QdrzrSSispaEy9s3JxUpek
# VrGsk80J8LN1i1sHPvcC/cBECMsZXmuad0Y9qPSBqR6ncz77YrkspMYObrzhVSUh
# fDIRWWG/bnyemZ7D1QImuG/ni44Y3LktUlTe7QzW5VYs4wjhVgMoM7QYv4oPepfx
# BY+jLKGCF5MwghePBgorBgEEAYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2ww
# ghdoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8
# MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBpdkC56MBHCsLk
# 4ULHMZ7UNVhXnaIK9UehHAuY+vlqawIGaqpnzSzKGBIyMDI2MDkyNTIyNDc1OC4z
# MVowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjo5NjAwLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEeowggcgMIIFCKADAgECAhMz
# AAACJjW0PmdDk/YfAAEAAAImMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5NDAwMloXDTI3MDUxNzE5NDAwMlow
# gcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsT
# HE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjo5NjAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL//
# D5lkgvlEUWlUjwPdnK427wjNwAQ4PfQ4tiOHffuteNysiU5LOklzhl5TETKWLrHo
# XrObg1Hx1s9v12IOn+E5TMdYbGIDVndFcoFv/gX+iPK83jdIQZapJ9VzcjcGWxhP
# fl5xUAn2RV/3Rg6/b20WMkEFmRi+tP8PDDJEuxw7I/in73+XImMP5QuzdhcGFWt9
# n4xtAH4FgoupG8EpuP/BH1qQ2szFAg2gZoPmNk783+dKyYbY/XO/9y/iBKgwGdZ5
# AgGSN3YjnDUN5e6mna9KI2ZHmwDZmQErfKJBZom9HE4OWR+LIeT0yST9OthOOaM8
# JuF766qEc1HLxSVs69awKrS1G1TKQe/f0OCoB8k2sTw5K3zfmsHMOmutwCHCaB+G
# hWLgAp6rCKRjSdRrjwrRDLzRdPh+IQDcTERk1pEWj02r8bBt+CoqoaZz3GEq5EVy
# O25rgodm+cC+laAQVI4KSi9ez8FwueQQcz3FnyJRqDkLKE2pdhgT/PSlxd1ho0iR
# DrwRaa68ubuD2ih9Xa86bkZU2iCGeRYbqcY+j8nASCYD2hJLQR+8VExY8D+ClK8X
# eyECsoedoSlVJKLcM1vKK5iISz0qjQiRlzzEoV5BFqoZHGsH7av/sHdfzVOmz30q
# EXCD7APzuh3bYXYxSDXHu3C3eBpWcWTQhkjBQ8IbAgMBAAGjggFJMIIBRTAdBgNV
# HQ4EFgQUXeGf19gk3Zj9n0tVsE8jEDNcexAwHwYDVR0jBBgwFoAUn6cVXQBeYl2D
# 9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUy
# MDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUB
# Af8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQAD
# ggIBADZTHS2v2xgKOyrQVHKJWnHXk66s1e/pCTuJf4CtU+XPfDi2qNxM2bV23e1O
# 5rbAkykmE8fyftReGZP3x3kO7jguXhp2ex7hJB9WDdAvppGRceclSfzL2J+0H8/L
# baf3GfA8V+PdCUM5KAu4eV673tTSIfZlqW5hptZcmKF2Jikrxw8cWWpk4CKi3T4Y
# Px0/5Ey6+nG38XYuZh6WmhnCuKIU5SaXERRXvEkfJlmUOq6yR7K6rTUNO/3U3ioz
# xx88+GX/alzgd4x/+d3Yei6J8lsNAU13hY+EvOfRLLe7VmHf5Le2NB2o353LDrRF
# pX5FcKg4uAVncwCD8agOX5+9vmHL/VrvVy1fzARp3U9/p15/amp+XfAVz76GQXwN
# ddNmh8k3hhVo3cifBsAZAMOQ0riWp5wKLHGZIrCJ0/KcZ4Tk6282grWmQuyb+LwX
# VGMZzNn+RIXZUOSobzrqJD6NVsY5DoO7d7LIVwUpmgMngHmYQBL1pPZIqqWUt7Js
# 5ugfqvruyJHkH/Yee7v4pi5hnLQERp20DqeAbhydJH0myuSGGwqZvXW6OrCAnI3H
# 3YyygYbA2A3VojRAgPwKyMIXCl+YzOUDjjEcpi/eGaPF6oFLi5TmtB6ICdWCkl5p
# UYqb+XM8O2emkZX7teFGnlvVnFP9ntfFz4jsfv+MK1ANmhplMIIHcTCCBVmgAwIB
# AgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0
# IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1
# WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O
# 1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZn
# hUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t
# 1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxq
# D89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmP
# frVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSW
# rAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv
# 231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zb
# r17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYcten
# IPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQc
# xWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17a
# j54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQAB
# MCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQU
# n6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEw
# QTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9E
# b2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/
# MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJ
# oEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01p
# Y1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYB
# BQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9v
# Q2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3h
# LB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x
# 5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74p
# y27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1A
# oL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbC
# HcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB
# 9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNt
# yo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3
# rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcV
# v7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A24
# 5oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lw
# Y1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA00wggI1AgEBMIH5oYHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAKL98zEW2Sqvtcxd2xHJZTSVIodn
# oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcN
# AQELBQACBQDuYWsGMCIYDzIwMjYwOTI1MjE0OTU4WhgPMjAyNjA5MjYyMTQ5NTha
# MHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO5hawYCAQAwBwIBAAICIckwBwIBAAIC
# FgMwCgIFAO5ivIYCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAK
# MAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAuO1bbpW8
# R7My/uFH5g4DMG4YTBEA83UnASeml3hqshonu7jfYJDhA/0UxLfCk6INAllsr/WZ
# l1YDWwivFS/RG79JuBYL/ICGmwPqfIEpr7vhJ4suN9QqLYxV+xwvD/RJXPCXn9nb
# zewJsSSrwLfF8KUkeXFop4hKKIKN5GonUn7qwWtueYUXhiKYK6+KGW6rvh94ajSU
# 2GuFewZPicnGTGf4knzexzHsi7q6iIPje+at41desrzsPLCgXKiJQl+h1+YtThgr
# FjrBc2W6ggh+DTk8bmsj/2hezdLbLAMxPoMYmOrKk/AW/2mbCambnbuajNZXjq9n
# a8NlEhNgm29mbTGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACJjW0PmdDk/YfAAEAAAImMA0GCWCGSAFlAwQCAQUAoIIBSjAa
# BgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIPdZwzGU
# juGjtB+vDA0s+FfWpDPd8bc4ghTP4qwJEcIeMIH6BgsqhkiG9w0BCRACLzGB6jCB
# 5zCB5DCBvQQgzDJcYWdM2xlEGuzoY38FtXSiRo0/dUFiosWNSwWduCowgZgwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiY1tD5nQ5P2HwAB
# AAACJjAiBCDGXcRT2AAo378o48NItPiuCBO+Cm/WWGl7CKIIWz0QsjANBgkqhkiG
# 9w0BAQsFAASCAgASlx4k3iopW51Mlr1rsO649Q1Wuk5DO61YrfNr5Ap7hPCguSng
# QATY4TeNpBdOwpr2l/RneGZpmsIxiT5CsMLwmfkNX6WB8pf2jGpnAW/0RSRce/gF
# aWOrsK1G7htxXUll8spQYife7i93q7vxeq4rlHjLbsU5DYXcuJ/tQ1wdxoRPOl/L
# kIpvnFDIU9RFfdT4u/gEfbMcxvq0EqEShUZqohIaJPj0X4e+xjWJgbwBb24JEolW
# H0b8BVX38DMzATYuRjYX110EXqlNAb8x6XggbSFWhEEjUyAcji66y+Kmc9qa9ZH/
# NxGp9BucRietfzwvSOEQZKuilQZ+ePKSNE8b8mqZ+sP9dHfhuZskxYt1rHbh8/+0
# MTppqBXgF6OaBgawHloLb2SfQxVovav0i3Eq/ZhUfN/Me1/2qeSED28bGcv2K9nu
# +UU4F3CY0i/PadYJvTkYr31sNgT/nFYAk1IsUrIkOeP+zUG7Bb4ZeCyCPbq11+/4
# jEtVT4R4VPy8Ji7dyh4XzxkUzlNS56k8S3bxe6QzdQ0CkBRTTqHOQfA2GuVJ8UGL
# j5/gRepAj0ztSX/oI957DH2xbRUCk5Nhis77Cc9N0hfoRo4lIybiof46ql3rwqnC
# wq4B0C0nRElJgA8RVc3KUmbiVq25LKWsfG7QE//vc8TZ2p7rRnRWIWvgvQ==
# SIG # End signature block
