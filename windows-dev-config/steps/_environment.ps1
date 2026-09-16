<#
.SYNOPSIS
  Shared helpers for PATH refresh, TLS, native process execution, and UTF-8 text I/O.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Update-DevConfigSessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    # A missing per-user PATH is normal, so empty values are filtered before joining.
    $env:Path    = (@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

# Normalize native failures to exit codes so callers are not tied to shell-specific error behavior.
function Invoke-DevConfigNativeCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @()
    )
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false

    $output = & $FilePath @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

# Some installers can wait indefinitely, so process waits are bounded and emit periodic progress.
function Invoke-DevConfigProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [switch] $NoNewWindow,
        [string] $RedirectStandardOutput,
        [string] $RedirectStandardError
    )
    $start = @{ FilePath = $FilePath; PassThru = $true }
    if ($Arguments.Count)         { $start.ArgumentList           = $Arguments }
    if ($NoNewWindow)             { $start.NoNewWindow            = $true }
    if ($RedirectStandardOutput)  { $start.RedirectStandardOutput = $RedirectStandardOutput }
    if ($RedirectStandardError)   { $start.RedirectStandardError  = $RedirectStandardError }

    $process   = Start-Process @start
    # Cache the process handle before exit so Windows PowerShell can still report ExitCode.
    try { $null = $process.Handle } catch { Write-Verbose "Could not hold a handle on $FilePath." }
    $startedAt = Get-Date
    $deadline  = $startedAt.AddSeconds($TimeoutSeconds)
    $nextBeat  = $startedAt.AddSeconds(60)
    while (-not $process.HasExited) {
        $now = Get-Date
        if ($now -ge $deadline) {
            try { $process.Kill() } catch { Write-Verbose "Could not stop $FilePath : $($_.Exception.Message)" }
            $minutes = [Math]::Round($TimeoutSeconds / 60)
            # TimeoutException lets retry logic distinguish a bounded wait from retryable install failures.
            throw [System.TimeoutException]::new("$FilePath did not finish within $minutes minutes, so it was stopped.")
        }
        if ($now -ge $nextBeat) {
            Write-Host "  still working -- $([int]($now - $startedAt).TotalMinutes)m so far" -ForegroundColor DarkGray
            $nextBeat = $now.AddSeconds(60)
        }
        Start-Sleep -Milliseconds 500
    }
    $process.WaitForExit()
    return $process.ExitCode
}

# TLS 1.2 is enabled once so downloads work on Windows PowerShell 5.1 defaults.
function Enable-DevConfigModernTls {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Could not raise the TLS version: $($_.Exception.Message)"
    }
}

# ReadAllText preserves UTF-8 files without relying on Windows PowerShell 5.1 ANSI decoding.
function Read-DevConfigTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

