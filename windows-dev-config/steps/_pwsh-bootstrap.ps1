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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
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
# jJk4hKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBo5bHBOXnj0qVK
# qPf06TarFhjGfTCHWmFgkdfeAWwvzAIGaqlts48uGBMyMDI2MTAwNzAwMjgxNi42
# NjRaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
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
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOjkyMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQA4RWFs+kTiZnoZiAj1BtYj8zCN
# aqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7m+YXTAiGA8yMDI2MTAwNjE1NTUwOVoYDzIwMjYxMDA3MTU1NTA5
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDub5hdAgEAMAcCAQACAifDMAcCAQAC
# AhIWMAoCBQDucOndAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAC32x9A9
# k/BS6a/hb9f1pHe6/DjE9rcEEMlGmVqV8N/vrEfc7vjE71hMAyRjXXDuetXyTlv7
# JBy0n3GRigo5RMiERY9Dh0hZWrnPXeUHdX+QQKy9MWE6TXWV3E/y5rNWOyNltONJ
# 3m2+FjC0kbbEWmed2NazEEid7cJSE9lpXwWEifFjsVOGKKSIfcSI+fQryvLB/3wL
# 0MUHqEigjfezNO+ecIhcZRS9gY6ErHiaKn+UlcZSom48U+sykmvoXTIwob96kvAb
# NhludzIdCZVU/vUCzFewK9hvjCs8JPXNe3FLfIDLMJBF/ridjDrkHic1JZ65XSwE
# lt6vTH8PFw72FVcxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiNP2WAkU8/+KwABAAACIzANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCA9jULv
# cy3WiYc06MTY3sp3Csfaon3v+PJuZEja+3y6VDCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIJbwMywRbvcGiynjnwjAqcaD47yYvebKZRAvtEAR5u6zMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIjT9lgJFPP/isA
# AQAAAiMwIgQgGBOduoW46vNsiMxanYVo/+oTn+ExLYW2Oa1cEQYMfp8wDQYJKoZI
# hvcNAQELBQAEggIAQ5ccrf+/AA19Ba9cYI6waN77+NVjjIP6sWt/unGuA5YvsUqb
# mzYBnJGxsQTAryUgYwjZjfF5zAziSKyADSQQL8N4RZB6/XPKD4xHOIKonzqfI6rP
# N+ohrqammH/Z3CZZxJRPlfnwCBhDo0UdRcn/u3N5bvuvOPcASDFJH1+8V7cL5BGo
# 3xZQ8ydFe6lFmCBk3QnYOWktru97D540h9lk9kJ8Q1SvUdBnT086RQseSly1Nx1A
# WgGrxmARj52/X4pql4R9cHRuACNbE48fu+vVe7uhK68pum0CscHcz86fM/PhyePP
# X0Y9HOy7may9OG7OBg1JDsIpQErFk3G+ffCHUAFx9rljIWkZ/pVSvIQR2aB7jbeT
# aN3eqSGiUGO79J1YMAjhJ+V5fqAgJiSpEj+7BixusT3RiKVNEXbvMYBO7ADMCmI3
# ejeY41GlgOJXbx1FMaAaWKdgIHoNVc/jY4dUEeZ5N055y0vsCrIJg4lWrcJEE+08
# mole4bsbGAWfeic+OsioIp4c/hyKf6pbtruKiLm0nGBcwTwldacsc4DvdoO+H9Eb
# 8p1CwYdR/HnnxFggkgtEDwuHMk4yF6LAgeCdj3gKoofj2dXabue3OimP1JeQs0ad
# EdRto9EKiVebTjjSTGLEwqUg/fLUWPSFgwK0TWiXvMq+hQtUL48BoS4U3mc=
# SIG # End signature block
