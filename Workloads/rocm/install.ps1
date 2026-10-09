<#
.SYNOPSIS
  Install AMD ROCm Core SDK on supported Windows x64 hardware and execute a HIP kernel.

.PARAMETER DeviceIndex
  Zero-based AMD device index used for HIP kernel execution on same-vendor
  multi-adapter systems.
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 63)] [int] $DeviceIndex = 0,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$gpuName = Get-AmdGpuName -DeviceIndex $DeviceIndex
$rocmPlan = $null
$planError = $null
try {
    $rocmPlan = Resolve-RocmInstallPlan -Architecture $architecture -GpuName $gpuName
} catch {
    $planError = $_.Exception.Message
}
$gfx = if ($rocmPlan) { $rocmPlan.GfxTarget } else { $null }

$catalog = (Get-AiCatalog).Components
$component = $catalog.AmdRocm
$report = New-AiWorkloadReport -Id 'rocm' -Request @{
    PlanOnly = [bool]$PlanOnly
    GpuName = $gpuName
    GfxTarget = $gfx
    DeviceIndex = $DeviceIndex
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'rocm' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
if (-not $PlanOnly) { Assert-AiAdministrator }
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $component.Vendor
    architecture = $architecture
    gpu = $gpuName
    gfxTarget = $gfx
    maturity = $component.Maturity
    sourceType = $component.SourceType
    index = $component.IndexUrl
    requirement = $(if ($gfx) { $component.PackageTemplate -f $gfx } else { $null })
    version = $component.Version
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = $component.InstallPath
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = $(if ($PlanOnly) { 'planned' } else { 'pending' })
})
if ($planError) {
    [void]$report.result.blockers.Add($planError)
    Set-AiAcquisitionAction -Report $report -Index 0 -Action 'blocked'
}
if ($report.result.blockers.Count -gt 0) {
    if ($PlanOnly) {
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: rocm'
        return
    }
    throw ($report.result.blockers -join ' ')
}
$pythonPackage = Ensure-AiWingetPackage -Id 'Python.Python.3.13' -PlanOnly:$PlanOnly
$cppTools = Ensure-AiVisualCppTools -Architecture X64 -PlanOnly:$PlanOnly
Add-AiReportPhase -Report $report -Name 'host-compiler' -Status $(if ($PlanOnly) { 'planned' } else { 'ready' }) -Evidence $cppTools
$requirement = $rocmPlan.Requirement
$report.acquisitions[0].requirement = $requirement
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = 'Python 3.13'
    sourceType = 'winget'
    packageId = 'Python.Python.3.13'
    action = $pythonPackage.Action
    packageEvidence = $(if ($PlanOnly) { $null } else { $pythonPackage.Evidence })
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'hip-kernel' -Status 'planned' -Evidence @{ gpu = $gpuName; gfx = $gfx; deviceIndex = $DeviceIndex }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: rocm'
    return
}

$compiler = Import-MsvcEnvironment -Architecture X64
$python = Get-Python313Path -Architecture X64
$root = Join-Path $env:LOCALAPPDATA 'DevConfig\rocm'
$venv = Join-Path $root '.venv'
$statePath = Join-Path $root 'install-state.json'
$desired = [ordered]@{ requirement = $requirement; python = '3.13'; gfx = $gfx } | ConvertTo-Json -Compress
if ((Test-Path $statePath) -and (Test-Path $venv) -and
    ((Get-Content $statePath -Raw).Trim() -ne $desired)) {
    Remove-Item -LiteralPath $venv -Recurse -Force
}
New-Item -ItemType Directory -Path $root -Force | Out-Null
if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) {
    Invoke-CheckedCommand -FilePath $python -ArgumentList @('-m', 'venv', $venv) -DisplayName 'ROCm environment creation'
}
$venvPython = Join-Path $venv 'Scripts\python.exe'
$hipcc = Join-Path $venv 'Scripts\hipcc.exe'
$expectedRocmPackages = @{
    'rocm-sdk-core' = '10.0.0'
    'rocm-sdk-devel' = '10.0.0'
    'rocm-sdk-libraries' = '10.0.0'
    "rocm-sdk-device-$gfx" = '10.0.0'
}
$packagesCurrent = (Test-Path $hipcc) -and
    (Test-PythonDistributionVersions -PythonPath $venvPython -Expected $expectedRocmPackages)
