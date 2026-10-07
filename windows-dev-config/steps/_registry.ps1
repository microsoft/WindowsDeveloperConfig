<#
.SYNOPSIS
  Shared registry read/write helpers used by every registry-based phase.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-DevConfigRegistryPath {
    param(
        [Parameter(Mandatory)] [string] $KeyPath
    )
    # Source data omits the drive colon required by the registry PowerShell provider.
    return $KeyPath -replace '^(HKCU|HKLM|HKCR|HKU|HKCC)\\', '$1:\'
}

function Test-DevConfigRegistryValue {
    param(
        [Parameter(Mandatory)] [string] $KeyPath,
        [Parameter(Mandatory)] [string] $ValueName,
        [Parameter(Mandatory)] $Value
    )
    $psPath  = Convert-DevConfigRegistryPath -KeyPath $KeyPath
    $current = Get-ItemProperty -Path $psPath -Name $ValueName -ErrorAction SilentlyContinue
    if (-not $current) {
        return $false
    }
    $prop = $current.PSObject.Properties[$ValueName]
    if ($Value -is [byte[]]) {
        return ($prop) -and ($prop.Value -is [byte[]]) -and
            ([BitConverter]::ToString($prop.Value) -eq [BitConverter]::ToString($Value))
    }
    return ($prop) -and ($prop.Value -eq $Value)
}

function Set-DevConfigRegistryValue {
    param(
        [Parameter(Mandatory)] [string] $KeyPath,
        [Parameter(Mandatory)] [string] $ValueName,
        [Parameter(Mandatory)] $Value,
        [string] $Type = 'DWord'
    )
    $psPath = Convert-DevConfigRegistryPath -KeyPath $KeyPath
    try {
        if (-not (Test-Path -LiteralPath $psPath)) {
            New-Item -Path $psPath -Force | Out-Null
        }
        New-ItemProperty -Path $psPath -Name $ValueName -Value $Value -PropertyType $Type -Force | Out-Null
    } catch [System.UnauthorizedAccessException] {
        throw [System.UnauthorizedAccessException]::new(
            "Windows blocked changing $psPath\$ValueName. Administrator access or Windows policy may restrict this setting.",
            $_.Exception)
    }
}

function Test-DevConfigRegistryValueAbsent {
    param(
        [Parameter(Mandatory)] [string] $KeyPath,
        [Parameter(Mandatory)] [string] $ValueName
    )
    $path = Convert-DevConfigRegistryPath -KeyPath $KeyPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $true
    }
    return (Get-Item -LiteralPath $path).GetValueNames() -notcontains $ValueName
}

