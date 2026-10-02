<#
.SYNOPSIS
  Retries a script block with exponential backoff for transient failures.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-DevConfigRetry {
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $Name = 'operation',
        [int] $MaxAttempts = 3,
        [int] $InitialDelaySeconds = 5
    )
    $attempt = 0
    $delay = $InitialDelaySeconds
    while ($true) {
        $attempt++
        try {
            & $ScriptBlock
            return
        } catch {
            # Timeout exceptions already consumed their allowance, so callers handle the fallback path.
            if ($_.Exception -is [System.TimeoutException]) {
                throw
            }
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            # Write-Warning becomes redirected stderr after reboot and would appear after the retry.
            Write-Host "  ... $Name didn't take on attempt $attempt ($($_.Exception.Message)). Trying again in ${delay}s." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
    }
}

# Bootstrap carries this self-contained helper too, before shared files are available.
function Invoke-DevConfigWebRequest {
    param(
        [Parameter(Mandatory)] [hashtable] $Parameters
    )

    $waited = 0.0
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            return Invoke-WebRequest @Parameters -UseBasicParsing -ErrorAction Stop
        } catch {
            $response = $null
            $networkFailure = $false
            for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                if ($exception -is [Security.Authentication.AuthenticationException]) { throw }
                if ($exception.PSObject.Properties['Response'] -and $null -ne $exception.Response) {
                    $response = $exception.Response
                }
                if ($exception -is [Net.WebException]) {
                    $networkFailure = $exception.Status.ToString() -in @(
                        'Timeout', 'ConnectFailure', 'ConnectionClosed', 'KeepAliveFailure',
                        'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ReceiveFailure', 'SendFailure'
                    )
                } elseif ($exception.GetType().FullName -in @(
                    'System.Net.Http.HttpRequestException', 'System.Net.Http.HttpIOException',
                    'System.Threading.Tasks.TaskCanceledException', 'System.TimeoutException'
                )) {
                    $networkFailure = $true
                }
            }
            $status = if ($null -ne $response) { [int]$response.StatusCode } else { 0 }
            if ($attempt -eq 4 -or
                ($status -ne 0 -and $status -notin @(408, 429, 500, 502, 503, 504)) -or
                ($status -eq 0 -and -not $networkFailure)) {
                throw
            }

            $retryAfter = $null
            if ($null -ne $response) {
                if ($response.Headers -is [Net.WebHeaderCollection]) {
                    $retryAfter = $response.Headers['Retry-After']
                } elseif ($response.Headers.Contains('Retry-After')) {
                    $retryAfter = @($response.Headers.GetValues('Retry-After'))[0]
                }
            }
            $serverDelay = 0.0
            $date = [DateTimeOffset]::MinValue
            if ($retryAfter -match '^\d+$') {
                if (-not [double]::TryParse($retryAfter, [Globalization.NumberStyles]::None,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$serverDelay)) { throw }
            } elseif ($retryAfter -and [DateTimeOffset]::TryParse($retryAfter,
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
                $serverDelay = [Math]::Max(0, [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds))
            } elseif ($retryAfter) {
                Write-Verbose 'Ignoring an invalid Retry-After header.'
            }

            $backoff = 5 * [Math]::Pow(2, $attempt - 1)
            $delay = [Math]::Max($backoff, $serverDelay)
            $remaining = 120 - $waited
            if ($delay -gt $remaining) {
                Write-Host '  Download retry wait exceeds the remaining two-minute budget.' -ForegroundColor DarkYellow
                throw
            }
            $jitterMilliseconds = [int][Math]::Floor([Math]::Min($backoff, $remaining - $delay) * 1000)
            $milliseconds = [int]($delay * 1000) + (Get-Random -Minimum 0 -Maximum ($jitterMilliseconds + 1))
            Write-Host "  Download attempt $attempt failed; retrying in $([Math]::Round($milliseconds / 1000, 1))s." -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds $milliseconds
            $waited += $milliseconds / 1000
        }
    }
}

