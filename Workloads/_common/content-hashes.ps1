$Script:DevConfigWorkloadContentHashes = @{
    'cuda\smoke.cu' = '6252383bda8856daa14c4f315961e17d4de3bdba1cba6bf4c09a5d0aa52a2a6f'
    'dotnet\configuration.winget' = 'cba2c6873cee7eff241b6d7698d773f8575cfc60a6e9d7dbb8986f4ecea5c048'
    'go\configuration.winget' = '552e6fe17baa47df8d1f429735cdd718bdb61b052a86cc47e8f8c6c2cd22232c'
    'intel-ai\openvino-smoke.py' = '0b71b5f5351dd7536c6352dc02ffd523fa89f2fa60a23ff27d45fd3e8f9c1326'
    'intel-ai\sycl-smoke.cpp' = '6ed0361d8374bcae060b84469b3b167738f016abc9f3b46ba5f19ad870bd74b7'
    'java\configuration.winget' = 'f36edd7ca81b9389ba490505892d6ca5068d5942a249a98f3997356300b8447e'
    'php\configuration.winget' = '34e040193202a8cb0e4cadcefaf5bd678e9fb775bf5ad428d94c78f326604c06'
    'powershell\configuration.winget' = 'b86d0cc7dea26309a14478e5a94304dc9b037fe32220bdc83da8318ed60e220d'
    'python\configuration.winget' = 'bfec7eaad24ba3c5913e7713dafef31d6ac62c53005cc3fb6688db33dbf66f13'
    'pytorch\smoke.py' = 'f28b8ca06e0a2832684f1342626c74904c13d575ce96282f86cf66f44d3eba68'
    'pytorch\triton-smoke.py' = 'a2d2a538b1b30315f249753ccad68d6977bf85d711e3e3541c52ae16268814f4'
    'pytorch\xpu-smoke.py' = '7cba1b04e7ecbce0c24a9188ff847cd3c2fd9792810b5fd4324728ad21786c50'
    'rocm\hip-smoke.cpp' = 'ece1ed905b3afc7ceb918cc3ff751d624b8d681444b1c507a74cfef3d326034d'
    'rust\configuration.winget' = 'ea58a4b6dfe1aedcc1af4674b69dd376609c67140ee6a60dba0060edb266c701'
    'sql\configuration.winget' = '99472e573c10316a17be12d45da834e22be4b1b774afc5c15fdefe3d63bb98e7'
    'typescript\configuration.winget' = '826e1755d85798e376baa00a9891c58fd2dd6da67d0f54486ad957202ee7c8b1'
    'winappcli\configuration.winget' = 'd61b53240fbdef910ea7a92250add1793ae599f57217c83052bd6aed490ead4c'
    'winforms\configuration.winget' = '39de8aee958e1e4989fd5b484a45a36537a7f8cb72dc966fa3afa4d0e8b9e34f'
}

