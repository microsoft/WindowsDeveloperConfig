[CmdletBinding()]
param(
    [switch] $NonInteractive,
    [string] $Distro,
    [string[]] $BootstrapArgs = @()
)

& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Update only after publishing the signed payload.
    $payloadRef = '6b1c5a1dadd429570dd50ff44b15c0b5b86bc414'
    $baseUri = "https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/$payloadRef/wsl-comfort"
    $microsoftSignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

    foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
        $policy = Get-ExecutionPolicy -Scope $scope
        if ($policy -ne 'Undefined') {
            if ($policy -eq 'Restricted') {
                throw "Organization policy ($scope) requires $policy. Script execution is disabled; contact your administrator."
            }
            break
        }
    }

    # install.ps1 resumes from its own folder after the WSL reboot, so each run stages
    # into a new folder that later runs never change.
    $runName = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) +
        '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $target = Join-Path $env:LOCALAPPDATA "DevConfig\wsl-comfort\$runName"

    Write-Host ''
    Write-Host 'WSL Comfort setup' -ForegroundColor Cyan
    Write-Host "  Fetching '$payloadRef' from microsoft/WindowsDeveloperConfig..." -ForegroundColor DarkGray

    $ProgressPreference = 'SilentlyContinue'
    $null = New-Item -ItemType Directory -Path $target -Force
    $verified = $false
    try {
        foreach ($name in @('install.ps1', 'content-hashes.psd1')) {
            $path = Join-Path $target $name
            Invoke-WebRequest -Uri "$baseUri/$name" -OutFile $path -UseBasicParsing -TimeoutSec 60
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Subject -ne $microsoftSignerSubject) {
                throw "WSL Comfort $name failed Microsoft signature verification ($($signature.Status)). Setup was not started."
            }
        }

        $hashes = Microsoft.PowerShell.Utility\Import-PowerShellDataFile -LiteralPath (Join-Path $target 'content-hashes.psd1')
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        foreach ($entry in $hashes.GetEnumerator()) {
            if ($entry.Key -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $entry.Key -match '\.(ps1|psd1)$') {
                throw "The WSL Comfort content manifest lists an unexpected file: '$($entry.Key)'. Setup was not started."
            }
            $path = Join-Path $target $entry.Key
            Invoke-WebRequest -Uri "$baseUri/$($entry.Key)" -OutFile $path -UseBasicParsing -TimeoutSec 60

            # Latin-1 maps each byte to one character, so this only drops the CR of each CRLF.
            $canonical = $latin1.GetBytes($latin1.GetString([IO.File]::ReadAllBytes($path)).Replace("`r`n", "`n"))
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $actual = ([BitConverter]::ToString($sha.ComputeHash($canonical))).Replace('-', '').ToLowerInvariant()
            } finally {
                $sha.Dispose()
            }
            if ($actual -ne ([string]$entry.Value).ToLowerInvariant()) {
                throw "WSL Comfort $($entry.Key) failed SHA-256 verification. Setup was not started."
            }
        }

        Get-ChildItem -LiteralPath $target -File | Unblock-File
        $verified = $true
    } finally {
        if (-not $verified) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  Verified the signed payload. Ready in $target" -ForegroundColor DarkGray

    $quote = {
        param([string] $Value)
        "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
    }
    # The child can inherit incompatible built-in modules from another PowerShell edition.
    $command = '$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"; & ' + (& $quote (Join-Path $target 'install.ps1'))
    if ($NonInteractive) { $command += ' -NonInteractive' }
    if ($Distro) { $command += ' -Distro ' + (& $quote $Distro) }
    if (@($BootstrapArgs).Count -gt 0) {
        $command += ' -BootstrapArgs @(' + ((@($BootstrapArgs) | ForEach-Object { & $quote $_ }) -join ', ') + ')'
    }

    $shell = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        # A 32-bit shell can't see the 64-bit wsl.exe.
        $shell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    # Start-Process keeps the real console attached, which the prompts and wsl.exe need.
    $process = Start-Process -FilePath $shell -NoNewWindow -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-Command',
        ('"' + [regex]::Replace($command, '(\\*)"', '$1$1\"') + '"')
    )
    # The cached handle keeps ExitCode readable; -Wait would also wait on anything WSL leaves running.
    $null = $process.Handle
    $process.WaitForExit()

    # Throw rather than exit so the caller's window stays open.
    if ($process.ExitCode -ne 0) {
        throw "WSL Comfort setup finished with exit code $($process.ExitCode)."
    }
}

