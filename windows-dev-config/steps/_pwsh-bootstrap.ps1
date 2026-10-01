<#
.SYNOPSIS
  Selects the PowerShell host for setup or cleanup.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-DevConfigHasPwsh {
    [bool](Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue)
}

# PATH is checked directly because WinGet read cmdlets are not used during bootstrap.
function Install-DevConfigPwshBootstrap {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            # The timeout keeps early bootstrap visible if winget waits without producing output.
            Invoke-DevConfigProcess -FilePath 'winget.exe' -NoNewWindow -TimeoutSeconds 600 -Arguments @(
                'install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
            ) | Out-Null
        } catch {
            Write-Verbose "winget install Microsoft.PowerShell attempt ${attempt}: $($_.Exception.Message)"
        }
        Update-DevConfigSessionPath
        if (Test-DevConfigHasPwsh) {
            return
        }
        Start-Sleep -Seconds 5
    }
}

function Invoke-DevConfigEnsurePwsh {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $Resumed,
        [switch] $AllowUnsigned,
        [ValidateSet('Full', 'Partial', 'Uninstall')] [string] $Action = 'Full',
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return
    }

    if (-not (Test-DevConfigHasPwsh)) {
        Write-Host ''
        Write-Host 'Installing PowerShell 7 first -- WinGet is more reliable on it than on Windows PowerShell.' -ForegroundColor Yellow
        Write-Host '(One-time. Takes about a minute.)' -ForegroundColor DarkGray
        Install-DevConfigPwshBootstrap
    }

    if (-not (Test-DevConfigHasPwsh)) {
        Write-Host 'Could not install PowerShell 7 -- carrying on with Windows PowerShell.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Switching this setup over to PowerShell 7...' -ForegroundColor DarkCyan
    $relaunchArgs = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -Resumed:$Resumed -AllowUnsigned:$AllowUnsigned -Action $Action -Workload $Workload
    $proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList $relaunchArgs -Wait -NoNewWindow -PassThru

    # The relaunch performs the setup work, so this Windows PowerShell process exits with its code.
    exit $proc.ExitCode
}

function Invoke-DevConfigEnsureCleanupShell {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [switch] $AllowUnsigned,
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig'
    )
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return
    }

    # Cleanup needs the Appx cmdlets and removes PowerShell 7 itself.
    Write-Host 'Switching cleanup to Windows PowerShell...' -ForegroundColor DarkCyan
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-DevConfigRelaunchArguments -ScriptPath $ScriptPath -AllowUnsigned:$AllowUnsigned -Action Uninstall -Workload $Workload
    $proc = Start-Process -FilePath $shell -ArgumentList $arguments -Wait -PassThru
    exit $proc.ExitCode
}

