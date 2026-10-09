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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
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
# 260y86GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCrEybqFeedr1RN
# 1ht4Khlz9uveAoR0JrGqs50IvkcaCwIGaqmBecEWGBMyMDI2MTAwOTIxNDQ1NC45
# NjZaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiu7AFD/TTuaoQABAAACKzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMTFaFw0yNzA1MTcxOTQwMTFa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCX
# 3mi6OD3syUqQm4QqgkrKPbcsK/Qx3fYctL8+VM1uOY3booi5GxwauTgQf6JFHITT
# oxS7gjqKlK8OFLzL6UTl0jxEK5t6DuOcgJXdvutimoTlOS0C3kyITXBAXoj/gp6h
# RR9z6WRip1Ktkilb3dJXCjQqT9P2Cuujr+Vz8r+Z+jDl09ji/ic/4G34r3mVwjs/
# /Gnx9Pu31V8rXFicNiAzxpubawpbd8pqfzlWT2vnG3kF9l6MiREbvJ3XHLUwHQsh
# 0t/TrSFx/s/yCqpJWYJ6oClG70tvsFH0aRP8wB4cP/CFa2ILvk26i3OcJBl+pqKj
# HTSBy9mvwTPEDlnzco0Nt8R6pSPTXZgBsscHhoKfC0WQmOzY2keXbAmRTcZMyXz5
# v/AJbmoI0y07Bazvt5NkXddG9TErQWwtsFyIKrElDgWfHeCoTu1wu2ciD3dK72z3
# ca2gzoEDxT2j9BXIUKaiTzTdQPRsAMaO3dU0zaGwMMlwtSJyDh14YEgZoUu5vS8M
# ugMqdrNjphyL65yKhjpAWbhYkIHO/0uZju95tP8zZNqXIRh4tdfWHJPATn9r+cxk
# yuh2x0VLdfx1lmK9X3NjH0NtgAs5JB/wOlkyuudxmFTfWVyRrL37ispOZ8aPAFgv
# yR6cNTkGpkFo35JRjciNmZiU4qT9Uty+V5gudFk1jwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFD4WjuQTUJbtbd3jmvZku0FZ2eU2MB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQDO/CKsciEM8kr1fqH4TlfT66ENoTjxXw810pyEq0PdrgLwfgT3x+1gz7CQ
# HtUdevqMQ5qHyDLhm6pT911CYkGN+6g+MU7fMYTr6d3SxieJwBIoWkfR4g7SitGz
# MKU465KEYejfddoUgovC/xcRpaALO5p3/A248ByhJiMttBQNDtsT/HaCFwRFCURb
# y/f8c1kky8F8xkCXFz+/MtZ5d1lWFjwOI2geZHWq9XihDOgee5nS2koo5V6n8XG2
# 20UTevVf+pgmpIH71XKDVIYTGGZJs6yPlfJ2aXqw1ME4NR6okNsY3P1M31H6DMYR
# fJGNBNep595kXGh3YzA3cCiyg+jmJ58h/fTvjngIpuUFfODpDjFx0ic1YoLANxhC
# F3RhS9qYM7K40NEhKshYuaAkIG2XBKYig3r/0/b0sjvjBws55AYonMm3A8qcX/6k
# 9Vfc0mv9dtonHuWGfA2b+qE2qpCnhzGbdDHq7iOSZEw01nNupAMf1c41k9IoTQ2z
# 3iw6w4ZZoLOyg4TKMbp1krpT4trip/y30Cv5khyqCDNqaXQpBkOYON8LgtoQ3amV
# OX7ix5jdrnx/vUxTUSigXvrWdL7Uk8kpmS0zto2Toy7aT5oBzCTvfj9iJ/BN/E1v
# hFBkhJCvZ7PVvsMSnTTmkx2Fal2lVkztuAI44fD/uyLJdaMQSzCCB3EwggVZoAMC
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
# U1MgRVNOOkEwMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAJrD90ykHpo/0AGb7lmwvsCtqR
# OaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nOf8zAiGA8yMDI2MTAwOTE3MTYzNVoYDzIwMjYxMDEwMTcxNjM1
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuc5/zAgEAMAcCAQACAgKsMAcCAQAC
# AhMEMAoCBQDudPFzAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAB0MsV1o
# DoBLqKNHQIn9wlxMEWuJHoi1aFFYApAKK6c/5uXpfvg/6hg0F/6Ce1nB27DC5lln
# lxyeN59be+H1i6v93aLZvsK0DWiK+p3tQV1Kk3Q1dGgdgUKGCgixsijOYbVzQ8ac
# z7Mg7KdWY0YuoZzb2kv+RYvYQ1ZF+gUlScIyvxcuTth5XDcLafBQVznT/ADVcmLq
# s8GZLGUFTPckAEfd2QIApYWvgB2bHSDVU3K3tcHafaWkphcJzmxBnhA1IcEQbpbd
# B4Q5GVOVMlnuFjwmxG55p8cPz6r63QNVfgeAVTHriunqg/vRrcQg3nmT7oNaA2Ir
# qIEZ+GSfuCa8hgsxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiu7AFD/TTuaoQABAAACKzANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCABRhKL
# 43uLhRozHLeD7bRvl7zpox6x4eR2GyxU9i9PbjCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIHIOI/Q/kFftYA+M2OY+1Bx3ajBD6/WDAtPT2vFkv25SMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIruwBQ/007mqEA
# AQAAAiswIgQg4bKkOIQ/VgByEtzsHEXkZWBlg3apCLvAGoGTdbgutcgwDQYJKoZI
# hvcNAQELBQAEggIATgptOtuKnFGgJPshi6jPW+EXzsnHFS2cpP62z7FToOCggKlr
# 2ozEH0ncuM0JdKxjp8KuCVbW7xV+iFs/oK0iNt9jsX98iwtolIwEEcsnzoKwW8wK
# zdnhu1Mw/TS26y99Nxktyj4tWDsdSM6q5GDMPm3THNVgVT279qr+phhDBBwcSQfd
# tudtPX3MV1i7xowA6z8O1Hj68YIPzRKUk0orThwyG/FAA5pTDs6iIxcIeGsPxDcW
# MipFZ3aB8lbkYASw4GakWStl/N1h/SnXkn2eI32f0JUP/uB7Yr1P2SZsul0QecLk
# 0ClkokzUMV5/h95NXPm9YeIzL3OqwxNTTqmxJhUhapECSpB8Nez2HF+oEC2DaZmC
# Uy+jITjx/ooeIepgkGd72FaLDhCExM2lY2uR70dAoPeoNPM/46ZAyCEeegFGXRz4
# lyh2dRBh/rOCaMtbbV0Oc6wf9QAre0zQPV4/olJrFaqisZTLZxL4h3Dbc7DtHGN0
# OTycpTDmwMNb46SPNcfeHF0ByE9dcNxt4qAlMUUrWx+ownp+tp2JGIJ2WIxvmAvI
# G/WOe1bVsmFw57ItDww+zpMINlGZIjMQWGujCM4gHuKGT1XV2k0rpIYRVdf25kVi
# jfcBOmTQTkeUlNH4dlJ7WMIO/J7WPXm9gZ5StFECOyDbQNkQIb5Pkgq143A=
# SIG # End signature block