function New-DevConfigRegistryStep {
    param(
        [Parameter(Mandatory)] [hashtable] $Setting,
        [switch] $Reset
    )
    if ($Reset -and -not $Setting.ContainsKey('ResetValue')) {
        return New-DevConfigStep -Name "$($Setting.Name)Reset" -Description "Reset $($Setting.ValueName)" -BestEffort `
            -Check {
                param($KeyPath, $ValueName)
                Test-DevConfigRegistryValueAbsent -KeyPath $KeyPath -ValueName $ValueName
            } `
            -Apply {
                param($KeyPath, $ValueName)
                $path = Convert-DevConfigRegistryPath -KeyPath $KeyPath
                Remove-ItemProperty -LiteralPath $path -Name $ValueName -ErrorAction Stop
            } `
            -ArgumentList @($Setting.KeyPath, $Setting.ValueName)
    }

    if ($Reset) {
        $Setting = $Setting.Clone()
        $Setting.Name = "$($Setting.Name)Reset"
        $Setting.Description = "Reset $($Setting.ValueName)"
        $Setting.Value = $Setting.ResetValue
        $Setting.BestEffort = $true
    }

    $type = if ($Setting.ContainsKey('Type')) { $Setting.Type } else { 'DWord' }
    New-DevConfigStep -Name $Setting.Name -Description $Setting.Description `
        -BestEffort:([bool]$Setting['BestEffort']) `
        -Check {
            param($KeyPath, $ValueName, $Value)
            Test-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value
        } `
        -Apply {
            param($KeyPath, $ValueName, $Value, $Type)
            Set-DevConfigRegistryValue -KeyPath $KeyPath -ValueName $ValueName -Value $Value -Type $Type
        } `
        -ArgumentList @($Setting.KeyPath, $Setting.ValueName, $Setting.Value, $type)
}

# SIG # Begin signature block
# MIInJQYJKoZIhvcNAQcCoIInFjCCJxICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC4E+voOCd1738D
# j5VRqjO+Z9Jlr/r35JYU1MVHV6ZuAqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnBMIIZvQIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIBS6Kfw1CA6tCyplunoknArKn1JvOSQocZovv25Lej6cMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAB8kku7gIcVBnMjkk
# 7yRAxS8AKCzHBgdeZL4LkoIbzg2BIwoDWrf3BtZZudgEgSwNyuEUHXC1DeLI6drV
# 9/DPEpFZWgUmU7Ir99CJAKpPtriq4uJL4F+oOux7U9ooYIhIxTtaNTELln5opQc3
# cfQ7PvWLmCXE7AjLYb9oU49EVch8ChmbRX2yjAyxGbnKljdMsl/fHUDw+lvbCY2u
# wFb78I3q73oG2U+TQqaPm2dzUKN28IrfafsFaCxmCP6rB4MzvJld3YrjhhHst3i+
# Q/sK5v8EMJJCYSTgqJj4xR8Gl/h6K4/GuAwXvXWH19UN8q5GLImQY7D7Bcscdqwg
# 260y86GCF5EwgheNBgorBgEEAYI3AwMBMYIXfTCCF3kGCSqGSIb3DQEHAqCCF2ow
# ghdmAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFQBgsqhkiG9w0BCRABBKCCAT8EggE7
# MIIBNwIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCrEybqFeedr1RN
# 1ht4Khlz9uveAoR0JrGqs50IvkcaCwIGaqpMT40ZGBEyMDI2MTAwNzAwMjgxNi43
# WjAEgAIB9KCB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjM3MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR6TCCByAwggUIoAMCAQICEzMA
# AAIfOnBp5KIwLpUAAQAAAh8wDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwHhcNMjYwMjE5MTkzOTUxWhcNMjcwNTE3MTkzOTUxWjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjM3MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAyzvF
# xTnHxqgKoIs9PgJkJhZd3WdGkxuFBSZKqjXTB8tvA2oXggbOjjbn7pMnuceNglpM
# 4ESMvZBNlVsBJ7WfGZIMq8pAtGyKrCA+/uhcYLrHk139VcL5tQ/NdOFZnraASZSe
# Lhm7siWVL1w8eeZ1YedMoC082duFpELJz6b0Wb9pD3N/X924S8h1bZx7Gv1v/Ola
# 37XfgHxb3gPqjfxGPlxo+XPwzzFwmBAm9Gq2G/dnQyVrcM6cga6eIHx5YGNVBKXO
# JeABhC639ieMK8U801vkjPF4VdXTjj62Iw9PNCG2ai/AfiBdEQnZ9uvWF6xiukCB
# 4qc5ymXAkvIzd9GAB50yVTeWc7Orf9mLKgRg6rrw2ne/d+BRU8M71HDt1aCMnfd1
# 1sLz/P0ghVSYdtVvKBkE6bRh8pcvhZeIXp1TFWRdb+qLDrYq1/BhU4hIZ3/J0XTo
# O8mWACdMcvQrQ3212k5/3H9y6tzfxgmChYwvuZlAhPgCYZsTLjHb0lBpiogBXYjw
# I1E6rFlgQWSZtHgsIHhiRZpkAPle//fASnBPoFC+zvXlkQ0MCngHL6Oq8Tb9mOIy
# qxwOmf8It2v3ylISwjWREvKhna6QwJu6ofuhY2McrQG5IijOrkzcv1Cz5cLZWGaA
# CQw0D+3mAssMFWzU2x10QUkvjXHAtLEgeFu1Ou8CAwEAAaOCAUkwggFFMB0GA1Ud
# DgQWBBTZO9rBg5R9K+Q8L3xkeV8CSPAe2zAfBgNVHSMEGDAWgBSfpxVdAF5iXYP0
# 5dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIw
# MjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUt
# U3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB
# /wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOC
# AgEAZW7tyKMp5z89CtYj23jZ7Ho9m9eZebHZdhQBQQRk/ZUXXNoDVfCwCLrD2Bx4
# VL0Q3LMeJWzDYVSjxruEwy2qjbfwiPkhbRrqnUS6VT9VxPXAi8iqyj6XCRSQqj6V
# fnn6ALWAZiFEHMccE+1iEO4GoPPq5Cr6zJAqEaiktJir/CdbCn4vOfhtroWf9UbX
# klXWGTmTo/km+MM6J0wk4+xLYDDfwV9+VuXU83e8CXRnqWJFYvO9XUqwtk69WRcw
# Ee0uOHawlmaSeqYSWm1TTrDcRSSoEspLoDhls0N9fEa9zEz4NrNwZ7PqVD1YDIo3
# eG1Dh9gZRLCzDMDnKJU02aoNR2K3WNY8aVACPYqYwUESDS/zu9OWfv39i4zZiUKK
# AlSVV9uGnaWedfUrH2sxqKlxrfdW5qiqNHyNPSJeLFB4eIoeq6YkAwZci+75rwno
# 8FcWHr2OKlcE2f6N4L5fkdJRcWEvX3iDODXhtPlrA2e4y3IuTBXrjcKLEGN89ul4
# NaI9FPbvp3Efbk1PsQZifAbZQnYUNd0TTF+T/pK0WDwd1wqfSZul2jtffeat9gCG
# ZtZswRiOsh5b4l2hAuU8xojtS17j7V2VNl/d6ECWzKHt7/PuQjyq0GpRlsmLodmt
# 1dacG4/ltBRJhBT6bvEyPqmDtSCEFlEkbxY17YeTm9NoTDIwggdxMIIFWaADAgEC
# AhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQg
# Um9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVa
# Fw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7V
# gtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeF
# RiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3X
# D9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoP
# z130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+
# tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5Jas
# AUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/b
# fV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuv
# XsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg
# 8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzF
# a/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqP
# nhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEw
# IwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSf
# pxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBB
# MD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0Rv
# Y3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGC
# NxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8w
# HwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmg
# R4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWlj
# Um9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEF
# BQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29D
# ZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEs
# H2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHk
# wo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinL
# btg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCg
# vxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsId
# w2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2
# zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23K
# jgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beu
# yOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/
# tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjm
# jJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBj
# U02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDTDCCAjQCAQEwgfmhgdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjozNzAzLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaIjCgEBMAcGBSsOAwIaAxUASyDINT+7Dbgl6Zmx9iF09rV3hBCg
# gYMwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYw
# JAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0B
# AQsFAAIFAO5vzkUwIhgPMjAyNjEwMDYxOTQ1MDlaGA8yMDI2MTAwNzE5NDUwOVow
# czA5BgorBgEEAYRZCgQBMSswKTAKAgUA7m/ORQIBADAGAgEAAgFRMAcCAQACAixf
# MAoCBQDucR/FAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAI
# AgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAAZ/au02Vh1p
# OTKjWMYIqFBj2h9L/N2tfSiIdo5Xf/rCd6DAufxclrZ/JK/ul+CHtjAouzGKhQ08
# ICSjmQNyMBqbEt4EUyyeZ69lIZaIy7+PRw8An6pqkcuoy8LDnBtQffMTwGiSwQ9i
# mwL2AYwPsY+r3qnbo6PNPynegOajr44MfOvgx+rgJ1mANOC6mb+Gh6BsLD5bc6Ur
# tJxQS4Mvlh6EkVDTUHFmK+EUE/cqHJG5Fbxhg+3XCsROLoOHiCbeZZmwUaJrYGbr
# nU7ZpKc2fjHIZO0Rq0QtWOQ8vZEbZDq9p0QtOQZYW997/hureVC/nb5SaSEtzj6y
# G/GwO45PJskxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMAITMwAAAh86cGnkojAulQABAAACHzANBglghkgBZQMEAgEFAKCCAUowGgYJ
# KoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCB9vc8WLZfZ
# SjmWndWACo+cjGBRh5WSVbqpi2YiJ6H5LzCB+gYLKoZIhvcNAQkQAi8xgeowgecw
# geQwgb0EILAkCt9WkCsMtURkFu6TY0P3UXdRnCiYuPZhe3ykLfwUMIGYMIGApH4w
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIfOnBp5KIwLpUAAQAA
# Ah8wIgQgdXcVI5vvSVDXstD2V5qnrTIrnK9BiKVpJ0RAhXg/k2MwDQYJKoZIhvcN
# AQELBQAEggIAN2FujU7wUSN/NtII8PAGP6mBIHPjdjgD17+u6HJHzPsqSZD3tVit
# +N0j/FyxOf0muKYZqxdXRw3+dFgzPdTm1QlTn1IXn0iMY6L8bdxyZejmGaImg0E1
# LPoJ9KiSFIDkqfeQI87m3EmUKFw3EhKB6ihtoYvsTU02qW5vz9IIPsGR22YE3wb2
# 0W7CFNje0kVYtSaoBSdU1Jr1FyCS+aUro7mcvnMgRToSVaGJYRSVV6kPmynpxaFO
# bWV4u2ewmzVRkPFZXp0qXkftPmDF9PnkXKbjDznt6lrNg45BsrP0foqOUrm61Q0O
# Sna2z/ydSK9grt729LRA42PtqrwkKLAIDp0NUgupjM9RKXdVJiv72PcHn47c7Q7u
# stY4rHPkYcsELym2HgaKPIW1blNCyurpNbCsTd3uDHzBpoRs2F+bi82YoVb81bkf
# zlBgNUkqYIewyy7WL4y9I/Co2nISETl02iukN8nBxCS3no6WbTwByaAhE3MKp6x1
# +TkPxrsY8TIapt2RK5UtgymgfdS3JMbAos561rrAP/yW5D9dFm0SBqgRm9oL48Jx
# lcuWG4wk3muZd2a9lnJjiJcnO9VQRaF4cGtAIoeIcyUSX/LT2yAR3DbI/UGAndoW
# 6vO0rXED2/lFBEF6xl/AXiI1MDy5TwfL64biEgKY5nHJ8XNtjC+V/PA=
# SIG # End signature block
