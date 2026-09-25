<#
.SYNOPSIS
  Dark theme and Windows Terminal profile defaults.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script:DevConfigThemeKey = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$Script:DevConfigThemeSettings = @(
    @{ Name = 'AppsTheme'; KeyPath = $Script:DevConfigThemeKey; ValueName = 'AppsUseLightTheme'; Value = 0; ResetValue = 1 }
    @{ Name = 'SystemTheme'; KeyPath = $Script:DevConfigThemeKey; ValueName = 'SystemUsesLightTheme'; Value = 0; ResetValue = 1 }
)

function Test-DevConfigDarkThemeSet {
    foreach ($setting in $Script:DevConfigThemeSettings) {
        if (-not (Test-DevConfigRegistryValue -KeyPath $setting.KeyPath -ValueName $setting.ValueName -Value $setting.Value)) {
            return $false
        }
    }
    return $true
}

function Set-DevConfigDarkTheme {
    foreach ($setting in $Script:DevConfigThemeSettings) {
        Set-DevConfigRegistryValue -KeyPath $setting.KeyPath -ValueName $setting.ValueName -Value $setting.Value
    }
}

function Test-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsPath
    if (-not $path) {
        # Missing settings still need configuration when Terminal is installed but has not launched.
        return (-not (Get-DevConfigTerminalSettingsTarget))
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $current  = Get-DevConfigJsonValue -Object $settings -Path 'defaultProfile'
    if (-not $current) {
        return $false
    }
    if ($current -eq $Script:DevConfigPs7ProfileName) {
        return $true
    }

    $ps7 = Find-DevConfigPs7Profile -Settings $settings
    return [bool]($ps7 -and $current -eq (Get-DevConfigJsonValue -Object $ps7 -Path 'guid'))
}

function Set-DevConfigPs7DefaultProfile {
    $path = Get-DevConfigTerminalSettingsTarget
    if (-not $path) {
        throw 'Windows Terminal is not installed, so its default profile cannot be set.'
    }

    $settings = Read-DevConfigTerminalSettings -Path $path
    $ps7      = Find-DevConfigPs7Profile -Settings $settings

    # The documented profile name works before Terminal has listed the PowerShell 7 profile.
    $profileRef = if ($ps7) {
        Get-DevConfigJsonValue -Object $ps7 -Path 'guid'
    } else {
        $Script:DevConfigPs7ProfileName
    }

    Set-DevConfigJsonProperty -Object $settings -Name 'defaultProfile' -Value $profileRef
    Save-DevConfigTerminalSettings -Path $path -Settings $settings
    Write-Host "Set the Windows Terminal default profile to '$profileRef'."
}

