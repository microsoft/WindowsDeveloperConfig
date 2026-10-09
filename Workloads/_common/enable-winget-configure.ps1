<#
.SYNOPSIS
  One-shot "fix it" script: turn on `winget configure` on a machine where
  it isn't working yet.

.DESCRIPTION
  This is the single remediation path for the three failure modes that
  `assert-winget-configure.ps1` detects. The CmdPal extension's red
  "winget configure is unavailable" banner launches this script; humans
  can also run it by hand. Keeping the logic here (not duplicated in C#)
  means any future tweak -- e.g. dropping the VCRedist install once
  AppInstaller ships it transitively -- only has to happen in one place.

  What it does, in order:

    1. Self-elevates via `Start-Process -Verb RunAs` if not already admin.
       `winget configure --enable` flips a machine-wide flag and needs
       elevation; `Microsoft.VCRedist.2015+.x64` likewise.
    2. Runs `winget configure --enable` -- the supported first-party way
       to turn the `configure` subcommand on. Ignores "already enabled"
       errors so re-runs are a safe no-op.
    3. Installs `Microsoft.VCRedist.2015+.x64` -- the PackageManager
       configure path transitively depends on the 2015+ x64 redistributable
       (AppInstaller does not always pull it in on its own). Skipped when
       already present.
    4. Re-runs the assert to confirm the fix took.

.PARAMETER NoElevate
  Internal switch used by the self-elevation path to avoid infinite
  re-elevation loops. Do not set by hand.

.PARAMETER SkipVCRedist
  Skip step (3). Useful once Microsoft ships a configure path that no
  longer needs VCRedist -- flip this on and we keep the rest of the
  remediation.

.EXAMPLE
  # From a normal PowerShell -- triggers a UAC prompt, then runs.
  .\enable-winget-configure.ps1

.EXAMPLE
  # From an already-elevated PowerShell (e.g. inside a VM bootstrap).
  .\enable-winget-configure.ps1 -NoElevate
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $SkipVCRedist,

    # Internal: set only by the self-elevation path below so the exit
    # pause fires only when we're running in a fresh window that would
    # otherwise close. Not part of the public surface; users running the
    # script themselves (elevated or not) should not pass this.
    [switch] $FromRelaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Force UTF-8 on the console + external pipe encodings. Windows
# PowerShell 5.1 defaults to the ANSI code page (1252) which mangles
# winget's braille-pattern spinner glyphs into scrolling mojibake.
# Safe no-op on pwsh 7. See issue #15.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

# Also force the OS-level console code page to 65001 (UTF-8) via chcp.
# [Console]::OutputEncoding alone is not always sufficient under Windows
# PowerShell 5.1 -- particularly in a freshly-spawned elevated conhost,
# where winget's own stdout goes through the OS console code page (1252
# by default on en-US). That causes the VCRedist download progress bar's
# block glyphs (U+2588) to render as "ûÆ" mojibake. See issue #22.
try {
    $null = cmd /c 'chcp 65001 >nul 2>&1'
} catch { }

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    if ($NoElevate) {
        throw 'Not running as Administrator and -NoElevate was passed. Re-launch from an elevated PowerShell.'
    }

    Write-Host ''
    Write-Host 'This fix needs to run elevated (UAC prompt will appear).' -ForegroundColor Yellow
    Write-Host 'Launching an elevated PowerShell...' -ForegroundColor Yellow
    Write-Host ''

    $forwardedArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-NoElevate', '-FromRelaunch')
    if ($SkipVCRedist) { $forwardedArgs += '-SkipVCRedist' }

    try {
        Start-Process -FilePath 'pwsh.exe' -ArgumentList $forwardedArgs -Verb RunAs -Wait
    } catch {
        # Fall back to Windows PowerShell 5.1 if pwsh isn't installed.
        Start-Process -FilePath 'powershell.exe' -ArgumentList $forwardedArgs -Verb RunAs -Wait
    }
    return
}

Write-Host ''
Write-Host '=== enable-winget-configure ===' -ForegroundColor Cyan
Write-Host ''

# --- Step 1: winget configure --enable ----------------------------------
Write-Host 'Step 1/3: winget configure --enable' -ForegroundColor Cyan
try {
    & winget configure --enable --disable-interactivity --accept-source-agreements 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        # Some winget builds return non-zero on "already enabled" -- inspect
        # stderr instead of hard-failing on the exit code alone.
        Write-Host "  (exit=$LASTEXITCODE -- if already enabled this is benign)" -ForegroundColor DarkYellow
    }
} catch {
    Write-Warning "winget configure --enable raised: $($_.Exception.Message)"
}