function Get-DevConfigCanonicalWorkloadHash {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $stream = [IO.MemoryStream]::new()
    try {
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            if ($bytes[$index] -eq 13 -and
                $index + 1 -lt $bytes.Length -and
                $bytes[$index + 1] -eq 10) {
                $stream.WriteByte(10)
                $index++
            } else {
                $stream.WriteByte($bytes[$index])
            }
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream.ToArray()))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-DevConfigWorkloadContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkloadsRoot)

    $root = (Get-Item -LiteralPath $WorkloadsRoot -Force).FullName.TrimEnd('\')
    $actualFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Extension -notin @('.ps1', '.psd1') })
    $actualPaths = @($actualFiles | ForEach-Object {
        $_.FullName.Substring($root.Length).TrimStart([char]'\')
    })

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Script:DevConfigWorkloadContentHashes.GetEnumerator()) {
        $path = Join-Path $root $entry.Key
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$failures.Add("$($entry.Key) [missing]")
            continue
        }
        $actualHash = Get-DevConfigCanonicalWorkloadHash -Path $path
        if ($actualHash -ne $entry.Value) {
            [void]$failures.Add("$($entry.Key) [SHA-256 mismatch]")
        }
    }
    foreach ($path in $actualPaths) {
        if (-not $Script:DevConfigWorkloadContentHashes.ContainsKey($path)) {
            [void]$failures.Add("$path [not declared by signed content manifest]")
        }
    }

    if ($failures.Count -gt 0) {
        throw "The Workloads content manifest failed verification: $($failures -join '; ')"
    }
    Write-Host "  Verified $($actualFiles.Count) non-PowerShell workload files." -ForegroundColor DarkGray
}

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDV+ZrZN5gMFxQc
# Chnt6uSP4ZGVZzqyeta9mE9beAN/xqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEICu9TE7h8j9MwDlGF9Tw4DJqDxPVvfyuKP1pLYJ2zMs4MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAnd087TaeSToegv5f
# e9vF5r4cXNPlS7oaX+6k0PhgbIXrk6WiVVvKX2iaWYfFcSZb+LcPauua8KkqOYXM
# ntnXt9UftGv55DhWIW/R42yKfZj2ahfQ1wyS/a7B+g4+MyY82dHxlar3ClvypHsR
# +Kdu4y6fNuNnFzwbVPo726Sy/nWX3t4Hq/BawbfzEC+EtE78a+GVG8VsI/J6WvYI
# A+INTn6kR1CqWgO0ipL9/loekVNhdiR1164Z4NiffNpoVd+hsUEfe+sd66WivYwG
# tBpKzQOvUdXxTWvXDvSpi0mxCLDB5HMxwoY7vi9IGPTSCyyPc4c0nKHfzPTDvjPt
# nO9+LaGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAoEk8dRp3iivKC
# Bj/rPpX58ePi1D4o9KsCbvjx9jbXYAIGaqoul8WMGBMyMDI2MTAwODAzMDI1NS44
# NTdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODkwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
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
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjg5MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQC7ycXVZx3bsDpJkr7Vucgpksoz
# uKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nEBzDAiGA8yMDI2MTAwNzE3MzcxNloYDzIwMjYxMDA4MTczNzE2
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDucQHMAgEAMAoCAQACAgLxAgH/MAcC
# AQACAhNaMAoCBQDuclNMAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBABs4
# rEN8pg4dP3qjXs7pVUoTtSn8g/EgWGyjfTz89PBvZ3Mm2x12GilzJVB/n7prD969
# eGzdr0Lnusvey+REVZGwFiXwRf1mz4p5IL/a6X+UsNYuaXCk5bLuHVuQ3Npx6k9S
# GjJmc4uIcFagArFrs/1gZGMY5ekAyfp3UVD5D+kTvY7sGo3lwFvCurW5dKXqk2z/
# ZpMOvcuNlJv0fOM4ioCA/Qi1Rf0aId3ZwUizhX6EY0iHMpEI+yqOKmnjmdULIQqO
# 18R61msa5ygHUu5lk1atZlnxffbPuBvZ/Q4snF3LkDjjEwOgMSkJwsRDUip2Fejb
# 7LiXOqEu1HSWuHF33vUxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAiJB0vaq/8i1/wABAAACIjANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDP
# XLqkSciaqGR6NtceCdGDW+aHOb+4Ut4f9d/30JnKvjCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIAVgXQEKBOfGgjNskmDOmbcEIOnHGNwA+QcRufDR5AkTMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIiQdL2qv/I
# tf8AAQAAAiIwIgQgHBt4ycVgFXnGWxr5tOjNGcc7nkfKzETjnTiFKLwfz4AwDQYJ
# KoZIhvcNAQELBQAEggIAktpDi0ZY2oqsKt+G8jp29rm1V4xTTSmtPCvLdUGqmrbH
# vPvZPFGOlGx1fIrRYsKy70p3tB80x8LtE4jiEwrw5Hhz4RiPgRPBeKtconEOgoGf
# X8QpCIBlZzR3uqfHosJf0oEJnczInJH/XMktq31/3xJYBdmX3A/Pq1lqmyEIsfr4
# cimgjEfWRWsplNjEc2dYQscKu6Qfukf4RMluxUDOxhKLA0JCmbdF+1f3gSR0H3yw
# +3u4v3ndG3bQtaYu1AMNA9vzGlWt/fkSmj+5Eay92sKf1ipWFjThE7Oruzn1D6M4
# nD/vfU1NLO1Y/TcSDYK31CMYtZEiy1u7qE4Peu3Qc+pfNbk/DzkhPnxZCkcMol0H
# U78uIsXf9Mxf4+Ino/1rZDOc47ioXdr8gWywQvLIiCmqvtOmzkUjAz1HoD1/GGNs
# 4ps578O9izu4ZBMD05N6kFUsWbyCIVikffG3UH2CRZ0cnnXoaGXtj0OLKrCB2aSH
# jh88RAiclvPsMaQxIfHjAFGZJxJIanAKwH9wemtxT17HZvTzytlsCV0I7iUZl+1N
# vkNHiJBmKUcwf/fMxt2nB2jYR1OHGvBGii64fT+9CP/LdErozMl2rL9CZLenUEBo
# VJUJdpBakhR3qcr/EP1oLjl5jaItgryXGg2tqLFq5ttEfqQrpSnt4jNh9E+wuoc=
# SIG # End signature block