function Invoke-TerminalPhase {
    if ($Script:DevConfigAction -eq 'Uninstall') {
        $steps = @(
            foreach ($setting in $Script:DevConfigThemeSettings) {
                New-DevConfigRegistryStep -Setting $setting -Reset
            }
            New-DevConfigStep -Name 'TerminalReset' -Description 'Remove Terminal defaults and PowerShell, Copilot, and Ubuntu profiles' -BestEffort `
                -Check { param($DistributionName) Reset-DevConfigTerminal -DistributionName $DistributionName -CheckOnly } `
                -Apply { param($DistributionName) Reset-DevConfigTerminal -DistributionName $DistributionName } `
                -ArgumentList @($Script:DevConfigWslDistributionName)
        )
        Invoke-DevConfigSteps -Steps $steps
        return
    }

    # These user preferences are best-effort so later setup phases can continue.
    $steps = @(
        New-DevConfigStep -Name 'DarkTheme' -Description 'Force dark app/system theme' -BestEffort `
            -Check { Test-DevConfigDarkThemeSet } `
            -Apply { Set-DevConfigDarkTheme }
        New-DevConfigStep -Name 'Ps7DefaultProfile' -Description 'Set PowerShell 7 as the default Windows Terminal profile' -BestEffort `
            -Check { Test-DevConfigPs7DefaultProfile } `
            -Apply { Set-DevConfigPs7DefaultProfile }
    )

    Invoke-DevConfigSteps -Steps $steps
}

# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBZhUkjewpLCplm
# vGoEeNmxZlVNILWsKKrmvmaAJ4G5k6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIC3yCEQlMmSt7LEDPs6dfzEhWffXA9lJeiQqWgFNnhM9MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAnHisnUZZCk3YvUey
# jcvxA16oKv7FMbITdDujtgjioNHxv+JT/L4l2/3wR5EI+ho2SEWF0OCDxg0Wg7+y
# n8v205xBLirYrDMo/Z0ArjrQQtYU4mNAOTL/RJaapEe/9k3MuGvjA9XXWfHwnNk+
# kgpFb4kw1ccvl2er6ouFY8y7LvDdP8tbi3gH7QbWvHyMzuJ/B4VvwsFjAAvII0/w
# mhz8mJQTnfMLUCQV0q7Jf/MzLyIajHfYt1NsRT1Sx6ZfkWaNL89eLoOXdUjQZv8w
# QYEtWUdi+o1IE8t9i4dpfrjmsTRexgp1u3CC3zFeNI75YCJbGmErPP6uS+YK7Arq
# Ned2PKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAb1QGewcwu4FQt
# YtLbwfr2cppmCOkd7fGRBUSLkqkaYAIGaqosmeIeGBMyMDI2MDkyNTIwMzkyMy42
# MDFaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiJB0vaq/8i1/wABAAACIjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTZaFw0yNzA1MTcxOTM5NTZa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC1
# ueKJukIuUsAAJo/AY5DZRqH7bhgv7CWGNlEdbRGoITrdE6Wsn57NaNu1BTdjBbFc
# v7Rfixte0x+HRvXSqsD+WeSX/6/y9wE0Mz+xRPTGIY20K7aQDa68OyzVyUeUCypy
# ZC/gW/3ytO/ZOnU9H2ri77kJP8ABrqyy1UxX/OseEgvHsj8yikWT0ARtrjWbXMHF
# zSOo5hQcfUmMXKqWWz6+N0+UynhGy1n+doW4WZgpH8Y5W7hpSokWj1M/Lu4wi3o6
# Dz9vVWukcgUFGjLAl4YZpOhah7HuiC/alXImMQf8C3A8q/6/1hFoeIZB4UGkywxB
# /OSTOSsL6+39pDqzM7CgOpf4V799kN94yM9uXJI5T/SiA5MdIZIhEW0+bh85RqDh
# 5YW3/oav54RPxw5OPlH64QV6KJkl0FIElMVoLNo8UWRQcMD179x7WASjC6LsaNZ7
# yK0qcESIsL1wiQmdfQBxcqrFCpIQfnmQFkOp9IyXUWqza8tmpz8E6aXg9b1eiAT3
# PVTgrOlPi/hYZCfPxX/6jGtyPjy1CiwOmJamohmSU//COAenfRT2G2HMRUpCX1zs
# +AmDmdQM1XRab4YSALLAlDzGCsgI77nnuJjoXAliJmv7NfrvWAcA5KqCUOWQ6kSP
# t5r28MfKXWJJpSXtFeS/MkDzJy/iJRVyHcFy/B+MtwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFFkHwGoDJ5ZbEEiu8KstiusqaozQMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQBiAM+nqrpwG29txSXv42o+CsTe2C4boaRfFju9JaWkLTHwq7pknNONL3n+
# UG3x/B083EKXiFYrAmul7BTHCGXU63/xRsZ2wj3ZmR0A4d9nf9saCJVm4juPVFBa
# i/oktOOYH2j+1+zM70woN5ongB/pvy7X8AfY6JB4XPvb80Qz7fY5eddbnwjzg1sZ
# hUPFbbcweWeACINrzqFK62mMeXKmhtufMraoogJeJXfWY3x4/pbubgENT3+pXT65
# 203CPF9kfdKE7GKAIRYy3xkBTDvFd8dufjOpCn38nK6qMlVtnBjDhWQG0PM3E/ox
# Bs5UBrI6pBYkmIHtbjifDquHT+ThaVV7xHc6InoSc3aNzX49JHUgQmuvDdMjLkbY
# XeA0/1q5IxSg2U+ycZBOvAi3udZPKhA5VzODjf/ucu/vFtXrYcRkmGKN3jujaK3/
# yMZi2Ju5NEL3ISWorwp7RjeZg+JMIK0fosuVj+YCm5r64LH/D9QJDAj+XfZaNeFd
# v90K5A0QRRGP/poB9yTIVjEXj/uJzp8L4Dd44sAquqDOiHdkLgxfK8nPqpCSWPZ9
# G+RCPm85o9cAfxENtrSuOwcpyKzxsRCYCL+PK4+98orit9EVJ/LLoCeG+jLlj0Ka
# D4Qy6sZe4rWMr1brQLosTBZNwFnXxNjInCWBd0i7is1yTS/4qTCCB3EwggVZoAMC
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
# U1MgRVNOOjg5MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQC7ycXVZx3bsDpJkr7Vucgpksoz
# uKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7mEvzDAiGA8yMDI2MDkyNTE3MzcxNloYDzIwMjYwOTI2MTczNzE2
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuYS/MAgEAMAcCAQACAhQSMAcCAQAC
# AhSHMAoCBQDuYoFMAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAE4wsB+4
# lp7OROgr3rT8/twvvZ0xmr0gjTze4tA8x6mOR5Bvr5dCpH2pcu3ZRZEf496xGOTO
# eEjYBzMdoE6ZGmhCYh3c/IrZ9uAYKKSOW0iVpZdAGu6Ddew13KD8jxxvLazGjSVk
# 0r/gr8+xE4ghs9iKLNNxE1o372ThkmZzwNc7JKNmm9De2ouUKRIvuvjAgMYzW/HF
# ThLrg8DnWm9yRP9Uit4PqEFc0MJxCn/99DrqA94BEpE92EuZlqifPUicPFFBLGBq
# hte4muW8hyunuRKuyzP3LXsrSFyge7HaVBuW8Bd4opPnH61X28OrNfPUxE1lA4Yq
# IZ8UMnltl6mINUMxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiJB0vaq/8i1/wABAAACIjANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAyM7H+
# F+EmTdZ2Zv5eoAR0ud9E6U8J3YJm4gv2TMrw6zCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIAVgXQEKBOfGgjNskmDOmbcEIOnHGNwA+QcRufDR5AkTMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIiQdL2qv/Itf8A
# AQAAAiIwIgQgxuYaooi1ihSd5e5K4nAq7Ho9AVFTbdy4hO4sxiN2NKMwDQYJKoZI
# hvcNAQELBQAEggIANf1OFRwc+xqHSKG6n2jT2HYYA5MktP6SX2BygZpKPhJ2UJYb
# O6weAG/mcljos+A5K7dS7JlNpTPV2NjI4ouCtJcOe33h7bGnHyabHSvbfACnfseQ
# brSOhss96+930E2EjaTkE1KCT+dJobXcD+1h9BwEr23sOIC9gY+xZ5FM2RKn6BF+
# 12/brp9b6IEtMvTI4Fe6rDFdNE/zwHcom33Y+wDKbbKRDxBKIeZkQNbYDIKJ9+rT
# SU4qG+n+GqBRDIW4TXTD7+4JJsB1QTWqPpzKWaEx3k0PkG5oT93M92IeQvOFviS6
# k12yq90qgBaO/2dYRdNTHzSMNEzbt4/WXqqXcvagLU9DfiszOp/AJEGQKP/JGdUR
# AmQBQjRsKZ92Dyd7mQMR9BOSuwsWr5PsZi4l+AQLLHz3oEUY59Jg1JUCOnlUEVGc
# 7TfNjQN97QgwqQ78ZOyOxr3tcNYOWKZdxAXRLGgvMK+dLmtfZhfszFU0bgOeOjlL
# acED7U3kIhsTjVe4FTNBlKySIldnyEw5K4ng7Cq4j1THXnCj+G4TQZCGiXYCw4I1
# 94BVNTrZKvfzAe2B3z8mfs5EARCM+Ryjwmg+OnPcVjgf6uoKdgpaP6GFpxwXY2H5
# xS8oyyeSEfEDu0iQXK9CSsR+T52IVMYDWPODrm4KCpKwWPKT7S029+6mT3E=
# SIG # End signature block
