<#
.SYNOPSIS
  Adds workloads and components to Visual Studio Community with the Visual Studio Installer.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Matches the Microsoft.VisualStudio.Community winget package in steps\packages.ps1 (Visual Studio 2026, 18.x).
$Script:DevConfigVsProductId    = 'Microsoft.VisualStudio.Product.Community'
$Script:DevConfigVsVersionRange = '[18.0,19.0)'
$Script:DevConfigVsProductName  = 'Visual Studio Community 2026'

# Installer exit codes for success that needs a restart: 1641 (started), 3010 (required), 862968 (recommended).
$Script:DevConfigVsRestartCodes = @(1641, 3010, 862968)

function Get-DevConfigVsInstallerDirectory {
    Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
}

# vswhere reports only complete instances unless -all is passed, so a half-finished install never passes the check.
function Get-DevConfigVisualStudioPath {
    param(
        [string[]] $Requires = @(),
        [switch] $IncludeIncomplete
    )
    $vswhere = Join-Path (Get-DevConfigVsInstallerDirectory) 'vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        return $null
    }

    $arguments = @('-products', $Script:DevConfigVsProductId, '-version', $Script:DevConfigVsVersionRange,
        '-latest', '-property', 'installationPath', '-utf8')
    if ($IncludeIncomplete) {
        $arguments += '-all'
    }
    if ($Requires.Count -gt 0) {
        # vswhere matches only instances that have every listed workload or component.
        $arguments += '-requires'
        $arguments += $Requires
    }
    $result = Invoke-DevConfigNativeCommand -FilePath $vswhere -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw "vswhere could not list Visual Studio instances (exit code $($result.ExitCode))."
    }
    return @($result.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
}

function Test-DevConfigVisualStudioComponents {
    param(
        [Parameter(Mandatory)] [string[]] $Components
    )
    return [bool](Get-DevConfigVisualStudioPath -Requires $Components)
}

