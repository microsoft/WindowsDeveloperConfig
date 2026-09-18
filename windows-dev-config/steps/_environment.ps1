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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
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
# bDJX06GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCDGAYrW0foOfm1
# kJYuZSPAWbXe2J2YyOok9Bgnivv88gIGaqrCeEvmGBMyMDI2MDkxODE2MTEzNi43
# MzdaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiEzwDX70g8hpAABAAACITANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTRaFw0yNzA1MTcxOTM5NTRa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDb
# cTACqU1YvRocyWL2PL9fyf/+ULs2qK7U1aZsRnDZSnlCr7K7jgA3eFCEJL5BZ7dU
# TC0DeZepf+ZC+7HEbB4IdzmJfQAUDFFerqY5VTHmQvP2XA3lWSFj740idcGUHglP
# 5H/PbCJU7GAHWP2HdcCjdx1lYAo0A+zLI7xwnTQeMyOXX212Eg4UmDPPJgxdTMw6
# WFVWsBPWRBi5gDixy2s+7R8ADk5lbBBFDB5h0CjrNWIN7uCAzF5g7trrL8nXIKp1
# 0mj9RxhcGQ+tlht6VIvdygRVTUGdzFB2/nBvJqQ9kxxFltQST70fEdx4TyaKow/f
# 5+BSh4z4/9f7NXIVVTLn/8kcJAfRqFmRrrFt3IKby7VrzmYuoQWD0lmNFtGQ57Br
# JkPrPFAPek1ALtcbb7FH3nQpvi8ngz/MFX/+cnmNFWFU29VVLmzB9XvLZxbYvkee
# tt0mh5lfteeN2rEwUyrdrKufz9h2S6pbate+C2h02CrXwSka0x6ezpTmGkIJLFt2
# 5ub/UYXNLdHdsxGD6EfckOIoJYsm4MS9F/vSqLNHK89I0vTLBngQEp6LIFkINanR
# T3PtNx3pNKRKJRALc6L6mhW4hL4aHL749qPfQ72t5qAMm5xiKYMgJ2WanidRLNuI
# 251JIN7raaeA/2vb0XFkZcIbTR1pfQGsco4U0g5tjwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFOYjIs5qa6pfuquPyyK1FTr5QDCnMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA4I/3bkdnTxD2rFum3MF8xVKdEkohAObbePrQ+0fr5bRimjz9sVkKT/7gc
# j4OMcClSYG+IdX6Mp3EYsLHWfjvwfzFoeZE+yTbdBj/1VHZQRuCmw6QqeVCTbw2n
# nS7nBxnWd9oZXbPUpqEawH5DqXQaWFgR9A4KWVK/IvXVDMj1PlPCES1P3JonNbdh
# kkkz49rJuKOm5b7e/BH8loqAmXOXRc22yxWVTMWrEp4pslmv8eT7VoY8X/jdKYTP
# VEXsfmLbVFcqzMuB8vFGfUyWsWROS8wgq7lQYfWcYqh7NymoATX+wWYK3zWG7aRc
# iPGUAzznXdf+aHtIWnQLNa5HFmSXkiak3fSuprWYZiHhuYjE16hroApcBHpm+8S/
# kNqhm9WjQX+2BxnYv+Jejy6lqTi8fLBLS069WXVw/ptf5IV+FtYl34GvVoeg31Uo
# UmVVZe1SDUJkm9dDXc8l/qBDYiAIT2CCsPTyt9XA9JVuHxdP63n7ChvWAO/47QRu
# CDsUlFJoWwyBwl7jeYpaRVMtQt0iuJMGGjgEaJX1Q/2j8sXURvTceLHDD9ipWt09
# 2ZDWMQciDRmhHNFOX1dnjBvk/k1UMcg997j5oYznAnSpJvlg/4BP3aVE0h/YH2Kg
# sKbU4NXZHAjJXj2Slqo1C115CG6qBZaFkM8W6vPZCm5qnSezOjCCB3EwggVZoAMC
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
# U1MgRVNOOjMzMDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQALbEgZZnyYHXJ1DGb5fGjplXpt
# uaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7lc63jAiGA8yMDI2MDkxODA0MjE1MFoYDzIwMjYwOTE5MDQyMTUw
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuVzreAgEAMAcCAQACAhcCMAcCAQAC
# AhIQMAoCBQDuWIxeAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAIvgqvHH
# YzLJz9I85hU7hJWJZSJo8oJPpzjzTZ/rL/DpaxaEMmK3E97PlXdpahMgEGVLSzDv
# /F0cQQVKOCkzlBBoLQB1mEc3yXO0InrHFYQlk4QIOHGgW7Ic5wDzw6Maxt5LUWdu
# anOQCAEr8bD4RfgPnDdZ/HJiR9sZwByscx/qT+W7Z2XgdpRfN4DhMEuAvmxfMUpS
# 7o6GVvWugTq6ilME2fZCAYSsmrqoaApCNPsDmAORnsDYOmoXpZvtWIRt230dRiRj
# xwM+rFI2jQBQZQg45I8iNSWK8TPFKFoRCJYbQarxYlBO/LvZ1lj3QYg6cANk7rpd
# qUpzQ6HIBmtrGG4xggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiEzwDX70g8hpAABAAACITANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCsFFCy
# TDVDY1fH85HbgGK8eNiQtSNM3AAaq1c+4i+LDTCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIADvIQefFVUa4BJy8IZywMAvmGSKdUVqEmy9A++PCj1EMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIhM8A1+9IPIaQA
# AQAAAiEwIgQgwoi5apoTJQF4J0hLerV5hfxOUPUgbP0T/4aBv+85qT0wDQYJKoZI
# hvcNAQELBQAEggIANyFF1l7LEimuF1Ch/OZ6vqmpEUfD7gNJKlaZhPxxGTTZY7P9
# RlwUDNFgHuR3PtQTxgSGLHSLRclO3JpJUeIs4w+FhMlNN2IcnTXv+CH5xnaZWt3C
# ifT95Ik0nTQBXTMY87sw36PWbb1gHnVF1bKAJTxXznQiz12/yhRO3HoWxD+zdbX6
# aF2qjotlm8P839DnowjLrAakloyQn96BQYy8wMFA6gUXmqHvUsKk6laS23g0VWnM
# Fd1e3BxZehwsq5uqFKgGj+rt/PTaQjAu8EWHKBvrqyvzubs2J8oQksxR5/EJqI+6
# OVcpXN6Wg8WoxChMBzD93YEspI/x2C/9LKDHXKt+wKpIvUYKmtWZFYmyfe3ao4CK
# MHtYzsFZybpkaq1fDM96P5FjJHJDvxbVG4RZz44bkQUTaE3zpVpxqLWEfxFgMw3X
# r3BZ4j78Mq2zBafCvoJIuhCL6pkGka4msoXTf1+XQoVQ7oSdNKVkp7nTUqKY4Tm6
# +zAd3xxB/Um/rbCIBFOiJ2dIn6FckubF6KiHxV9kn0b8B8KW9Ku34UjWsGO0coOu
# +ckbXVuuyTEbB3giD4vrXbB/3LRWOF5EZ+7HimRGosqbEfBAvnqwAwzCFxpkEC8z
# huaoExLNTPEueCUkToen9fcwOem7/e3p9+RxjM5XvIMdHr6WtPTbnE8N56I=
# SIG # End signature block