if (-not $packagesCurrent) {
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @(
        '-m', 'pip', 'install', '--upgrade', 'pip'
    ) -DisplayName 'pip upgrade'
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @(
        '-m', 'pip', 'install', '--index-url', $component.IndexUrl, $requirement
    ) -DisplayName 'AMD ROCm Core SDK installation'
}
Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @('-m', 'pip', 'check') -DisplayName 'ROCm dependency check'

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-hip-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
try {
    $executable = Join-Path $temporary 'hip-smoke.exe'
    Invoke-CheckedCommand -FilePath $hipcc -ArgumentList @(
        (Join-Path $PSScriptRoot 'hip-smoke.cpp'), '-O2', '-o', $executable
    ) -DisplayName 'HIP kernel compilation'
    $evidence = (& $executable $DeviceIndex 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $evidence -notmatch '^HIP_KERNEL_READY') {
        throw "HIP kernel acceptance failed (exit $LASTEXITCODE): $evidence"
    }
    $deviceMatch = [regex]::Match($evidence, '^HIP_KERNEL_READY device_index=([0-9]+) device=(.+?) value=42$')
    if (-not $deviceMatch.Success) {
        throw "HIP kernel evidence did not contain the selected device: $evidence"
    }
    $actualGpuName = $deviceMatch.Groups[2].Value
    if (-not (Test-AiDeviceNameMatch -Expected $gpuName -Actual $actualGpuName)) {
        throw "HIP device index $DeviceIndex executed on '$actualGpuName', but acquisition was resolved for '$gpuName' ($gfx). Use the matching -DeviceIndex."
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
Set-Content -LiteralPath $statePath -Value $desired -Encoding ascii
$report.acceptance.hipKernel = [ordered]@{
    compiled = $true
    executed = $true
    evidence = $evidence
    gpu = $gpuName
    actualGpu = $actualGpuName
    deviceIndex = $DeviceIndex
    gfxTarget = $gfx
    hostCompiler = $compiler
}
$report.acquisitions[0].action = $(if ($packagesCurrent) { 'already-current' } else { 'installed-or-upgraded' })
Add-AiReportPhase -Report $report -Name 'hip-kernel' -Status 'ready' -Evidence $report.acceptance.hipKernel
Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
Write-Host "ROCM_READY: $gpuName ($gfx)"
Write-Host 'INSTALL_OK: rocm'

# SIG # Begin signature block
# MIInKgYJKoZIhvcNAQcCoIInGzCCJxcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA2D8mOTml3t280
# GDr4SOplESls952nKSHNBUVAOnw03qCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIHiRsfgPElhHslCq0Jwl/bT2C0mgcKK6KYfBBH6wxER6MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAXplbCf1RXQEdr72y
# 37Kd2gHgDEb/uToW/xdcFxNM5bp9w9F1lPXbMNSzK2NCMEj2Fely9mlPp5gutZyn
# /LC+noj5QgULuOTOe8fACkZNECGS97cYpsxOvGea6RILAlEHqVGt8x4BRgynA0r6
# WC4AC1zb+ZL8okmGpijY8+iR5YkwzyhHz1vjzslbSdl6fZfrh8jnXLfheIGsRtSy
# deSpymyF34Q+n2X04H4aUgwTTKOUmrwbly4YQw96jDHPYh84luJJ5+1gatJHB18j
# YQ1bJik5d8a413HMYXU8+38ACdkvQj7e5Ofj3oZyQmB7oIsIExI6lXyYz75OLfcP
# kZC4c6GCF5YwgheSBgorBgEEAYI3AwMBMYIXgjCCF34GCSqGSIb3DQEHAqCCF28w
# ghdrAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8
# MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBjuS4L8sL3RgwR
# aMC3E+Kssv5ja2qaZXVExfVRJWnlygIGaqpMus1xGBIyMDI2MTAwOTAwMTczOS45
# NFowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAl
# BgNVBAsTHm5TaGllbGQgVFNTIEVTTjozNzAzLTA1RTAtRDk0NzElMCMGA1UEAxMc
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEe0wggcgMIIFCKADAgECAhMz
# AAACHzpwaeSiMC6VAAEAAAIfMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5Mzk1MVoXDTI3MDUxNzE5Mzk1MVow
# gcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsT
# HE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjozNzAzLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMs7
# xcU5x8aoCqCLPT4CZCYWXd1nRpMbhQUmSqo10wfLbwNqF4IGzo425+6TJ7nHjYJa
# TOBEjL2QTZVbASe1nxmSDKvKQLRsiqwgPv7oXGC6x5Nd/VXC+bUPzXThWZ62gEmU
# ni4Zu7IllS9cPHnmdWHnTKAtPNnbhaRCyc+m9Fm/aQ9zf1/duEvIdW2cexr9b/zp
# Wt+134B8W94D6o38Rj5caPlz8M8xcJgQJvRqthv3Z0Mla3DOnIGuniB8eWBjVQSl
# ziXgAYQut/YnjCvFPNNb5IzxeFXV044+tiMPTzQhtmovwH4gXREJ2fbr1hesYrpA
# geKnOcplwJLyM3fRgAedMlU3lnOzq3/ZiyoEYOq68Np3v3fgUVPDO9Rw7dWgjJ33
# ddbC8/z9IIVUmHbVbygZBOm0YfKXL4WXiF6dUxVkXW/qiw62KtfwYVOISGd/ydF0
# 6DvJlgAnTHL0K0N9tdpOf9x/curc38YJgoWML7mZQIT4AmGbEy4x29JQaYqIAV2I
# 8CNROqxZYEFkmbR4LCB4YkWaZAD5Xv/3wEpwT6BQvs715ZENDAp4By+jqvE2/Zji
# MqscDpn/CLdr98pSEsI1kRLyoZ2ukMCbuqH7oWNjHK0BuSIozq5M3L9Qs+XC2Vhm
# gAkMNA/t5gLLDBVs1NsddEFJL41xwLSxIHhbtTrvAgMBAAGjggFJMIIBRTAdBgNV
# HQ4EFgQU2TvawYOUfSvkPC98ZHlfAkjwHtswHwYDVR0jBBgwFoAUn6cVXQBeYl2D
# 9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUy
# MDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUB
# Af8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQAD
# ggIBAGVu7cijKec/PQrWI9t42ex6PZvXmXmx2XYUAUEEZP2VF1zaA1XwsAi6w9gc
# eFS9ENyzHiVsw2FUo8a7hMMtqo238Ij5IW0a6p1EulU/VcT1wIvIqso+lwkUkKo+
# lX55+gC1gGYhRBzHHBPtYhDuBqDz6uQq+syQKhGopLSYq/wnWwp+Lzn4ba6Fn/VG
# 15JV1hk5k6P5JvjDOidMJOPsS2Aw38Ffflbl1PN3vAl0Z6liRWLzvV1KsLZOvVkX
# MBHtLjh2sJZmknqmElptU06w3EUkqBLKS6A4ZbNDfXxGvcxM+DazcGez6lQ9WAyK
# N3htQ4fYGUSwswzA5yiVNNmqDUdit1jWPGlQAj2KmMFBEg0v87vTln79/YuM2YlC
# igJUlVfbhp2lnnX1Kx9rMaipca33VuaoqjR8jT0iXixQeHiKHqumJAMGXIvu+a8J
# 6PBXFh69jipXBNn+jeC+X5HSUXFhL194gzg14bT5awNnuMtyLkwV643CixBjfPbp
# eDWiPRT276dxH25NT7EGYnwG2UJ2FDXdE0xfk/6StFg8HdcKn0mbpdo7X33mrfYA
# hmbWbMEYjrIeW+JdoQLlPMaI7Ute4+1dlTZf3ehAlsyh7e/z7kI8qtBqUZbJi6HZ
# rdXWnBuP5bQUSYQU+m7xMj6pg7UghBZRJG8WNe2Hk5vTaEwyMIIHcTCCBVmgAwIB
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
# UyBFU046MzcwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAEsgyDU/uw24JemZsfYhdPa1d4QQ
# oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcN
# AQELBQACBQDucnFFMCIYDzIwMjYxMDA4MTk0NTA5WhgPMjAyNjEwMDkxOTQ1MDla
# MHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAO5ycUUCAQAwCgIBAAICBwICAf8wBwIB
# AAICE3EwCgIFAO5zwsUCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoD
# AqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAEGtf
# ZjckXOYn8YTAw3N/eyIHDXAu99LS68IV/Fw0BOr0QVSbO3rcoQospotx+2RXSioI
# NyK4oViJeybPwEuiUF+pt0LF/hHxD/qPdmMLfsX3CSPm/z6YXLS6cP7iF0HYZLxK
# AVmJIFQKVLP9CUOG/50dLznT/qd6yoVFr5fWCTxIIzsGXruMIu1kJbQucY9sbZga
# WtuTECLfYYab9k2/+ntaT1cnrS7vyrHrINuc4dxFckOfYCey/cJZvQUzJqBRPtrW
# FsjWUFPyL0KpG+LMpv8yCekPNUMk3hKZOgPKOcu5D6PeDHMfDhg/a+plwYkUR50d
# 4Z8Vk9LCQhIlYB6u+zGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACHzpwaeSiMC6VAAEAAAIfMA0GCWCGSAFlAwQCAQUAoIIB
# SjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIJO2
# 9EWl4k9kMPHSsEd7XPccRa6SinufqCenbE4IhEmmMIH6BgsqhkiG9w0BCRACLzGB
# 6jCB5zCB5DCBvQQgsCQK31aQKwy1RGQW7pNjQ/dRd1GcKJi49mF7fKQt/BQwgZgw
# gYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh86cGnkojAu
# lQABAAACHzAiBCCS/H4nblYqcyIL+5TFJhovMalfT05Kn0tdfvTiH+85GTANBgkq
# hkiG9w0BAQsFAASCAgCuBGlzuAIQ2sRVhrXm5N9jIq2qywBUYvE5buwywg2P85+e
# x2AItrU+vjTCosxtxCCtGPnfFYO/CkxrfclpUhTNuPklRhOPnMulMoCadrOiz1Te
# E5rPDs9IdWIGS7OObJzrDjdvmRBdSqd0SkDPNuF8z9kQcX0S4uDaomHPEuoP2q7h
# kaTVDMQNxriClJvNEo9O5dB1EmWNZZWg5wXCejK6OVeMjnp9whpBCW3IGVVwkI+7
# OWgOAlA2UcuWK5SZWOQzBPNciwun1UhWfp6BxrTfR77TbrdfWFG9hoN2iaKEcoTX
# Buv4H+109zfZ/IkcUfkAePoW60mbwwkLNIZoqa4Y8CEO8x3IjWWtV9z/6GThxyY6
# szFlbC+dPPHP8XTU725T9DtP4jTT0CFMTjGMdkQ+0UfwAMt+xpttJrMmKHiilDkO
# BFrSWwiodBnEwRRsAjbE4fvsi6nFh6u8frFmE/ADWreoFIpBqWQoJZhurWCfcrdj
# edIzpBWSR8+4N803pdMIRufkPC49Ow5w/V9ZNLu1Y8xxgWX1/BUNCWwjb3TLKRHD
# +S58tq4a1RbS5ZerMusRIhVdDWJELdL6XPTBUXiiiEo2xt6RE/y3n/16T72VIIcc
# CHZ0l9S4aOV8GoPZJEf+sYaZSik269lxEYFu4t/Icxi+blwepbtgnYJAoRZnOQ==
# SIG # End signature block
