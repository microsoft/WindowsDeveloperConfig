<#
.SYNOPSIS
  Hard-fail preflight: assert that `winget configure` is available on this
  host. Every Windows flow in this repo -- and the CmdPal extension that
  launches them -- uses `winget configure` as its only install path. If it
  isn't wired up, there is nothing useful to do but bail with an
  actionable message.

.DESCRIPTION
  Failure modes this catches, in order of likelihood:

    1. winget (Microsoft.DesktopAppInstaller) is not installed at all, or
       is too old / broken to expose the `configure` subcommand.
    2. The `configuration` experimental feature flag is turned off in
       `winget settings` (`experimentalFeatures.configuration = false`).
       Only relevant on winget < 1.6; harmless to check on newer builds.
    3. Group Policy / MDM has disabled configure via the ADMX policy
       `EnableWindowsPackageManagerConfiguration` (registry value
       `HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller\
       EnableWindowsPackageManagerConfiguration`, `0` = disabled).
    4. Running in a non-interactive context where the AppInstaller COM
       server cannot spin up (headless service accounts, SSH sessions
       without a desktop). We can't always detect this -- we just surface
       it as a fallback hint when the other checks pass but configure
       still errors.

  This script never "warns and continues" -- the whole point of this repo
  is `winget configure`, so a failure here is a stop-the-world condition.

.PARAMETER Quiet
  Suppress the "OK" line on success. Error output is always emitted.
#>

[CmdletBinding()]
param(
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# UTF-8 console encoding, matching winget's output. Without this, a
# `winget configure --help` probe under Windows PowerShell 5.1 prints
# garbled glyphs in the error message we surface. See issue #15.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

function Test-ConfigurePolicyAllowed {
    # Returns $true if the GPO key is absent or set to anything other than 0.
    # Returns $false ONLY when the key is explicitly 0 (disabled by policy).
    $keyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'
    try {
        $val = (Get-ItemProperty -Path $keyPath -Name 'EnableWindowsPackageManagerConfiguration' -ErrorAction Stop).EnableWindowsPackageManagerConfiguration
        return [int]$val -ne 0
    } catch {
        # Key or value absent => not policy-restricted.
        return $true
    }
}

# 1. winget itself must be present.
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetCmd) {
    throw @"
winget is not installed or not on PATH.

This repository's flows (and the CmdPal extension) require Windows Package
Manager (winget) with the `configure` subcommand. To fix:

  1. Install / update 'App Installer' from the Microsoft Store, or
  2. Grab the latest MSIX from
     https://github.com/microsoft/winget-cli/releases/latest
     (look for Microsoft.DesktopAppInstaller_*.msixbundle).

Then re-run your command.
"@
}

# 2. GPO / MDM check first -- cheapest, and its error message is the most
#    actionable, so surface it before the subprocess call.
if (-not (Test-ConfigurePolicyAllowed)) {
    throw @"
`winget configure` is disabled by Group Policy on this machine.

Registry key:
  HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller
  EnableWindowsPackageManagerConfiguration = 0

This is ADMX policy 'Enable Windows Package Manager Configuration'
(Computer Configuration > Administrative Templates > Windows Components >
App Installer). If this is your box, set the policy to 'Enabled' (or
delete the value) and reboot. If the box is domain-managed, file a
ticket with IT -- every flow in this repo depends on configure being
allowed.
"@
}

# 3. Probe the configure subcommand itself. `--help` is a pure no-op that
#    exits 0 iff the subcommand is wired up and the experimental flag
#    (if required) is on.
$helpOutput = & winget configure --help 2>&1
$helpExit   = $LASTEXITCODE

$looksRecognized = ($helpExit -eq 0) -and ($helpOutput -join "`n") -match '(?i)configuration|configure'

if (-not $looksRecognized) {
    throw @"
`winget configure --help` did not succeed on this machine
(exit=$helpExit). winget itself is present ($($wingetCmd.Source)) but the
`configure` subcommand is not wired up.

Output from `winget configure --help`:
--------
$($helpOutput -join [Environment]::NewLine)
--------

To fix, run the canonical remediation script (elevates via UAC):

  scripts\windows\_common\enable-winget-configure.ps1

It runs `winget configure --enable` and installs the required
Microsoft.VCRedist.2015+.x64 dependency, then re-verifies. The CmdPal
extension's red banner launches the same script. If you prefer to run
the steps by hand:

  winget configure --enable
  winget install -s winget --id Microsoft.VCRedist.2015+.x64 ``
      --accept-package-agreements --accept-source-agreements

Still failing after the script? Likely causes:

  1. App Installer itself is too old to know `--enable`. Update it:
       winget source update
       winget upgrade --id Microsoft.AppInstaller --accept-source-agreements --accept-package-agreements
     or install the latest MSIX from
       https://github.com/microsoft/winget-cli/releases/latest

  2. You are running from a non-interactive session (SSH, Scheduled
     Task 'run whether user is logged on or not', headless service
     account). winget's configure path needs the AppInstaller COM
     server, which requires an interactive desktop. Re-run from a
     foreground PowerShell / Windows Terminal window.
"@
}