# --- Step 2: VCRedist 2015+ x64 -----------------------------------------
if ($SkipVCRedist) {
    Write-Host ''
    Write-Host 'Step 2/3: SKIPPED (via -SkipVCRedist)' -ForegroundColor DarkYellow
} else {
    Write-Host ''
    Write-Host 'Step 2/3: winget install Microsoft.VCRedist.2015+.x64' -ForegroundColor Cyan
    & winget install `
        --source winget `
        --id 'Microsoft.VCRedist.2015+.x64' `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  (exit=$LASTEXITCODE -- if already installed this is benign)" -ForegroundColor DarkYellow
    }
}

# --- Step 3: re-run the assert to confirm the fix took ------------------
Write-Host ''
Write-Host 'Step 3/3: verifying winget configure is now available' -ForegroundColor Cyan
$assert = Join-Path $PSScriptRoot 'assert-winget-configure.ps1'
if (Test-Path -LiteralPath $assert) {
    & $assert
} else {
    Write-Warning "assert-winget-configure.ps1 not found next to this script; skipping verify."
}

Write-Host ''
Write-Host 'All done. You can close this window.' -ForegroundColor Green
Write-Host ''

# Pause only if we self-elevated into a fresh window that would
# otherwise close before the user could read the output. When invoked
# directly from the user's own shell (elevated or not), the window is
# under the user's control and the pause is pure friction.
if ($FromRelaunch -and $Host.Name -eq 'ConsoleHost') {
    Write-Host 'Press any key to exit...' -ForegroundColor DarkGray
    try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 5 }
}

# SIG # Begin signature block
# MIInQwYJKoZIhvcNAQcCoIInNDCCJzACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAWEoj76p2bgZRE
# qT0f5FvcbwY8rLJ+0CpJ6RaaM8Ufp6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIJ7B5HUfahl3nIJLuaopCYuoCdMJAeoNBBEvp0MDx/juMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAUz4lzCAoRhkNubcO
# BK9r/Md34eKs6OrLp8Bd3FpvYpooJig97suFaaBwuv6QyW5dw+Kk6vdqQq+8msXe
# HOPZTO8OM8vOCkbKpdL6eb00MJ/rBRTf/ngtYHUsX9X+8jPXf/oQRJCATWUxaCE/
# PC7RENxS8Q3Me1fv1X58UaZhH4jvVX0yIfLjDwbqe+syC0JnNC80z1TDkqoB33oO
# VTHe1hc7B21BTbKfMRQZuE7dfYH3Wf//IsCOTTGjPv0hkgDWZIk0K/D6MbqvOnJq
# Vra05wkX0wTWrL0TLq2bCRTuCFQ/SPCGL6xSL7j+830fWrBHa2MNjytJ8LP35vh7
# h7dheKGCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cGCSqGSIb3DQEHAqCCF4gw
# gheEAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFZBgsqhkiG9w0BCRABBKCCAUgEggFE
# MIIBQAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBubeIJ2rynEHbp
# Bx0tBZsUTUf+UWOkHxlX/zVgp0HNhgIGaq1uSlu6GBIyMDI2MTAwOTAwMTkxMS4z
# NFowBIACAfSggdmkgdYwgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGlt
# aXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjM2MDUtMDVFMC1EOTQ3MSUw
# IwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR/jCCBygwggUQ
# oAMCAQICEzMAAAITsEM1Zs+vlegAAQAAAhMwDQYJKoZIhvcNAQELBQAwfDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjUwODE0MTg0ODE3WhcNMjYxMTEz
# MTg0ODE3WjCB0zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEt
# MCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzYwNS0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQD0mXrguhnEMg1IWDP70pLk7O/mbnjx49XNz1FdZ7hPj8ym
# V+Brh6rXZEZ2nlxW+eN17m/F+rZrH+Oe7u9Rbitk3iY5Sbm+H6RxixCVhDncXCAg
# HecSNxAeiasbeZl7+jOMVICvoluCUq0h4DJI/MBwXPIB6vmUs1QcES9AwzwE6MzJ
# qkK+HTGyDjEoVxUQlAsoR8IYF98xkj9qa60cVvcJRNntpWkbYocQVQ2VnW/Awq/F
# dM9EOdvA8bPLKoknOd+ws0dDi9e3a21LU94KgYjSE3U96rzIawhcz2ihzALToMY1
# Iz/gsDHa4q/CZSfo3AtzT62a+fLrDbytkt6OyRF+dVah8S/WZZjSMdScevBIYFLy
# BU/2BwGzo/mDQ6kk8x/F1SQddGRww89bSEg/w1tbxblK6nwe7CdIpuOnICUYFR0z
# 9XmtlvSxmaSfvXivpQsYr5wssA3pHcWFfo3SePrgXbstMrYFtLSkllpeOjR4M3PV
# BzF4gUtSAX5EGwtgOfwTxwKR7Erw2W3caL3Ml/nnDpR9Nn6TBMzEyoXGHv5N/Hv5
# oE5tn6fH3rUC2KoDLvNVXr2j8tZF0o9l29mf0RLIZtOc9+OQERG/bamtKUROVHDM
# /puYRU4pYtZXDG7CHttRZS5RvVyP3fO+21BgZBq3kT0Assk2aW8soKyQHutouwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFBOeEErH4WvKmFBYxGKkfj2wwUA6MB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQCCbFomsapDYPpQmFnpCXZJkU5o24ZtbcvMH4RL
# 6XYEHUwm0FFIV2L+FVjfc2nGwlCFDlMtWnQNdg6Qig9BzXusf4hWF6Y7yMK35Toj
# VMjDpxHtz60Sj8mOnoSoRTVzj+atoyOAeFD6toL85QCb3wDWvhsg8e2wGYtE4aZ4
# TlcsgVoEhlYe+HYI5chMo5tdV3nAa0nV1ll3BocAJcXnTqO1r66hR3LMB642VM8t
# OtnyfKHEbCT1WHp6INDsJAxZJJrwMlL09ReN6iL29N1Ltkxeq762/pDPfG2gEXn5
# gUri4T6aIaz3QXGbRUraVauYWGORGXnPKgc53Abuyk1iQOiYI81Yi51RCZBgqm38
# eyyl9xv7GmdYgNB0zOATymPW+nAuBYScfsu1Ph1kJ6gOj08rjRHEEPyQonvr2eCQ
# TB/AIPYRf8xCTv14i86GmcfXYa5UHK9opmTldm+q08403Cvyr+oDfzvsi5bBaCdp
# 5f6munDR1n9Au1sYZWuA/5NFCO37Z1xkDk/dfgvAA2GI+zLQ6XhcJ2Ps7EEsW87O
# wI8M9pWeSn518MUb404GKvtqpMnrzrbanKaDVX7qBz/VG/EL/CC9jIbTfd5wmq/Q
# 6fRlE1iv6L86TCADcc/VosPRoesSnDqW3TbreJGQK+tx1w5bzDeMLxMm5oZbILZL
# 2MSPODCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# aXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjM2MDUtMDVFMC1EOTQ3MSUw
# IwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4D
# AhoDFQCYETxIKPGCNpybLz9UR2Ts3GlHpqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nJImDAiGA8yMDI2MTAw
# ODE2NTEzNloYDzIwMjYxMDA5MTY1MTM2WjB3MD0GCisGAQQBhFkKBAExLzAtMAoC
# BQDuckiYAgEAMAoCAQACAhMHAgH/MAcCAQACAhMYMAoCBQDuc5oYAgEAMDYGCisG
# AQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMB
# hqAwDQYJKoZIhvcNAQELBQADggEBALa9nG3qOp9T+cxg9BpIdVztk5k2iPuOOsQz
# mI7OQB4C5u/GPe2Fty4fgDX1OHKVUyznkN5orY7gyC3Z7Yq/fwunHbU4jt++yXf2
# CcSEgBqvczwf1afy0bJAXzGNnf4qXeRI3yBqx6OUVNiUHkfXBWE23HYv3OprWdLR
# GsSr7ZNL5Q9gtm8W25vUM3wDjorSBwkPp3Ux8qhdBshE/CzTnOsVmgBl/9fEgDj7
# BxBeuCyaO3a/4G+B+aWSpXknsW7L3byAf8O8pb07UEGanz4+32G+ZpAhIpuMCetd
# hySnMyy7yVR0EJi6xnTdOZdvHuyyFxth6l195QZ41+tOpCaSnHQxggQNMIIECQIB
# ATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAhOwQzVmz6+V
# 6AABAAACEzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
# DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAtHT0Bw8q1FJo49+TmtjVRSKdFaoaafudT
# rfKFx9eM7jCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMzhCW0UhTPwngOM
# DM/idWh1m9DFgaV5Qh+nzo5rnFhoMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTACEzMAAAITsEM1Zs+vlegAAQAAAhMwIgQgZHnx7TXYSM8lSXfP
# DFiLQXx0AZzVAHu0sNvUzDUUMSswDQYJKoZIhvcNAQELBQAEggIAFtAzhGRA5ZoK
# lwABHgQk91UNAJsgi1tEiALZarLEzf8V+4XhhQiHGvxhOmyX9dNvWSCQpygHNne7
# WroznuvDHa+uvV5AJNg0aYZT8SWz4iq2wBBO3lMIHcd6f60iWoOMRzhjgFN4OgM8
# 58Y2Hi20JSUa1yc8VbQPjGlYp9J6/bfZm4pQePdnzykxN2HNp5hoAhW006STrjP8
# SI9OMt61nAcvvWbCgkDJkQ4GWGED3R//sf6/UTwTCzRQ6eksxxf/e5A6X04e+ViP
# PGHG/fsnzqbs4EYAVsi/6uaAAZgsHehRoodtN4o63HLhbpTJ6epTJyJtKuin3TlL
# CQEU/lKbeqQwfNPayF+DnpDQ0wsNc5P2Tu7rsoGpSFUH1EXJbEE03jmKkBTaZggh
# pDFtxYjgwhmWvCShxyaAkrmRSf0kjlj2eCURaQr04pgnSK4A4nc0dIenRiInpmBb
# LV7BFli8+BR7+CyAl68NZnxpxdysLKu8Iuk9BbparRfklPKK/lEAMHBmcT0IIvhH
# cG8PB77KwhYXG1R9/UvEacJrwjWmcba4Wtj0zfiK4xZj/8U7e31FmD80UUU8HTLz
# 92W47bpnLVIZ87ViCqor4FyVajXfdPBWjKRqXjTFHieGWB/lUmWxktkLpcoK/b1u
# 2j06035azO+ndplkTzK7ccXmcnvGvIs=
# SIG # End signature block