# The installer can update itself and continue in a new setup.exe, so every running copy counts.
function Get-DevConfigVisualStudioInstallerProcess {
    $directory = (Get-DevConfigVsInstallerDirectory).TrimEnd('\') + '\'
    @(Get-Process -Name 'setup' -ErrorAction SilentlyContinue | Where-Object {
        $process = $_
        $path = $null
        try { $path = $process.Path } catch { Write-Verbose "Could not read the path of process $($process.Id)." }
        $path -and $path.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Wait-DevConfigVisualStudioInstaller {
    param(
        [int] $TimeoutSeconds = 14400
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextProgress = 60
    while (@(Get-DevConfigVisualStudioInstallerProcess).Count -gt 0) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw 'The Visual Studio Installer is still running. Close it or let it finish, then run this again.'
        }
        if ($timer.Elapsed.TotalSeconds -ge $nextProgress) {
            Write-Host "  still working -- $([int]$timer.Elapsed.TotalMinutes)m so far" -ForegroundColor DarkGray
            $nextProgress += 60
        }
        Start-Sleep -Seconds 2
    }
}

function Add-DevConfigVisualStudioComponents {
    param(
        [Parameter(Mandatory)] [string[]] $Components
    )
    # The installer can still be finishing the Visual Studio install or an update, so wait before reading the instance.
    if (@(Get-DevConfigVisualStudioInstallerProcess).Count -gt 0) {
        Write-Host '  (The Visual Studio Installer is running -- waiting up to 5 minutes for it to finish or close.)' -ForegroundColor DarkGray
        Wait-DevConfigVisualStudioInstaller -TimeoutSeconds 300
    }
    $installPath = Get-DevConfigVisualStudioPath
    if (-not $installPath) {
        if (Get-DevConfigVisualStudioPath -IncludeIncomplete) {
            throw "$Script:DevConfigVsProductName did not finish installing. Open the Visual Studio Installer to resume or repair it, then run this again."
        }
        throw "$Script:DevConfigVsProductName is not installed yet, so its workloads cannot be added. Run this again once it is installed."
    }
    $setup = Join-Path (Get-DevConfigVsInstallerDirectory) 'setup.exe'
    if (-not (Test-Path -LiteralPath $setup)) {
        throw 'The Visual Studio Installer is missing. Repair Visual Studio from Settings > Apps, then run this again.'
    }

    Write-Host '  (Several GB -- the Visual Studio Installer works quietly for a while.)' -ForegroundColor DarkGray
    # Start-Process joins arguments with spaces, so the install path is quoted here.
    $arguments = @('modify', '--installPath', "`"$installPath`"")
    foreach ($component in $Components) {
        $arguments += '--add', $component
    }
    $arguments += '--quiet', '--norestart'
    # The installer echoes its log into this window; the full log is in its dd_*.log files.
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $exitCode = Invoke-DevConfigProcess -FilePath $setup -Arguments $arguments -TimeoutSeconds 14400 -NoNewWindow `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        Wait-DevConfigVisualStudioInstaller
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -eq 0) {
        return
    }
    if ($exitCode -in $Script:DevConfigVsRestartCodes) {
        Add-DevConfigNote -Warning -Message 'Restart Windows before opening Visual Studio; its installer asked for a restart.'
        return
    }
    if ($exitCode -in @(1003, 8006)) {
        throw 'Visual Studio is open. Save your work, close it, then run this again.'
    }
    if ($exitCode -in @(1001, 1618)) {
        throw 'Another installation is running. Let it finish, then run this again.'
    }
    if ($exitCode -eq -1073720687) {
        throw 'The Visual Studio Installer could not download what it needs. Check your internet connection or proxy, then run this again.'
    }
    throw "The Visual Studio Installer failed with exit code $exitCode. Its logs are the newest dd_*.log files in $env:TEMP."
}

function Invoke-VisualStudioPhase {
    param(
        [Parameter(Mandatory)] [string[]] $Components
    )
    if ($Script:DevConfigAction -eq 'Uninstall') {
        throw 'The Visual Studio phase has no cleanup steps yet, so no workload can include it in Uninstall.'
    }

    $shortNames = @($Components | ForEach-Object { $_ -replace '^Microsoft\.VisualStudio\.(Workload|ComponentGroup|Component)\.', '' })
    # BestEffort lets later phases run when Visual Studio itself could not be installed.
    $steps = @(
        New-DevConfigStep -Name 'VisualStudioWorkloads' -Description "Add to Visual Studio: $($shortNames -join ', ')" -BestEffort `
            -Check { param($Components) Test-DevConfigVisualStudioComponents -Components $Components } `
            -Apply { param($Components) Add-DevConfigVisualStudioComponents -Components $Components } `
            -ArgumentList @(, $Components)
    )

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBmXt9gKBcEj9cz
# oFU/dpN4WXoR8UoXNZRKVueQjZyfQaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIEyj8a7s0+r0vEVaUq5Jx2bi2jFG8qlIwkB8Qohbwax3MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAIn1YWhAC78eYDPrK
# NxO3L4g9C88SarFCwTEcNJdpb015JFdNc+nipRB7ONXCLRyn81SVM/oqJmxVpoP9
# +5kjY/P874Uw690rKHJULyMwucLtEZdfk5rydg2B37QjK4IpgteJl4P+ChBPPwrV
# 8WLYFGvI/Tfwbi4NbnLNB2OrHhRG9OvIwLgIW+DjKp/jSX7CeI+cFgm2V9Vblr8d
# EtQEbwCZ8Cusck2PIg+qfGk+AaG5jGADvolKs8r9U69MuoIWqShKU7aklle55FlA
# fWpOmlKzvq0RtXVZsaEMHTGBrZEc3xd9qbvOyeZhnUvrd1eaaseIisQwt5sO5iHV
# mEvJ86GCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBM7h/1cmMw9OJX
# nUaV9JHhd4y4ebVn3YmSBNNGKwWGKgIGaqls7XcvGBMyMDI2MTAwMjAwMTQwNi42
# NzFaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAiNP2WAkU8/+KwABAAACIzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTdaFw0yNzA1MTcxOTM5NTda
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCK
# 6Q2nk5WUdKzSCSafp+UjUARsWxHKS63rJhFC/zSabFumTBuaJ0QNrmqevub5Db7f
# Sj5qtwwKnjIO92+HXF67192fujL7DFot5WEj/AtEZ/XrzFHimKlN1h6gEQwP5I67
# wizaPW5ZzSBNpaLBg5oHvASPOZtwdNUoZ+DQKF3hJl1KZuoIlVK+qi7cLjgak6s5
# oOZcRCMrKnuC3aoVa6wRDbYvKUuj7rkFx9KO0PsHJ/k+LnZMggRheh4AVdawyh+o
# OzKPjlQGUNfSeWUgym2U9CLa8tt0mQX4DxDz6+ram50gj1oAfyQ6TQ7r96PADFOK
# BgaU7+cpHnaZG89dTegQ6ydBRGIycOw1dRX2eKDRRzziK3cn0WaIm/7OeGsyQKjI
# zEQuUTDv0Jj/9zQ7truLOOpJD98BJVOK7je84Sz2hb3HvUST7j1j2N8peD6olkpF
# HR/1Z8Jz4F+mkrUF7MmPAirYHRzunbIg3HrDMNwFYN7yBkDA4/VMo9CY0y9oGUoq
# 2yjbCwTibz9VYl93nB3QQiTCT9nW3M+TOWB+PMrZpExq1BSHmKPzIqehKqrUDoM3
# 3PK+dEKwpYLET6uXq4HuQRMXWT//sPubUnQAaaUMfQhAZSy23HtxwtN3eK9+T4wC
# av2wQFt57eUOwUW5/DCzMF9tua5He1hNvgcAXaiG1wIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFNbAh89v29nPY9bwQb1QYCzxVgeXMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQCHQwe7z5tp4NZwAf1cB+4c9J4svw3P6WqGBMxtqznS6DdzUzStXHCaPZhM
# 41g1iKHNnmcnLjwLujOEaNjhSnUDiAZqQjW5ZapOBxgc7Egghh9k+r78qWAe3rJ4
# QohBbhSGdZtKivTRaeRqmnhy8+ThrKhzCeEwaarXJimZwSpdQQUDbheWHeyAxASq
# ultd5KO0m/UFvO03tfepqGXA4tCg/WGECwKqOjJzpRAfPIB6y1HyVrk+vmL5rpEb
# TwwLOtX7WxFGG8+cYLk9HjaDkxraA/HYlKQRx1sdza+w/gulLwgOnByRJKF2rr8M
# 7FNIlwoi6ywFpaNc8A7HewaGjgw/tfcE260I1XekGluANI9HnONOYWlI7BKBQbWE
# 2teo6vsQ1Vg8B8rTZSePVdmXL1PPqqs3KVdFKM5kYocPCDM+6VL32IV96sESf2T7
# DjxanpCg2D2UYj4Z1i7cy8U1LLDGg55KWs4af2RRBjH2MulHgAmW5obKxiZCDQjR
# aroJ2XElXUhigE9BzvhCFbT/HDY2vpVpl5HnSpcCSxmL5i5lIT/xbAQMI7Luh75X
# rm+IslfFWOGOGMlCp+24qEJEglXEP7xwsolNdBNndXihhyIefVGlI1DR7xGELiJr
# k8ifVWYo9XEbEXv/lbvp6F2R2UsnweWckvq0y1HWnLHDqH6dPjCCB3EwggVZoAMC
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
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjkyMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQA4RWFs+kTiZnoZiAj1BtYj8zCN
# aqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7mkA3DAiGA8yMDI2MTAwMTE1NTUwOFoYDzIwMjYxMDAyMTU1NTA4
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuaQDcAgEAMAoCAQACAgboAgH/MAcC
# AQACAhJlMAoCBQDualJcAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBABrf
# aiBY2fPh4HTFIaAJbguIWHWscLsgsDEpvtNN6RhBP4cya323OjiZ+hpMASk6JRN+
# ZUckvtR0ZIA9HPvqiZUTftniIR5Phi1ikL+vS9sS/dp0iSFgUTzeIlWkgkc2ioVZ
# JCD73x5EH9RtSXS+z8LnmlMz2BYO0lFKpp8LNqlD1+pFQYIBFm3Uwb2zlaw12R/C
# LZN8InmNYydaOXW8+mp/ZS7IjBvAdygdL7+hYZfKN3W6j/FEFx4BQRjhKUhEtNdh
# 8hPPhO9cHeHliyl+Eu7u9NdydkyT3lINzJqoDaqgofeVVIYdwO2iwGCb0+ZnXbIh
# ikJa481GzyDmHFbhxwgxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAiNP2WAkU8/+KwABAAACIzANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBx
# GeuBz5iFu1qK9tOI/AOcpITkN1Y1GvoqE2x68YY14zCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIJbwMywRbvcGiynjnwjAqcaD47yYvebKZRAvtEAR5u6zMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIjT9lgJFPP
# /isAAQAAAiMwIgQgpcsuHZEN6tlj+bouIThVz+bwwO9yU3fgNhEGYSguf1cwDQYJ
# KoZIhvcNAQELBQAEggIAeTEZdHgilnLQ24qxLX0hM0uGrBveLi76OBSUezBJsOxP
# siyz+Ex2GDqvMnWyVbt1bYlMy8eNCI9Oeqd3hNjvG875hbETgM/JhdQrapKNYIEY
# Vy81Pi9Y8mWx3vXJJrbVFrak1B7Io17uideGXXXc7wo/qUdWNZ4PmYRHVw2yQLQA
# 05f2wS0Me5ZVKXbgWRKCA30CIOAHHLOCtaTbo+U3LAOF8y9UJ3ClIFdASEeaKhI/
# s5WtcEWspmZBI9OXlUcKRRQcc7WQ/c3RdXMbmXXfGSAj4rmQUZ+Qcscg+UqC+E85
# H0ak1Q/XVNZRm/Q6IQxpe+KdGbOK/1l6g83kdzH3ASES21hMKgMxwmDIupDmLnWm
# 5hL7eqWPmP7THr0zuzgQFOvH2EfsFQihZN1J/UKowTJ/lmzuQIXoXql6rQ14gc5f
# EThk7pHdUCtBitDjNY1lFwoYRYvcWCRkAc5W0e+4gK0QbnIjh6zVq9LFhPdUDXdp
# NBjrub5P3eIxMo3H4CJxVXNxI3zgE1STHlsjNny/oQ1G6cwbW+IHl0rp+ROera3W
# znp69CnPQ5bL/IOl7MI901tOMCSiP0MrStUgXyTcuwLwvQ2nBZPwfHxHc82RNvxU
# 7wVG9d3HHsFK9yD04E4i+bmOPGfz6bbOqE465l+BKDZHC9EaH+H1VUamgLnYKjY=
# SIG # End signature block
