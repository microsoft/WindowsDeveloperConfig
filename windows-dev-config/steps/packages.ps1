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
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDEi5r1dqR6UhFe
# hBqcAgH9RnyqSZKoRNNBMGuWBJlE7aCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEINJEOls8gHTYteKL0lKXt3+ymB7B
# rB2a7J9nd9mvBT3bMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAtpG96Wc60QaxqOqua0mLXzB3FY02HfVPCywOAAw3bRIw2/RjFaEjqGboOS1J
# 8mc8p7qG944+c4JgrjejWlxE8220LHpAx6YZoHouqJYv617gPyRVddxJl3iAsFkG
# sGsbLcc6MRYinNhpyT+ScWWDW/sJgYAt+bNS6pGAMzoRdyAH8qI4x7tmKl09pHMj
# no+8GgIwSK1h9QEUFi1DlSYaG3tjp/s9NcIN9LyBaswAJDmyrZ2zSNFYO9nmo2z1
# WKAB8aJtoWF/P3DWgkPceacSL/5cFgNWMm7qx4Y0Dt8t1hXCJXaku3/+KbJNy71I
# zSbkX1Yk2oH1DOLpc4CvT+lNL6GCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCCSSqETigFp0fFQM9UTe0RJclnLUhRU48noz1exN1A2mwIGaq45QgZRGBMy
# MDI2MTAwODAzMDIwMS4zMDNaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# MDFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACGV6y2FR19LGNAAEAAAIZMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyNloXDTI2MTExMzE4NDgyNlowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjQwMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEApqFIyUkzIyxpL3Q03WmLuy4G
# 9YIUScznhKr+cHOT+/u7ParxI96gxxb1WrWuAxB8qjGLfsbImx8V3ouK1nUcf+R/
# nsnXas5/iTgV/Tl3QTRGT0DeuXBNbpHqc+wC1NiTyA76gLnirvSBEoBzlrpNQFEn
# uwdbPLCLpTS3KWSCu5J02b+RFWR/kcFzVxnhoE3gIaeURtrGKGBZGKLBXvqggkDE
# NtKkvtvRT32xLvAvL/RpReu5z18ZojCs72ZSoa74Dy8YbaWsDm3OZOpJRZxZsPKC
# HZ6xNqgFKf0xNHj0t9v0Q3W+2z5gAVaasJJCvR52Sl0XJ2AOf3l0LSetXgUA5gD5
# IQ1RvEslTmNnSouTrGID3D1njY7mBu0puiIdPK2jK/1Weef2+YR4cQpWQkeBZmXi
# dh9AuWdlwxKQL15LJ6K2dw8y/t/PBhmLyt6QAf0CepWRdgZnMytVAUuWHwlZRV9J
# LY7aX8D55eL9+cOLpX3bGNOmN24UpIW8qtZaqXaesFvIOW23JNLhaaQVvObr1eu7
# GE/5Mn43e+/DbtdYl/bLP2IQ1xYEJdSbcUkDFfW3KlZEh+nBKDtaRnNRkbgIgxIb
# KdT38OKQwZ/aA4uSsiAg6nEPiWBHGuytIo5wU75M5VdjhEqqTHfXYu8BJi6GTzvW
# T+9ekfMXezqCkksxaG8CAwEAAaOCAUkwggFFMB0GA1UdDgQWBBSAaOo5HWatNzqZ
# n1IF1fcD6nr3ITAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAXxzVZLLXBFfoCCCT
# iY7MHXdb7civJSTfrHYJC5Ok2NN75NpzTMT9V2TcIQjfQ3AFUbh1NBAYtMUuwxC6
# D4ceEXG5lXAnbvkC9YjeLVDRyImXYYmft7z+Qpl9t3C/8a0tiqnOz8Ue8/DYLtMT
# gvWMnsqLNjILDaImOfnHI36TLCjGFe8RYLXGdCUdOLlfAdMGePxSTA3TAAOc+GQb
# mPWjrguLWbxvnl3NVjRvrBZVkxFMoVZH0f7qGwDOShjpnv5nYnQ48ufL0uBz52Rb
# PGdX4Fv9+UGOrBprmcHzmIutFtJec2Y4kujNtTK2wBGgWscEOVhFiaVdje8VLJ7M
# VNKE5TmsuGM3jTLr1nuR5AFGs3UKkP7g3cQD4cHK7XdLiTm7e606QJ+WqeQsADYE
# 9dvU9wIUbI9Dl4UcIErFw+FHaWSTrkfJ4SvLmhKnl5khhpJ1sF3z6e1BxepUliXH
# qzRLiHWihWIWESF8IHElF3POxbP4VJqHBiYvaXMV0SyRgwoD6zXddbUnX9WR6JL2
# BlqAjjHxINwelsp/VhxAWThzuMA58LxvE/VAzjfFF4Wm7a1ZALmJVw3oL/s/uxo1
# Op4tcT+hfZ9uN1htC1JN4DuRqFfLttjuoAmUQobO5zUFRzvCn8Ck/hiO+bzR15sq
# kjlxLMyMjpkc/ef4SUUikD468vUwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
# AAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1
# V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9
# alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmv
# Haus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928
# jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3t
# pK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEe
# HT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26o
# ElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4C
# vEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ug
# poMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXps
# xREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0C
# AwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYE
# FCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtT
# NRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBD
# AEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZW
# y4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAt
# MDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0y
# My5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pc
# FLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpT
# Td2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0j
# VOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3
# +SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmR
# sqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSw
# ethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5b
# RAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmx
# aQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsX
# HRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0
# W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0
# HVUzWLOhcGbyoYIDVjCCAj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# MDFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAMXYp/Wqqdyb0enigrLfxl0InAz6ggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5xGXUwIhgPMjAyNjEwMDcxOTE4MTNaGA8yMDI2MTAwODE5MTgxM1owdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7nEZdQIBADAHAgEAAgIHXjAHAgEAAgITmjAKAgUA
# 7nJq9QIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQB8Gfj5sV+2ZrfvdcDM
# YX2mEcsqIajWSjPAzgMJJDzOnX+JWyMXtsLgDxUJMkZVBTj2c0xdlATFV/l5qN92
# LCfKlL0aLQMsGoJtmL+y8QLXzyUys4PnFEcPQ/iG3AkIiwYD+i+hVgWbELKDPnBL
# bNFAhQVwStJ9pM3beeZbn9klEUW6TO/7gSPYpfjxY+1juHmYuSxIX4Gnbujpijvp
# o4oFIWoW0iM0ciMySGZ5qoabziBkq6PKH9oDXekX+2U0Mc0q4rz0V4uER8EzS1jY
# i6NTt710iBh9oChoW0vd0b6xxEb+NKT7PerWGyjW6sJyeMK9Oj26z32HYG3AwSEd
# i+a5MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIZXrLYVHX0sY0AAQAAAhkwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgzyGbM3hXh1tfVdGZ
# B8SeTDp7buYmd9p4wW7GGS9ZMKEwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCDckX633E1y1EF32V18zQcrsgjzI9+3Le7mlvk2OebthjCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACGV6y2FR19LGNAAEAAAIZMCIE
# ICHX8DfhEGDB9iO6sXC/ccy0Ob+1S04peogz8vD1vKYlMA0GCSqGSIb3DQEBCwUA
# BIICAADfGShwBmutcA8w7skrmYvtBxteDZDpOi0Rqz50SQVj4CXn8PhjLneNKJom
# N+f+Ix7H13kjKPZaunR/9rfx7kbesTqiB3BNuvl+CahDRIccz+GbDt2+9nxCtUMU
# uREFnKTnhjEnmwe2wW7Cf4Sjynd1/Eda69HwMKZG8wEA4BWfLVEezjWbryRySzhj
# 6QWaSFgzleedBa2DZe+p8/nCcmy97NCAY08Fl740gTF+habf7gyCLb/InuzYAGn9
# hYtpcTRaApUKQowmzEJDr3Grp4+qUjxlPb12jtOnzIlbDyic8DM+aa0/kfw+nFzS
# qFWfcgz/Ibpw6zZ/Z5nLdn/nDMGc6dIvOOLTP9a84XKKaQ/v0BZlYywdZ6NXEGB6
# 3+MWGFIpoL2j96l19WuKDMRyHCA0Fhs0WzaAXAPMinsDeI/+8uIBkrEJI3asL5xe
# 8DdQjXnEwxLCiWJgiaSFLu0qdtKca65MfRprF7uNyDgvmbKlCxMiUQEmnZrGD+Wj
# UwKjHo8K/WrfPdRUtPb7nnRd8y8ZNuOMahtOUupDzZXl473aQsypNcpfy2MAK3iJ
# Y/OiSzn0gWcKel9njVDyxQJWrgcTS4jfCWxiruvz3WkWZdBPTZE5CEtTT22sbj9w
# 5f9fYi1zRPgsazNOqwepRPMjLm4gtQHR20Nml4OpBM6hHSvW
# SIG # End signature block
