<#
.SYNOPSIS
  Run an optional coding demonstration with a pinned 1.5B Qwen coder model.

.DESCRIPTION
  This is intentionally separate from install.ps1. The default llama.cpp
  validation model is about 397 MB; this optional coding model is about 1.04 GB.
#>
[CmdletBinding()]
param([string] $ReportPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$runtime = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\runtime'
$llamaCli = Join-Path $runtime 'llama-cli.exe'
$statePath = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\selected-backend.json'
if (-not (Test-Path -LiteralPath $llamaCli) -or -not (Test-Path -LiteralPath $statePath)) {
    throw 'Run llama.cpp\install.ps1 before the optional coding demonstration.'
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$plan = Get-LlamaCodingDemoPlan
$prompt = 'Write only valid Python code defining group_anagrams(words: list[str]) -> list[list[str]].'
$modelDirectory = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\models'
$modelPath = Join-Path $modelDirectory $plan.FileName

Install-VerifiedDownload `
    -Uri $plan.Url `
    -Destination $modelPath `
    -Sha256 $plan.Sha256 `
    -ExpectedSize $plan.Size

$arguments = @(
    '--model', $modelPath,
    '--single-turn',
    '--prompt', $prompt,
    '--reasoning', 'off',
    '--seed', '42',
    '--temperature', '0.2',
    '--top-p', '0.8',
    '--top-k', '20',
    '--predict', '384',
    '--no-display-prompt',
    '--simple-io',
    '--log-disable',
    '-ngl', $(if ($state.backend -eq 'CPU') { '0' } else { '999' })
)
if ($state.backend -eq 'CPU') {
    $arguments += @('--device', 'none')
} elseif ($state.requestedDevice) {
    $arguments += @('--device', [string]$state.requestedDevice)
}

$result = Invoke-AiNativeCommandSeparated `
    -FilePath $llamaCli `
    -Arguments $arguments `
    -TimeoutSeconds 1800
$output = $result.StandardOutput.Trim()
if ($result.ExitCode -ne 0 -or $output -notmatch '(?m)^\s*(?:```python\s*)?def\s+group_anagrams\s*\(') {
    throw "Coding model did not return the requested Python function. Output: $output"
}

if ($ReportPath) {
    $report = New-AiWorkloadReport -Id 'llama.cpp-coding-demo' -Request @{
        Prompt = $prompt
        Backend = $state.backend
        RequestedDevice = $state.requestedDevice
    }
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = 'Qwen2.5-Coder-1.5B-Instruct GGUF'
        vendor = 'Qwen'
        maturity = 'stable-model'
        sourceType = 'huggingface-immutable-revision'
        repository = $plan.Repository
        revision = $plan.Revision
        file = $plan.FileName
        sha256 = $plan.Sha256
        bytes = $plan.Size
        cachePath = $modelPath
        action = 'already-current-or-downloaded'
    })
    $report.acceptance.coding = [ordered]@{
        backend = $state.backend
        expectedDevice = $state.expectedDevice
        model = $plan.FileName
        outputContainsFunction = $true
        output = $output
    }
    Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
}

Write-Host $output
Write-Host "CODING_DEMO_READY: model=$($plan.FileName), backend=$($state.backend)"