# Write through a UTF-8 no-BOM temp file to avoid truncation and edition-specific encoding behavior.
function Write-DevConfigTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = "$Path.new"
    [System.IO.File]::WriteAllText($temp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

# SIG # Begin signature block
# MIInQwYJKoZIhvcNAQcCoIInNDCCJzACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBmyGkOSrgrvaWf
# BGr78cGfyfqqmwY1oN003pU0taOKgqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnfMIIZ2wIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIN4LBVlbuvuOil7BCk6cJXLFrCtb1B+dyP0oyfYns6TDMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAp9yqUrnLdvyHc341
# ileU0cWXi9tixO3i9TcpB80HG25gxlPccber/ItEeKqELK2LIqD5fJBF710cUCvr
# DTYdSZEQounWRfe0ItSWl9zdE0IJrI2p/aubtRTS47VXl4B+SSbPUtv8vIRRqFUc
# xT62Bm4Uk2Aq1v97GHW8QbwSJHBLltP2E4kDpB/AtwjZa/l/knS+EcwmzqAIP6SL
# k0NrtAep05G+oVJC0Do2gwpeDloXydGrUikF7KqxkeZ2OfOAkhv0l5/4JdMxWNFj
# tOev6vAGXDXF/7F0S/wB2CCKaLjc+mXAG3qlCwztBto3ZXFHZB9koUtfweQknc/Y
# bDJX06GCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cGCSqGSIb3DQEHAqCCF4gw
# gheEAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG9w0BCRABBKCCAUgEggFE
# MIIBQAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCDGAYrW0foOfm1
# kJYuZSPAWbXe2J2YyOok9Bgnivv88gIGaoiirnolGBIyMDI2MDkxNjE4MjgyNS4y
# MlowBIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGlt
# aXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVFMC1EOTQ3MSUw
# IwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR/jCCBygwggUQ
# oAMCAQICEzMAAAIS0QgGPMoYT6oAAQAAAhIwDQYJKoZIhvcNAQELBQAwfDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwODE0MTg0ODE1WhcNMjYxMTEz
# MTg0ODE1WjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEt
# MCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MkQxQS0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCvTNOgOSlZC2xl6RLRxXSq4N0pJMaSi+8FpkfQ4AgSLQ7c
# Jw7vsmJfxzgSmr26JsdVlnVb8ui58TXva+RFc75Bg21ZaisQInYBxlDXRukCW2SF
# k2JeVUnwvdDOEqCteuYySbYn7+DzVTbck9w7jBccR+2idPfCl3//3fquObDEybs2
# RuzKBsl/7gBUEw2vhow9CEF3vqh3QowHpau/IQY45TTz3c4W59LkQN7LifjhaBrE
# kTRWe/f846+47DkqnUo+qONgn4v3LAu4Ey1wN8uk1A7+HV4USgytuIQzrtM582Vd
# /FsPPgyWxi8uKjGB3ZfN7LVDGtXX6L4nJUMkyJJ72Ao67OmJBAUTX0NQ+CyJ3KMt
# PNcSFJUsGVGivR4JV/uALpF+Tw1jes7ayCA4vv29TkW4MpOH+wg61xQd4cLjaMEY
# H6190oLUo4FH5SU31o7ODyalQ0jYWCpC+KtU/2mlt4xR++nbAD2+jJOJFa8ODMLG
# jzGUnWexxhMchCuaQX2P8JrQgOa3x+86frieeUk4ZRhlgcwLWXTG2CRhMTURJSqq
# RrAqTuKpvF2cvLJxL51H7NrE+50wMutAXPyWB/L2huTQPwcLZ3OFalg2fmF2Sg8T
# OAKpBQ6ny/dCP+x3hqfK6l7kqgKSMAE4/fKFJDhb1n4OsmeEz+tuxcLuhO/bpwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFFIFuVLFvlxgpg7C939V+hc5+7feMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQBedICSZfv1FzuXFLXA6jNcntXSi7kOe1Vw4mmU
# iQOO8Q3wEhCmHhT6BI4tm5VF4//P1h1SJSRw/AvU8zbjn+QRfUR6CnE1zwcMDqEo
# IeDQAs0Ry7GcY6WAouiRd9R6vUPmGJbw8AEz1H6d6K15OA9ppGUkW8ZNi+i1zS6o
# aIRLmExCEvxE0WGlL1FwhYe2dAYSet05S8ICGzgV5WJrByYtMq/7XzvRz8x5MeLR
# AN15H7v9aDiqGQnaTWIQcl2Zh/yshXQ1EFlx1FNN0d57flJc/md40J8CSMMi5nJx
# G53qPM8sI0uI1jMZcGzDMnKCPgR5I5FPvAy9oW4p5EBehcLfDBi+AiwjXOfcMZjr
# blj7JlKLxQ1I0e6uLfpm/1r5Di8nAOlgrfpLRMHal/vEuKIffaeTtgrvdGD3xbp9
# nYg27NjNnsaGC999+SPgRReDUTQR99jWkSqRukNM/uH8MGq3Og9ezLDYxSH7vK9Z
# yrYEZlK5xroJjpfiKgy5zk9amya846WLsBE0DsBvyQp0JzaA0MtpyCWzB5kRz39V
# AHqGWz9voqTfaeTC4cTEqVp6hJWsoHlT3GWnX5zwn/sYmPhHDsCJDy1yn5aZ/IPw
# rFfZCUpsOLhJSOeCW/jrXtHz5r9wNYnJoy3zbv1aft/bIx503uR8YhDlJmPrpF2F
# 2Vk6rzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEw
# MB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk
# 4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9c
# T8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWG
# UNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6Gnsz
# rYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2
# LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLV
# wIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
# EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0
# gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFph
# AXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJ
# YfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXb
# GjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJ
# KwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnP
# EP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMw
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggr
# BgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
# xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
# BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0B
# AQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U5
# 18JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgAD
# sAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo
# 32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZ
# iefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZK
# PmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RI
# LLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
# ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9
# af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzba
# ukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNZMIIC
# QQIBATCCAQGhgdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGlt
# aXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVFMC1EOTQ3MSUw
# IwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4D
# AhoDFQDlUcGviHTQQ3uNR1DfdIT6puT/wKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7lS8qzAiGA8yMDI2MDkx
# NjA2NTg1MVoYDzIwMjYwOTE3MDY1ODUxWjB3MD0GCisGAQQBhFkKBAExLzAtMAoC
# BQDuVLyrAgEAMAoCAQACAgUNAgH/MAcCAQACAhOGMAoCBQDuVg4rAgEAMDYGCisG
# AQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMB
# hqAwDQYJKoZIhvcNAQELBQADggEBAHLw2sSzgn0RqK3wqrD8mg2qT9ZU35ecvUbD
# 4hZTy8v5eN5lSZ0Z8XfEk1FPR2IN4l9+KWRjA7lYaW163SIlb3JY68kwrGnt/YNY
# l9SxaQxLlCEI5Qp9uOE5GR0Aj3kbmlK9zg4VAz+dxUfJ6pOKCUtr2BihccdVPuNL
# aR1kt5b5Fv2UW+wY5PTYnOCg8uLC2hoPi0QlwHhbigxhSMUfrX+xNAHBEmw6mgma
# s57NJugUCbruFuRcobCJBi9eqYPpKxYeaTvv87sSayUULqjIBYiMYiww2acjfwia
# NMzj1Xcqq5dfyLDekLWixlmPRIHtydDOz0gqDv0dW/CTJRH1yqQxggQNMIIECQIB
# ATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAhLRCAY8yhhP
# qgABAAACEjANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
# DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCDe/MYRgTFtn0Z476lZY31CQ+n17rgMXwlj
# ZaBHG9pqPjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIHP5fka87taeCScf
# gFl5hT4HMEvUnLmgnzBWVM0jF9iDMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTACEzMAAAIS0QgGPMoYT6oAAQAAAhIwIgQgH71PbHFZpdxSR78i
# Y/TvEJfRBLOjbBZCGQ4e5SBIxVYwDQYJKoZIhvcNAQELBQAEggIAolY+zWfYfQWC
# 9NHf7kt1HNO2IrzzvPHhva/3P1i71qr2Y4h0fhjC1yRUf6xO4LnsqEX6++rIPzzh
# gmIDmIuaTdTsuEr1cluR7ri97rxoqIim7vA+NOoD0lhMbMs6+rxs27chvUnUGzw9
# PndsF8ZE+4g3cU1rcWAItWpvh4e1RMl/HEYR7qFT52c3tN7sxJPASDbne0Qn+2/J
# ShuSTDZ8LiKyh86qVhZJTFgZ7icbRONhec2S/9YmyWycguFRDkbsayL7smGXDt8R
# 8RCLXLMvi4JHIHkOjtXc8bX2RWUxj7u5SEurwT8oFZ3LvC8L0XmrcRdPmYgq2Y3r
# 3yqyafTggSoexyiLnz0qOIg4FaZ07qaMCm/1/vHcXgIU1opydWpjpjV15gwFzGLr
# xAxmUApyGr6c9yhYVqUibt+dHJIzQOTjRoF3H2GAnBIp5rKa1clto27WB7MO9FQm
# PBLaVaxt7ODzL+bVsK0CLcBY8u5VqL+vIJ9y5W/0mWqCHAn+kVfou6j01Ndp4dh2
# SkotGCbc3o0/MKZrCc0VFgIftdd0T4f+kjYsRMuL61zf2RN2a1m7p8AQZxH7+P8C
# /Yo28edNSRtSxkJPN6srEUxVGHU82nq+4PR4e268EMhEElKFAoWRWA2s6lhYrpw6
# K4LzwM0M5p1Tbzar47PqJXhu6dMneBI=
# SIG # End signature block
