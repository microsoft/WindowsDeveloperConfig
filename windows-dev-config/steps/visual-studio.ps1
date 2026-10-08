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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
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
# mEvJ86GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBM7h/1cmMw9OJX
# nUaV9JHhd4y4ebVn3YmSBNNGKwWGKgIGaqppwn2XGBMyMDI2MTAwODAzMDIwNy4w
# MTFaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiY1tD5nQ5P2HwABAAACJjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDJaFw0yNzA1MTcxOTQwMDJa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/
# /w+ZZIL5RFFpVI8D3ZyuNu8IzcAEOD30OLYjh337rXjcrIlOSzpJc4ZeUxEyli6x
# 6F6zm4NR8dbPb9diDp/hOUzHWGxiA1Z3RXKBb/4F/ojyvN43SEGWqSfVc3I3BlsY
# T35ecVAJ9kVf90YOv29tFjJBBZkYvrT/DwwyRLscOyP4p+9/lyJjD+ULs3YXBhVr
# fZ+MbQB+BYKLqRvBKbj/wR9akNrMxQINoGaD5jZO/N/nSsmG2P1zv/cv4gSoMBnW
# eQIBkjd2I5w1DeXupp2vSiNmR5sA2ZkBK3yiQWaJvRxODlkfiyHk9Mkk/TrYTjmj
# PCbhe+uqhHNRy8UlbOvWsCq0tRtUykHv39DgqAfJNrE8OSt835rBzDprrcAhwmgf
# hoVi4AKeqwikY0nUa48K0Qy80XT4fiEA3ExEZNaRFo9Nq/GwbfgqKqGmc9xhKuRF
# cjtua4KHZvnAvpWgEFSOCkovXs/BcLnkEHM9xZ8iUag5CyhNqXYYE/z0pcXdYaNI
# kQ68EWmuvLm7g9oofV2vOm5GVNoghnkWG6nGPo/JwEgmA9oSS0EfvFRMWPA/gpSv
# F3shArKHnaEpVSSi3DNbyiuYiEs9Ko0IkZc8xKFeQRaqGRxrB+2r/7B3X81Tps99
# KhFwg+wD87od22F2MUg1x7twt3gaVnFk0IZIwUPCGwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFF3hn9fYJN2Y/Z9LVbBPIxAzXHsQMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA2Ux0tr9sYCjsq0FRyiVpx15OurNXv6Qk7iX+ArVPlz3w4tqjcTNm1dt3t
# Tua2wJMpJhPH8n7UXhmT98d5Du44Ll4adnse4SQfVg3QL6aRkXHnJUn8y9iftB/P
# y22n9xnwPFfj3QlDOSgLuHleu97U0iH2ZaluYabWXJihdiYpK8cPHFlqZOAiot0+
# GD8dP+RMuvpxt/F2LmYelpoZwriiFOUmlxEUV7xJHyZZlDquskeyuq01DTv91N4q
# M8cfPPhl/2pc4HeMf/nd2HouifJbDQFNd4WPhLzn0Sy3u1Zh3+S3tjQdqN+dyw60
# RaV+RXCoOLgFZ3MAg/GoDl+fvb5hy/1a71ctX8wEad1Pf6def2pqfl3wFc++hkF8
# DXXTZofJN4YVaN3InwbAGQDDkNK4lqecCixxmSKwidPynGeE5OtvNoK1pkLsm/i8
# F1RjGczZ/kSF2VDkqG866iQ+jVbGOQ6Du3eyyFcFKZoDJ4B5mEAS9aT2SKqllLey
# bOboH6r67siR5B/2Hnu7+KYuYZy0BEadtA6ngG4cnSR9JsrkhhsKmb11ujqwgJyN
# x92MsoGGwNgN1aI0QID8CsjCFwpfmMzlA44xHKYv3hmjxeqBS4uU5rQeiAnVgpJe
# aVGKm/lzPDtnppGV+7XhRp5b1ZxT/Z7Xxc+I7H7/jCtQDZoaZTCCB3EwggVZoAMC
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
# U1MgRVNOOjk2MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCi/fMxFtkqr7XMXdsRyWU0lSKH
# Z6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nE9BjAiGA8yMDI2MTAwNzIxNDk1OFoYDzIwMjYxMDA4MjE0OTU4
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucT0GAgEAMAcCAQACAhC7MAcCAQAC
# AhNUMAoCBQDuco6GAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAE72p5YV
# UocX6tsJyGuvVw4p6ZjOux3Onlfj/ev5SDTselbxccZP8Fz+Ipi6foudyMlgBITB
# ZeJUjaO2774AlUx2k1BgaVs3EMZZR0ILpFucrv8BDTHX356F9qibm/73OW/ish/A
# KwEbuDjw9TOPm+OjtHK3+6KoZfR1tnNrMRYRU92PQ10hvyhTlbg1piUR3da+xz3b
# jMtegMEDr20X09D9nn5c6RyT/eG+4l1TCvpD+Ji0sb5ObplLDCSx3Cce+kPMfI48
# OaCHZ84I/OncTfcqExN9Mtm77q+/IaxPtNWNLp1jeTYG9jACfi6rKT1tU7fhLXdC
# soJQ75AWks6UdAgxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiY1tD5nQ5P2HwABAAACJjANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAU5S20
# u2qdeQlGf3bISHC/PI5Rp0X0ClTUHxFr2OUMfjCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIMwyXGFnTNsZRBrs6GN/BbV0okaNP3VBYqLFjUsFnbgqMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAImNbQ+Z0OT9h8A
# AQAAAiYwIgQgQkY8i/Wl7jyUXnjwKjpnYMF3np2azI80vYi5naVqoj4wDQYJKoZI
# hvcNAQELBQAEggIAGXhCdwfa8Xk/3cf0Yat6GOoUQuNHwofzT/v/KqrBJhTaJfCw
# EExlzdlRHYZRkfURe35ZDi5VPx5FZF1IyJ0H6iD2ZNYIJDpv89M01JQ7vuDu141n
# X1ApEa/LDqlPsWD8zCyb/6ubI008KeuFJ3GfTzQbZxTcpnpuXH+RYtGs9EZQ2ihP
# lka+X9J4/Xdhebu2kqr1R/vwayy1lkwzEZQD5xKR1fshn00i08GYbKSEutkxPHvM
# 8e+/B2rJKu9aePfbMcf2XObG2Pejf72rBqmMqaM7p/11CCc7Qvd2VGXDqMkHODmQ
# oq16jVNPRg/rd/jWv9Cb3bwLBz8BdYlRY2wZBg6+CCHXQKZ4PsUEZPfBYXqcggKS
# RvBy11nrv84XGncTxW5vVfJ91LCfiLf7JHz8YuPo9KDnGjXIgF0uTVsJYyuQPP/C
# SaRpOPYk/ADwtgKMxPtc2Z2tyUzZyA9uoyNcf9hbrnXTRcx0SV9JzOelEIVqVC+h
# ytlbwdGXVWwABs/9LyisJ7dfbod99BdFWRS6hY7zK2dkeqz43IFkz8Ov00qtlLIR
# nH9Rq5wLamlJCZgKc9Ypra2bsmxJzcFj1CNpgPZ0/Hu1AQVeLvlPVUBVBW3gXQDc
# 7KTh1A3wuIBBaogVq9vT7lPOjyLwz0BLRod3U4tDGZMqXWoRhmc7uS8bsPQ=
# SIG # End signature block