# SIG # Begin signature block
# MIInJwYJKoZIhvcNAQcCoIInGDCCJxQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB78NKxl14VOVF3
# yHxhTFalshx/GPj0heXFLbP2rQTlgaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIPmpujQLvv8Po0m72xASI1zh1Y2rBh/cGkstUUUFHv0vMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAz5KlYjS5wVRfpMp1
# OhtNor4HY3ZvBGMrdxbY6D7f+IFbRZp6aWCZ6sMDAfvxgmm34LkGYT7AVhdwpJou
# 7UdnBmeWv1k/bGM2ccKyWvThPX22F3TGj+g0bRm2ttjCAlJZJJEe4n04VH94uGsl
# w6P7Q+bgfglreUzOt/zrQdIy7n0uCRXU4asPGpyajm/2P9T6qwgCQGmboT8lUFrN
# E26iDotR9KUnTHBbeZxS/KKstRQoqvhKkqmUoN+k39KJ1oRQo30LpCV4z5ruDv6I
# lkqLVO6g5qv8HvhHyA7f/iRLA550+iEOE4x/nIaLRBsPiQYLPx6oVQ15RkiFe3Ld
# UeTG6qGCF5MwghePBgorBgEEAYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2ww
# ghdoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8
# MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCD5YNSfF5NoK3mt
# Ml4VrUju2L6EpKwitYmk5Kvd5qv09QIGaqmsxy4BGBIyMDI2MTAwOTIxNDQ1NS41
# MlowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjo4NjAzLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEeowggcgMIIFCKADAgECAhMz
# AAACJYDHN8bNqndJAAEAAAIlMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5NDAwMVoXDTI3MDUxNzE5NDAwMVow
# gcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsT
# HE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjo4NjAzLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKbx
# Eg/R4sDjpVwI+i++aqwiU3qqSbPkiwdaZRTSd5Sqny4bFp16j5LBYELBDlqVkj8M
# 12ld/KJktlHpdiClE8XN6kiXs4INvg20SyQkIhkORAw3Csf1jBTK7vUYaKCwsjF6
# V4e0De62hVN4eNLVvxSfA5FG2ScqTKtQCtPpmkHauh0hyZwty/fHfDCBiU6zQUSD
# kSxWtlvss1z+d3RtcOn4dM5Za6Lx6hNXAl4vFxU/zr2gXyWLlJTzVpra0Ynr8mx6
# OLP0kxbxIlcoFPYMJcw5SQKwaOic9lGp++gxIhBmC1o5PIAmWu+zLRNnvxesaqjK
# C1CKZCds4Avgo0tIK5blNkRAZMcs5AkaCCBvePmAoLvvz5Eg8kD6f+GYcn/HipP8
# dNM+hV4wJy4EpatBdHX7+lhq7cXB7S1YjIb4tbORGv9k08+6lwDZhyLeqfwdH1HC
# 9CimpI0nCfZGLpqbwBDJ9VXL8EHDS3qOmhE+PAq+5SN8LOlp7p247FC1DVcM308D
# bKX2wOSj/4BdX9I57x5rxChBy/ezcSuQb4unqGe/Do4w+JqfiCA2RG2C0HuujU6K
# ik5Rcmf1jkQ7clQBc1y4z2b7kzLVUS68bK2AAfe7GayVOdbdhut9rNrJIJJKdaSF
# o5nfeGBu5RB8fufY0UQBRz9wXN+YJBSKRaKycljLAgMBAAGjggFJMIIBRTAdBgNV
# HQ4EFgQUsTjSqhdO4wdfcB9lS7WfyfHaH3cwHwYDVR0jBBgwFoAUn6cVXQBeYl2D
# 9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUy
# MDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUB
# Af8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQAD
# ggIBAAed9zbJTKgdlu+/JUoW5eHkfHEci8hpH0lakh8hMmVz8qLTeO5H69yTOre2
# nl8Ufksvt4gVdEi6h7Ayy9Z4Wta5+utbgeGaELCSoCt8DULTGT4dpizY7jxhLExf
# 2WBLWRNMhvdix+gV0Wkq6s9/adzZh3jAuD4WDCaTGR7ITcxQpWdrxJl5WkSOdLm5
# wVyTiys/ArY5EB/vQjbcYbI+GqAgpmmE1eFKxxMBCzIioHkbAMx1FXksrfs19Thi
# bG8JiHdMVgT8aHTVDrIm9/0fGIRmnBb6hSTSCu4ehuDeyAhHmt+BSjyXfS9SdoNg
# xw8AKVoUwL9BsdlJpSFZdkbU45wynSD29hA0sMSoVfaOWq6/NVJLC0e2bUpOV0KN
# EQP6R0LJtw/Fs9qXAmKBdzUGwj0KK2dN/SWPBv02Rn8lUjz8PratdfOHPgXe7SJU
# bPCdwZrFHEcb9e/idOumQ556mhhs0FsxZLYbWo/dePulV/T7ipHIConSy2NCOhU4
# kiZU9ZGPPk9HcOfpp1BUwEkMzqAOuPWtlMVWAK1OKOoZlIbO9ekaQXe9izITpkOZ
# r+QZ2JR7mxp4jqUfro+JZZeCrG3uzLYTO/TIiNJW/54w5PZAxSJnpYJzuBW0CZel
# 94i6z42aAW8z4hzVfnx7gj0QvhlICJ1KlZbQZlMs0LTaavIuMIIHcTCCBVmgAwIB
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
# UyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAFNv5so48CMIF+WHPDkRcG5JbF4O
# oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcN
# AQELBQACBQDuc8tMMCIYDzIwMjYxMDA5MjAyMTMyWhgPMjAyNjEwMTAyMDIxMzJa
# MHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO5zy0wCAQAwBwIBAAICBCkwBwIBAAIC
# FEYwCgIFAO51HMwCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAK
# MAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAJLlVo8U0
# vOOmYGZsivd4tYZJ5dQNM5utNiOkyTQ1e5c8oj+vVFxRFNC2wevIXDuCBrB3ZU5q
# K5MprurY35lHdVbpV5Z7Vn3+dnA40TRt6SyL41TPGENi4/az1vHy/qvE327kk2VZ
# mLQIKmskaSGLefMMWyUGh8HJAsqbzBpQCpCAmX3fbpDkJU2GfNWDaGbZusuPPW8J
# SlKYxJDBxfhLHwL7usiixI5NwzGf29BioLivNLdMK6XXdgeB+GOeqbO/+7BT4uXn
# F+xUHTW3WWCao6XmEsip8ULOpFEi7F2vSpUqP2aYGPY313ydAQqQ2/EAuIn6r5p3
# 4A/ptM/zJ10ldzGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACJYDHN8bNqndJAAEAAAIlMA0GCWCGSAFlAwQCAQUAoIIBSjAa
# BgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEILaB8Fra
# k6KcDQvWq41zworKVYzvJH9M+GhkptzpVaBHMIH6BgsqhkiG9w0BCRACLzGB6jCB
# 5zCB5DCBvQQgVg3uiHo43fL3YKYCX+UXQJjCuNZZA/p0JTFqM9IcoRAwgZgwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiWAxzfGzap3SQAB
# AAACJTAiBCAPxLlOoqNa9iZ0d93MolgrT8vR9EZQrjSeMMzLhED1pTANBgkqhkiG
# 9w0BAQsFAASCAgCEE5T2Oq1BYEOLjRn0fne8ymGRyBHfDVjEaJyZc65AK9j3VHB8
# 8EpbZHEid1cs2Zm76W19zQpWgvy+4YRfsnqvGeFUjQftIgcGTeoIhI3sPCm/Tber
# 04jHzB+nQHt0zTutTUAs5LCJ8fLxKd7AvUzwtsYuBIgdt8VeygN4KeGX6Heo9KwV
# HCPUtJcLL/1GMmx97T3beMUfOdkDIMLBIiz0VcMjK/FQg3cK+oVvfQE8XvIMtLUm
# QZ9kF+i3v3GU3vOarbViUUWLVzBULGkabB+nGIwkdL5A9dCwybXKuLbW0Ej0Oilr
# BTz7v2UFjHXtjt+Lg8UsMflXpzaBBXfiLGQeqPhneMxuwAoCHyyvWX00JCQb45tm
# fg83WfVfCNcqOxzG2rlPLpcVHQwQIEtQnut11UxuuTh6m3N58Mei3/FDCSNje4hN
# RFYM/xFxVacM+ZyUlGA7JHzmDc7eP7iTE20DeWpgNGUaA7fMP56nD0EupqpWaN13
# BLO4SISt34SRVPrP58xW9eCtctkeFDUvN8THo0zKOiVswH1LMittVjlmk4UV6r+5
# VEk/CZyDbtVDgvyn+5Vg/sYMaq598bQh35nBoz8oLm1pyWrE1K3ZLgKNajnBmHPC
# UKxiBnqjeBiUGi8ePIEemA1R3cUuQSPLhOAuiGyFuxy4oy5t9noZ/vcleg==
# SIG # End signature block