# SIG # Begin signature block
# MIInJwYJKoZIhvcNAQcCoIInGDCCJxQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB1P96f6PjXk4KX
# xThi/yGs6WVXKdlr8v9WfIY57rJ9tKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIG55yIBVc5HGGBU9XcY13ziDxg9+ZMLP5yc0QVYGGzmvMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAiMiOxEj04EqGEiOX
# NKXTd5fvtlPTtlNQnSP77A2tOn+dXSk9kG5Cq5BfeeRDiRz6e4LMWDU42reHtezC
# ckmYPfEgdATnUNVr5j7qcPmyExN4xDwaVNZdi72OuPeOGSh94RLUOevDtOQrOa/x
# ixUIe4ALfBWBwnmpU0Bl0fhRvC+EGNg9QEYdXZg9UU9khm4K/CpM19arq+zRYdd8
# hpOgAJLl/44k+GrFD+r+ztfqnUZgyFlTLokI/7OOXQP9rh1RgL6bjGnc7GyN+pfr
# ht9rHCxWZA4+iMWbn29uYw/PFxh+HG6rlNsClbLVQWrXToYJDE+0svUYCkWSSvPN
# /goEXaGCF5MwghePBgorBgEEAYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2ww
# ghdoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8
# MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAFVrMV0YOJpNCd
# 1DpU0GMczQT4kLDoKsUPfa+njiiHlwIGauILw5e2GBIyMDI2MTEwMzIxMTgyMS41
# OVowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RjAwLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEeowggcgMIIFCKADAgECAhMz
# AAACHqOspG45b3xJAAEAAAIeMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5Mzk0OVoXDTI3MDUxNzE5Mzk0OVow
# gcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsT
# HE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjo3RjAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKXR
# OO1sPCxHsV7xpzqiXmzXOG1Op3YBalyFCEun0bmaZIzbc3l/JAYJDUPTqs4Dc+Bc
# oX7vq9e84KzZWwu/WjCPiYcTISqKrwYnnIL79A1hGlk8Dx7s6B6TMM7pL/i/L+NM
# xhuneuG4WIooLNNY5C10VwX4PSTfr0jumb8TTtLI0waS413mWPlIn3VSoW5l+MwH
# pxDbCHvua2JFRV2PnfKN02qP4ZCX5hrPb0GOvOftTWWf4mkuWdvTF0aZmgg8plvA
# FVxa3Ivi7KEwvtJJOaI59ZdT6D7I2XQJ2gsYvwu1YcSLwWy5M95J1KqZ4yu8toSa
# JtNVNLi9BBjw0+dvq4jnLqI1X28EVybwtT+UNOMZOo9rtQFPiB1/kmbfBit8IVng
# /+PkyipPQk41xrnSO3hMYj3RKKFdoMRiqTbdLQglndSRSm6QNFOMrvXcEjKR9/HI
# Gox5Cp87TO9Z9THsGuZSm6BBzD334PEuXaB/65ASlGaeVutUn129b12zh+oQ83aM
# bRDAXU8FKCU1xXVKmpkqK1CAEZLC7/zYArO2gIfBhEdE3DPBNV7/Uo1O+aoB3hSB
# 6zjLA4fTaFpqBPzBhjw51Z2MqfeTTnbD6SZzRQLQX6JVdMZkgzG+j2IFlChd6HNG
# 1Yn9U60q8LJLdywrM3utK1YnCNJbPp205/SX7K0tAgMBAAGjggFJMIIBRTAdBgNV
# HQ4EFgQU5goWmuoEHQlmYlwULhw8+Z4XgmQwHwYDVR0jBBgwFoAUn6cVXQBeYl2D
# 9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUy
# MDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUB
# Af8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQAD
# ggIBAKShkHk2clUVvnAp6NGieTnXxrZME1ikpwEy18voFLQBFoAE4wZguU826EjU
# fCZ6U/2FfeirdNoSb9wOSTM1ADMN50+ChEjZHv7ymg1Ja8dcQCztJk4Ob3HsqqUG
# Q1kz17HhdjXI2ZU4CZYONGvuMqNqJBue1/sQLgY2KTEYZpVY6N9i3dD1fSv8qzwo
# GVvMNH3OMD9MJy1HhyjValTVlEsWsH1uXx1HGxufJPapDjUTt1PXZHfR4gZTOISz
# kY37bpX+i9c6LbR0mIzXeFha/LU00kCGQo6UsHU426d3p9+E91Rwday7xX6VHRpq
# QxXrgeoNsu6ZmsI3BSh9XHfEyTwXi0Jgm1DEtPLBzfSxkAPVLawLX3n3HoqLED6n
# jUUtSXyDrigfLdt9icfnF3gk4GBChqqd0aNxy3Gv7wSSeOErKuADOtNwosltR7OC
# jJ7xusIsn7Lo8CgSOldGRJgBTzB9DdhZFyToAvChXtSKfz6ukZBJteEXpzV1MVqR
# eYKEKW53ggANj+3olGQn7ToXMv6MN3wotXxCPvsl+K5OI8gbkb/GWcahkVxf7LIG
# 0O/NkTjx35j4dhR39y+EfUUqXsAf7kDKi2olIWa8z8G5hHHYHbRqxVeKVXaTYls0
# 7csYLPdD52kSXPCx8muRrU3+B62Zrt9amjCw2+ghoRC+Np3xMIIHcTCCBVmgAwIB
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
# UyBFU046N0YwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAIP9A2QoMhbhUgXuPeiLaputHRr/
# oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcN
# AQELBQACBQDulHI2MCIYDzIwMjYxMTAzMTQ0NjE0WhgPMjAyNjExMDQxNDQ2MTRa
# MHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO6UcjYCAQAwBwIBAAICDUMwBwIBAAIC
# EY0wCgIFAO6Vw7YCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAK
# MAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAKDCGiG+l
# 4w3Rtl2OP0hDGkqop+MLd6WE+O88YD7yOIROZcWp8ryE3UXkZjfdPlr2tESmBYyh
# Rqh7D0hdjlvkbcGApHKj9Giqm7YYkIYzOx5axCSco7PsxCDvoCjqBouWpu2su5SO
# UcmVjyuCZmCNXOXqLgeuI1xj7Fk7QtwCoMTpgEUVpuVaBDW57i6KExrF6r+pnfQU
# uScyNJg1yX3OO7vP9DtAa3nYll/cvGS5IHNDgHwRyR3uqb/J5hxOaY6aFPi7PGVy
# +upUuYKwI3RhvtL4liUxqbB+uT95UoStOTbRFFvNzcIUtxANbi4w7kRQLnESTKqh
# qKYe7QZJKBgmKTGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACHqOspG45b3xJAAEAAAIeMA0GCWCGSAFlAwQCAQUAoIIBSjAa
# BgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIMjTvjHE
# Omw/S7CCY05SCBH/3nJcVEiytrHd492/hNG4MIH6BgsqhkiG9w0BCRACLzGB6jCB
# 5zCB5DCBvQQgL4FdavP2B4yAzwG+fxurEeOEdcnb0QGLMhMjDQH284IwgZgwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh6jrKRuOW98SQAB
# AAACHjAiBCCOIHrXWZ2EIoypIflV5OEXxT8VdNVo4rQtHGy7N8zO2DANBgkqhkiG
# 9w0BAQsFAASCAgAuyE0RT0z9Bd2sDwOJradbWezwDPwaN7Qcg4qZVSQv0Hat65gm
# 5i/Nh3YE92eTRxjDnzqfu2o5E/8/JJ5YU4k+kL1Dfu4cSOgakA+sbFMRs4RGRf+C
# NaSpkhvfsaeIu63ocANiG2iOzH8K7WJWFoniRgR7h2SKJVusRnemZ2NbyvZAq7Qm
# CnCQSIXEcwc7FJyXPVhNyb5h7PccXefp9I8vGmU47O8FvMOrDiXnN0SSQK9RbBDO
# WrXSxftlFUx9RVxTQL9mIo9ZRooRXUCXykxnnELOyPCaTeuzhLchBDrtu9EBqZbs
# cTC75QLwn33YYImkhfWmFOOBEpL/cO13XRfg0EBwW5FS8Xb3JgNpm3jhWrsHXZBw
# ejQjrzQeugWPTvuTZOGOQMriwEbKlvxDQH+uvkZzVfyWV3deoIAg7ailAdcSkYju
# m48s0pmBKGkzx8lXxmYhdziTCI6Zod4NWNw8PWqTko0Gi03vU/WVsDnnGY7H0nHA
# q9mxtiRcB7GrlKJ5WLTYiOgfB2IEpWvBO2GMrnex4gXkGDj3mv1otGILjT84pOxj
# 6f1Gau5n7W0DR0weHhWJGqK/0jKbwsfTUUYuFVr1VR131dk+098RWgh+MlQ8RfUW
# 0Xnn5AqZXns09XWa/edmPAj2dym1jCwiTAmcrAP4MvaO6iwcH27qDeCG8A==
# SIG # End signature block