# SIG # Begin signature block
# MIInKgYJKoZIhvcNAQcCoIInGzCCJxcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDYkrqf90ifrdIM
# BH15nQi9OUG0HwUmt0bYbENUTZSVcaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnGMIIZwgIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEICS37Neh5GNLbED5R6iz6WVaMe9kt84E2PDzl34rDvAuMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEA0GV5xVUEIyVE50Dt
# YUSuv4OexdWX6/XouLwhFizW9b3+ktcrNsN5Tm+UN3em2iDGRmdOh5kJhCd9d9kW
# Jn00yOh4dc320avyzYXujrbaTG/w9VO+Y9JZZrX5EZBLGMyQMhuQ25gYPJ2J4pgx
# ccVbXa2//o/1iVBOhDDningontnxm2NYw8b2U/SALjShyo0GpwJwwer4/CDQ+wns
# CdEKC0uLpPE7rRtlxBYrKKkej/gcFLY0AWZnK1f/DAIIu5VeI6TTXdREk39/Rgyr
# X3TZiDLcsQAaxg/6hVp1oxEbzVs1tFbu33SKVyp+xatj3Kxn3tlIORmcD2pEco31
# jJk4hKGCF5YwgheSBgorBgEEAYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28w
# ghdrAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8
# MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBo5bHBOXnj0qVK
# qPf06TarFhjGfTCHWmFgkdfeAWwvzAIGaqqKc3yZGBIyMDI2MTAwMTA0NTIyMC43
# M1owBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjpGMDAyLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMz
# AAACICTh5uAXubSOAAEAAAIgMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5Mzk1MloXDTI3MDUxNzE5Mzk1Mlow
# gcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsT
# HE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjpGMDAyLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANFh
# jvKvuKNboJHXvy4q94gy5+61Y6JzGAnAo5x7/YY5Bx66zplZ9fXiLeM2Dck4/swY
# kyQ4C5zBYHCIDxRGn5liQaOlWhWQZmxXbtaOovCl/YDCoGwn9POrATskUVrG6nct
# 3GPwaN0nKYMVGt1U3+lgegEWuMPUiQgO7xvUJafy2CiaIpFJj5JO8mr32ZWR2mEw
# EhQY56BCfLypF3bhUwTTGLw6iaSz1mr0SMN4ocam8BtdQRDqbdxE6gQ+FMT+aLB5
# Af1Oom3cg6yo+/cvy6uiMHvjtcELbLQIMgeUotwuXdkbwPslcqdZMV6feaww8mly
# +tDfNQFUmsf+YjdHEeYKH2mkM/S4bX48nCTof/H6x+gb2FbrjGheSnHoMR81k19x
# d0ptcXbxcRd0s2fOjdIs1XKZ5AmE2o5IqGdTzhCcqauMSTnjUmK6uUMKQJY72VQF
# Qxv3HSfJ9dRs1E9UuA/49MxF1c6jAl1gLMJB83ZmovSzhgjbwXUNufsGDDYTg/UT
# 26ey8zMke3OFLZOHdOkJ8Fs4ZqUiUX3H8Mln+yyb/LLNP1i0gV6qZ83EE9MTdo66
# HofGZMgLN9gABO9Y2EFujX1DCyM94D0m+GpMsLYpQ2CteugbLh4NmjSfuMViNmRS
# KHVPL7wTqoS9XY1rpnmBTIPlr60cYOarr0KZSId/AgMBAAGjggFJMIIBRTAdBgNV
# HQ4EFgQU28ic4IiHEYDyZjuXWDTtQe/I2DMwHwYDVR0jBBgwFoAUn6cVXQBeYl2D
# 9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUy
# MDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUB
# Af8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQAD
# ggIBAK0oYG2jUFK+bhYUj4nQ1LJWFTUscvsXd9uNnZ3sXkqf8UJMFlenOsNWXrcU
# tE1wgWmcnLj+eWDjevtPmwk92jgyzwANIdAQmcdK7fH1SmMLNEQE+L36ceG8OBHH
# /VaYEPqBBRkks6Fw3ZPFbgonKGKcy2IEW2Q1Fna+ZnUwB01dObl3QvCTfDOP79/t
# UIJNYJclKio1rdVT/qwAIcj3sS9ufODxt3eHGt/PoJwJW5/vt6C9EeKe2Em7BJF4
# 8/tpWZx69vWdZQgAgJ0F5sdA6vM0h5YEhDC9wVpLdIVz7j2uqvBA4wUNHgVgHNLt
# vRB4FXEW4svaJW7goAcw1SEstIPiIosMUE1M61PNOWEa8yAbvsDVyN5CsMwdrqhF
# 4wN5QOodSvG/yDshF0iH6HSAMuTM3TEi7OWLQG/sm3JsYltXonFoMXgLNIIgxGkr
# n2cjqIqjguCdtAFklbv7pqRiwob+lc+V/E2/YiekPXS1IKQK/D2SvpbX41E34S5l
# zNGADBaVwr1clne67+/+jEe07v+SZUiznUX2pXpjZA1d3q1Tjpg+sr3ybZAPKz6W
# 8s2KYrR7XFntnUZrAqiEoa+UsAtYOVlCqAd8nfUIHQuUgMjuIvJhOl3aLIqOqyRt
# CLIy0gIf5GYf+gKDsk4rRkDdcgxtr1pJaAEXdBnqkbcQZ5CqMIIHcTCCBVmgAwIB
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
# Y1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA1AwggI4AgEBMIH5oYHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAJMYD2+mwnqCWoIuYjSuCAbHhgQS
# oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcN
# AQELBQACBQDuaCRcMCIYDzIwMjYxMDAxMDAxNDIwWhgPMjAyNjEwMDIwMDE0MjBa
# MHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAO5oJFwCAQAwCgIBAAICCxcCAf8wBwIB
# AAICGK4wCgIFAO5pddwCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoD
# AqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAdi09
# LSDoMZSexszcrNbLiJq+9iPVp2IxWAsApXPqTU55j31NX2Zps2l6e/XMZYy3/Rzq
# lVI+kaN1AsxPGRz54LvjYJiAVU0FVCUOKWbpa7+9+GM2GVU1jAj0xXD4LzeYWuVa
# U/pv1TYKOsaXiDDgeHCc2uXO2k9SdxVNKwkToF3bZKui82v8dKeqegjK6pGKrNit
# IOkMcZjIfME34IRY2FcoV7+LhP/OHKzLkFzq+8qSji1/9dRsIHXF1U31+6WbwxWM
# AqwhT1CMruCc7RFsA57MCimFbddkzv/w609tjqfVCyrUqUJWWKpsEgCPQ7zihLA7
# /lY20R2uO/uSopz8DjGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACICTh5uAXubSOAAEAAAIgMA0GCWCGSAFlAwQCAQUAoIIB
# SjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIAVC
# VIsGMNJThjDiuQdBbIN3XF2xrQKP38MGVQd7R108MIH6BgsqhkiG9w0BCRACLzGB
# 6jCB5zCB5DCBvQQg43u/I6U8DVWqUSnRAhUaU13xLlhYGcqP3su5NYdI7a8wgZgw
# gYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiAk4ebgF7m0
# jgABAAACIDAiBCDMhjd1vIrfpeGPJ5HAy4oq9vTSkidoMfYllW+5dYVoJjANBgkq
# hkiG9w0BAQsFAASCAgCCZiqwqACgzieP7FuS03pFg1T/UrtFQuK092N4z5wZm2VQ
# 0fUPGcKI5/L7NP4xSCVdjwXpkIlamyjPqK+ijyqyN+/EGTtmrgbt8Ns5k30rcSgG
# sK020L5JH/Ag0s+lHxv5cZOMo7oFHouvYBBwP/Rn96pMAK4/PFnCCqM+CqkZfdmg
# Kq1lAdTvPKN6ZjHCWYXw0QB9j1DaTGjn3kLPz9Hq8r4wu1QdymdEaWDI9AqhBDVB
# NP44ALtASzrlE85sHTBuct82S/3fPfLtyyCYJoWYCM+Oj1Mn/uTqyyL6iyJpN7wv
# jcyG/ubtcWXoJ4K+BtIpqLobnpYZWobLx3wr9gV80IZ0j9ZRUl8LXCcTAhQdOSfh
# RZUmduo71D5issey9pfooZcsCh7e4G+6VwzxYjeFXas0kVmVXRV6u5llWVPgeP/e
# 9iYCG1rvanAMJndqUOzTL09DgSn++YT6tJakT2nIP3wv5aNbRB5meaWJFaGyoIe3
# c4Qw81iQ9hyyF2t6PToL5vm+j7rXFrbtHzeb3i3PhJ7S90ABCGUx6AiT41xUiPSH
# O7qskRlEJSX3YSw08wIvTzTeC68iqnrHCR2fwRlmdwhiIvsqa2BySwndPsZcU0nF
# oxnT4AjOL/RP1rRChrwSaI/rp6pzQvnoxClUlcM/dfBKxsTfgr7ZGTfnE5Zn7A==
# SIG # End signature block