# SIG # Begin signature block
# MIInJwYJKoZIhvcNAQcCoIInGDCCJxQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDbwwmPsp1LW6l8
# fCnNvmostC0td4avQuVCG96AiHdzTaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIKXgcy6kadZ2+duECV2N7DBa14jUxsyBzm9I/xsmc7nEMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAMY38doZqq20MccgA
# e6aq0+eetloaQCLgppqhygm2COv2OGj9GSqMzwZa8ZbbgO3+AgOK7zJsUuq0T6Ad
# ZT0jH9uD15J6Uj2jsYBXs106F1RP2mpzKotUVnRS2IFhmYIQqq1C8C4mXpINVFju
# g/ufj7N5mqPGt/8rQlgIQjLsthMz0kwme4J2lKaMDiJTvFPN/U+oY4iTLeEcqqgU
# p8dK7xp0YcfJ2KtAYrtKfvl+O/wQw0qvkGhcUznoUsWiN6UMBELWF4VmJ+buMDEu
# MzDKXZfOUpqlmzQpr68ElfMRsJy9MbHlVLkf0sEcz5coleWLQ+mRViWAGyoDMUsA
# ENqC0KGCF5MwghePBgorBgEEAYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2ww
# ghdoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8
# MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCD+FC1JF3cHGKPr
# oHZO5dNOrbBzHUPfdnhWYb5BuUipOgIGaqpov3cbGBIyMDI2MTAwMjAwMTU0MC42
# NVowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
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
# AQELBQACBQDuaVQGMCIYDzIwMjYxMDAxMjE0OTU4WhgPMjAyNjEwMDIyMTQ5NTha
# MHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO5pVAYCAQAwBwIBAAICJ8swBwIBAAIC
# FAwwCgIFAO5qpYYCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAK
# MAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAN9YrwUk0
# UIci61zBo1OKqd8ohZPuDDsh7nTc0ZLs87dzuaghGQucNR2FFcc1Q91lmTWjvUPh
# 5L1quNEyu/h0S5YgumdNy2fQWR0XSV9tt0T3Fo76miSwTupSHsVVEfMVJRIjAfvp
# NyIRoe8hNqXafp/7pXikbO8OYzhKFuqJex75dWhI3WJAQWPo/cMhyl6D2ieNbF10
# YDIMP8dYhx/yTLiGcl76GdewWrunfcPT6HkI74HpotDIvr8ouyIG0V7/dJ/2SAYJ
# SiQaVIwbA36izDSgmgYhoKXVQsKcnjqsVzrVjssTtkyCrQKX6Jo6Av5TlQe/zrCo
# u31EmeZvTJ4kKDGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACJjW0PmdDk/YfAAEAAAImMA0GCWCGSAFlAwQCAQUAoIIBSjAa
# BgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIKwbUhzc
# vBDBbJFIU9HwGK6u8smdXdxLzi8gc2ePfbavMIH6BgsqhkiG9w0BCRACLzGB6jCB
# 5zCB5DCBvQQgzDJcYWdM2xlEGuzoY38FtXSiRo0/dUFiosWNSwWduCowgZgwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiY1tD5nQ5P2HwAB
# AAACJjAiBCBk9rb4GIcnfY7hc1sD0ufhjzFftQFzcZCZnnkGkouocjANBgkqhkiG
# 9w0BAQsFAASCAgAh4c3FlTDf80vWZuyz5208iWOKHgoAAYkUCbe1J23siohbQmMQ
# jy4bZLrOstt5eN6t9IX57cKpjnsu9Vp0FmzTMHLf8xhj/1wYdOLffuilOOf568TW
# zgfv8YOygnz+6EoXX5+ZIdagiAqRNvToevMFPJlxoCZGyRqm19Ho9q2p9d30dNDP
# R7hs7x1dQII/6KuE34MemWc8lDKwA5xlmvoRQHhW+H8M5Q92vDEciT/Ote5VGcnW
# Y9kZJy07T5IkML3Bc/rjvwpi2Cn7HHFjmgw6SKjAG5bjHZz912fRhQIFtbVDdSyz
# uvGoSrf2omB4Kcd8ItDGsucxWG8exAsUaby2imPjZwxf0lV75/Ip7c9sBN+1OaVI
# dPUwLxQ/GKe0YPjvQjqRxq/iIIDNWsT9J8tqYlrgn/Lb9O/KMeXaoaZj3vXIFVeG
# WajMvywHZwAr0/bpDA1Uu7cD4lQCLSKrmBwRx1dehOHjieSaiS+9Hq0eJFCZ+uGZ
# z89mDHR2PXzkBcqNyvMDfW4DkBb/2B7B803mJmDYAr91o+suT2rjPzCRidLsDK9F
# PhA92k52bDwAKAag7giw2+bCDQvCtJZXEBSrEQq1v9gIDUvvot0FaYR2atTpUhjq
# qZlNLUO48NoVKmSyYrZBlpgzCDyXT2bZ4fJJRoGA+jW+VmiFvxefj1X5yg==
# SIG # End signature block