if (-not $Quiet) {
    $ver = (& winget --version) 2>$null
    Write-Host "winget configure: available ($ver)"
}

# SIG # Begin signature block
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBgBxDmGEi+9xLg
# WMBMCIMf2v9VaJNkK0+QnEfFv1rG7KCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIPtlXTx+5y3fD5Gzgc+viewyRUu+
# UyOs9/DEZCbBEqjnMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAGYA6Xmyo1e3zAxKUKv7rAYdAtROR8kzTkDll/Dh0I1tJYxaoQWGMsF2hmVId
# P/pn+iq4VLauRn4ZzMMnzounQNeH4Z5xlZx/cBp68iYnPk0UMXe977QmdI3UoRxJ
# 7QpTdznfy2txq/HBTFdxQDfscx9i41kxCVHficgiZuZ2gCBedaY1JmXLF72XovQu
# q2zRAKVnxE6I55ZnnWJOH5qpO0PgaM5rcOPBKBrs+dCTZcDqNsVN4M96837XzDTE
# oEYcibqwi2cNyna670KUmQRJsns5wuzN8VYIxizZBFE+2Rv3RkxL7fgTO76WBaGG
# Z4YxuOM+mj0UXuURB2CkZGlOg6GCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCA0XcXD25+d5kJma6o6ae7gpBc9YC8v0gXZxEMMOCxUHgIGaq3JA61dGBMy
# MDI2MTAwOTAwMTgzOS43OTlaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoy
# RDFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACEtEIBjzKGE+qAAEAAAISMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgxNVoXDTI2MTExMzE4NDgxNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjJEMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAr0zToDkpWQtsZekS0cV0quDd
# KSTGkovvBaZH0OAIEi0O3CcO77JiX8c4Epq9uibHVZZ1W/LoufE172vkRXO+QYNt
# WWorECJ2AcZQ10bpAltkhZNiXlVJ8L3QzhKgrXrmMkm2J+/g81U23JPcO4wXHEft
# onT3wpd//936rjmwxMm7NkbsygbJf+4AVBMNr4aMPQhBd76od0KMB6WrvyEGOOU0
# 893OFufS5EDey4n44WgaxJE0Vnv3/OOvuOw5Kp1KPqjjYJ+L9ywLuBMtcDfLpNQO
# /h1eFEoMrbiEM67TOfNlXfxbDz4MlsYvLioxgd2Xzey1QxrV1+i+JyVDJMiSe9gK
# OuzpiQQFE19DUPgsidyjLTzXEhSVLBlRor0eCVf7gC6Rfk8NY3rO2sggOL79vU5F
# uDKTh/sIOtcUHeHC42jBGB+tfdKC1KOBR+UlN9aOzg8mpUNI2FgqQvirVP9ppbeM
# Ufvp2wA9voyTiRWvDgzCxo8xlJ1nscYTHIQrmkF9j/Ca0IDmt8fvOn64nnlJOGUY
# ZYHMC1l0xtgkYTE1ESUqqkawKk7iqbxdnLyycS+dR+zaxPudMDLrQFz8lgfy9obk
# 0D8HC2dzhWpYNn5hdkoPEzgCqQUOp8v3Qj/sd4anyupe5KoCkjABOP3yhSQ4W9Z+
# DrJnhM/rbsXC7oTv26cCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRSBblSxb5cYKYO
# wvd/VfoXOfu33jAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAXnSAkmX79Rc7lxS1
# wOozXJ7V0ou5DntVcOJplIkDjvEN8BIQph4U+gSOLZuVReP/z9YdUiUkcPwL1PM2
# 45/kEX1EegpxNc8HDA6hKCHg0ALNEcuxnGOlgKLokXfUer1D5hiW8PABM9R+neit
# eTgPaaRlJFvGTYvotc0uqGiES5hMQhL8RNFhpS9RcIWHtnQGEnrdOUvCAhs4FeVi
# awcmLTKv+1870c/MeTHi0QDdeR+7/Wg4qhkJ2k1iEHJdmYf8rIV0NRBZcdRTTdHe
# e35SXP5neNCfAkjDIuZycRud6jzPLCNLiNYzGXBswzJygj4EeSORT7wMvaFuKeRA
# XoXC3wwYvgIsI1zn3DGY625Y+yZSi8UNSNHuri36Zv9a+Q4vJwDpYK36S0TB2pf7
# xLiiH32nk7YK73Rg98W6fZ2INuzYzZ7Ghgvfffkj4EUXg1E0EffY1pEqkbpDTP7h
# /DBqtzoPXsyw2MUh+7yvWcq2BGZSuca6CY6X4ioMuc5PWpsmvOOli7ARNA7Ab8kK
# dCc2gNDLacglsweZEc9/VQB6hls/b6Kk32nkwuHExKlaeoSVrKB5U9xlp1+c8J/7
# GJj4Rw7AiQ8tcp+WmfyD8KxX2QlKbDi4SUjnglv4617R8+a/cDWJyaMt8279Wn7f
# 2yMedN7kfGIQ5SZj66RdhdlZOq8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
# AAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1
# V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9
# alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmv
# Haus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928
# jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3t
# pK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEe
# HT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26o
# ElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4C
# vEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ug
# poMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXps
# xREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0C
# AwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYE
# FCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtT
# NRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBD
# AEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZW
# y4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAt
# MDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0y
# My5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pc
# FLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpT
# Td2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0j
# VOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3
# +SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmR
# sqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSw
# ethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5b
# RAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmx
# aQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsX
# HRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0
# W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0
# HVUzWLOhcGbyoYIDVjCCAj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoy
# RDFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUA5VHBr4h00EN7jUdQ33SE+qbk/8CggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5yo00wIhgPMjAyNjEwMDgyMzE4MzdaGA8yMDI2MTAwOTIzMTgzN1owdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7nKjTQIBADAHAgEAAgIMDTAHAgEAAgISoTAKAgUA
# 7nP0zQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQARD64R7YNJX5SZLiIE
# k5dd+RQlSMC1UrEEgtgv7vrdpsdSzaGeQImve6jBjaUWH+AW3XUhlg7mAJ9Rcxn+
# rSpMuqKMXo6McQ6cbtt7WK5gWQ9jvxEDDUpgEnu3GJ1ob7q13DudtbbxDpyO1jz9
# c/G/iXLCCpw76UNGtoVxlEsHA7zZog7eJ5s3z8FOYe/Q0px+3fg/CyNjKMrd5lgJ
# Rs7KbgabgTdAD0TpeymsQwmuImnZDtRY3fOoopGjG04QY2iY4Yxf8ws3CQaSDm/n
# KzKp6RXfX+3s74V8jJ5Olsd9ov9O4fVyGVQH8xXAv0nlJ4NIdE6vyi9ALjkNIx45
# lmz1MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIS0QgGPMoYT6oAAQAAAhIwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgqYjGZHunzD/6gPk1
# tdBnHTlDYwRyb+5I7qX4tdjo6hcwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCBz+X5GvO7WngknH4BZeYU+BzBL1Jy5oJ8wVlTNIxfYgzCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACEtEIBjzKGE+qAAEAAAISMCIE
# IEkneFWBrseu7W5WflKM5UQU7JCdVK75bWIBlPy0E3n3MA0GCSqGSIb3DQEBCwUA
# BIICAJuCuaUH5a5sFwUhRPHtNs7FJqUPoPC3aFpDJsmMe9Mm3jk9JF7U3pxLoAxD
# WE7hiHxdBpfwijvKYhDmom7Bjxe7v5l7Nta4KNhmevh7U4WTcdI0JO/RaEe8f2Vx
# NRiLg2Um1ZzYCyHo+mGvGZh/1s7bI5FZVpOIsQnVunzIReyUEBnixzWT7z+Z/FAf
# uD9EhcZo/GG7pMjqA4IlaIpOwJOKdUKFEDya49GwlV1fMYQAegG2cQcRPVyV7vqH
# 3dSEBZa7SPnECLyYYV71ND6zExfHHIb8YCi7hbmmYzJSDEQtEChblcDf6XoRcVjL
# Fajfrc0U3ivBlsxfYuZu/l/HFOfQjItJqxImL3QEEjdoa8o9YZ53ptysdDcERSxB
# gigmoPdVJQ7gfnOnkjEMcq8fcMi/ZdIwMmAVPU/kjj0/JJqHlA9adSuPMaRGuAqd
# ZpOqAuZbj02U/5I7aPCVQUQQ4JgNfZAQQewowDZwAMM3oSg/NzRxI8uAEd4NcRbA
# QCGnIFLCa/HQ3Qea/R40kGqWvzjPWAWJlgbW+rr/N1uHVi0aFt+AWEmm8Zq7b56v
# JFrCVx1h/k2AjTPuH6LdznFr0RgGbzJbo9nAjqmLQruyZm6NV5fUAfrVOJ3SS9E3
# 6zDDur+v9eN1AlGoneljcxHemPRquzlAfuyM+FE+3JtSE6B8
# SIG # End signature block
