<#
.SYNOPSIS
  Install and verify Intel OpenVINO acceleration, with optional oneAPI/SYCL tooling.

.PARAMETER OpenVinoDeviceId
  Optional exact OpenVINO device such as GPU.1 or NPU.0. Device still declares
  the required class used for prerequisite validation.

.PARAMETER SyclDeviceSelector
  Optional ONEAPI_DEVICE_SELECTOR value such as level_zero:gpu:1 for
  same-vendor multi-adapter SYCL execution.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CPU', 'GPU', 'NPU')] [string] $Device = 'Auto',
    [ValidateSet('OpenVINO', 'SYCL', 'Full')] [string] $Profile = 'OpenVINO',
    [string] $OpenVinoDeviceId = '',
    [string] $SyclDeviceSelector = '',
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$intelGpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPDeviceID -match 'VEN_8086' -or $_.Name -match 'Intel' } |
    Select-Object -First 1)
$intelNpu = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'Intel.*(AI Boost|NPU)|Neural Processing Unit' } |
    Select-Object -First 1)
$intelPlan = $null
$planError = $null
try {
    $intelPlan = Resolve-IntelAiPlan `
        -Architecture $architecture `
        -Device $Device `
        -Profile $Profile `
        -IntelGpuPresent ($intelGpu.Count -gt 0) `
        -IntelNpuPresent ($intelNpu.Count -gt 0)
} catch {
    $planError = $_.Exception.Message
}
$selectedDevice = if ($intelPlan) { $intelPlan.Device } else { $Device }
$openVinoTarget = if ($OpenVinoDeviceId) { $OpenVinoDeviceId } else { $selectedDevice }
if (-not $planError -and $OpenVinoDeviceId -and $Profile -in @('OpenVINO', 'Full') -and
    $OpenVinoDeviceId -notmatch "^$([regex]::Escape($selectedDevice))(\.|$)") {
    $planError = "OpenVINO device '$OpenVinoDeviceId' does not match the requested $selectedDevice device class."
}
$catalog = (Get-AiCatalog).Components
$component = $catalog.IntelOpenVino
$report = New-AiWorkloadReport -Id 'intel-ai' -Request @{
    Device = $Device
    SelectedDevice = $selectedDevice
    Profile = $Profile
    OpenVinoDeviceId = $OpenVinoDeviceId
    SyclDeviceSelector = $SyclDeviceSelector
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'intel-ai' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
if (-not $PlanOnly) { Assert-AiAdministrator }
$openVinoAcquisitionIndex = $null
$oneApiAcquisitionIndex = $null
if ($Profile -in @('OpenVINO', 'Full')) {
    $openVinoAcquisitionIndex = $report.acquisitions.Count
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = $component.Component
        vendor = $component.Vendor
        architecture = $architecture
        maturity = $component.Maturity
        sourceType = $component.SourceType
        packages = $component.Packages
        versionPolicy = $component.VersionPolicy
        integrity = $component.Integrity
        cachePath = $component.CachePath
        installPath = $component.InstallPath
        reasonNormalChannelInsufficient = $component.NormalChannelLimitation
        expectedStableSource = $component.ExpectedStableSource
        migrationTrigger = $component.MigrationTrigger
        cleanupUpgrade = $component.CleanupUpgrade
        action = $(if ($planError) { 'blocked' } else { 'planned' })
    })
}
if ($Profile -in @('SYCL', 'Full')) {
    $oneApiAcquisitionIndex = $report.acquisitions.Count
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = $catalog.IntelOneApi.Component
        maturity = $catalog.IntelOneApi.Maturity
        sourceType = 'winget'
        packageId = $catalog.IntelOneApi.PackageId
        version = $catalog.IntelOneApi.Version
        versionPolicy = $catalog.IntelOneApi.VersionPolicy
        integrity = $catalog.IntelOneApi.Integrity
        cachePath = $catalog.IntelOneApi.CachePath
        installPath = $catalog.IntelOneApi.InstallPath
        reasonNormalChannelInsufficient = $catalog.IntelOneApi.NormalChannelLimitation
        expectedStableSource = $catalog.IntelOneApi.ExpectedStableSource
        migrationTrigger = $catalog.IntelOneApi.MigrationTrigger
        cleanupUpgrade = $catalog.IntelOneApi.CleanupUpgrade
        action = $(if ($planError) { 'blocked' } else { 'planned' })
    })
}
if ($planError) {
    [void]$report.result.blockers.Add($planError)
}
if ($report.result.blockers.Count -gt 0) {
    if ($PlanOnly) {
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: intel-ai'
        return
    }
    throw ($report.result.blockers -join ' ')
}
if ($Profile -in @('OpenVINO', 'Full')) {
    $vcRedistPackage = Ensure-AiWingetPackage -Id 'Microsoft.VCRedist.2015+.x64' -PlanOnly:$PlanOnly
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = 'Visual C++ Redistributable'
        sourceType = 'winget'
        packageId = $vcRedistPackage.Id
        architecture = $architecture
        action = $vcRedistPackage.Action
        packageEvidence = $(if ($PlanOnly) { $null } else { $vcRedistPackage.Evidence })
    })
    $pythonPackage = Ensure-AiWingetPackage -Id 'Python.Python.3.13' -PlanOnly:$PlanOnly
    Set-AiAcquisitionAction -Report $report -Index $openVinoAcquisitionIndex -Action $(if ($PlanOnly) { 'planned' } else { 'pending' })
    Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
        component = 'Python 3.13'
        sourceType = 'winget'
        packageId = 'Python.Python.3.13'
        action = $pythonPackage.Action
        packageEvidence = $(if ($PlanOnly) { $null } else { $pythonPackage.Evidence })
    })
}
if ($Profile -in @('SYCL', 'Full')) {
    $oneApi = Ensure-AiWingetPackage -Id 'Intel.OneAPI.Toolkit' -PlanOnly:$PlanOnly
    Set-AiAcquisitionAction -Report $report -Index $oneApiAcquisitionIndex -Action $oneApi.Action
}
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'openvino-inference' -Status $(if ($Profile -eq 'SYCL') { 'skipped' } else { 'planned' }) -Evidence @{ device = $openVinoTarget }
    Add-AiReportPhase -Report $report -Name 'sycl-kernel' -Status $(if ($Profile -eq 'OpenVINO') { 'skipped' } else { 'planned' }) -Evidence @{ device = 'GPU'; selector = $SyclDeviceSelector }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: intel-ai'
    return
}

if ($Profile -in @('OpenVINO', 'Full')) {
    $python = Get-Python313Path -Architecture X64
    $root = Join-Path $env:LOCALAPPDATA 'DevConfig\intel-ai\openvino'
    $venv = Join-Path $root '.venv'
    $statePath = Join-Path $root 'install-state.json'
    $expectedPackages = @{
        openvino = '2026.3.1'
        'openvino-tokenizers' = '2026.3.1.0'
        'openvino-genai' = '2026.3.1.0'
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) {
        Invoke-CheckedCommand -FilePath $python -ArgumentList @('-m', 'venv', $venv) -DisplayName 'OpenVINO environment creation'
    }
    $venvPython = Join-Path $venv 'Scripts\python.exe'
    $packagesCurrent = (Test-Path -LiteralPath $statePath) -and
        (Test-PythonDistributionVersions -PythonPath $venvPython -Expected $expectedPackages)
    if (-not $packagesCurrent) {
        $openvinoArguments = @('-m', 'pip', 'install', '--only-binary=:all:') + @($component.Packages)
        Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $openvinoArguments -DisplayName 'OpenVINO Runtime/GenAI installation'
        Set-Content -LiteralPath $statePath -Value ($expectedPackages | ConvertTo-Json -Compress) -Encoding ascii
    } else {
        Write-Host 'OPENVINO_PACKAGES_CURRENT: skipping package resolution and installation.'
    }
    $openvinoEvidence = (& $venvPython (Join-Path $PSScriptRoot 'openvino-smoke.py') $openVinoTarget 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $openvinoEvidence -notmatch '^OPENVINO_SMOKE=') {
        throw "OpenVINO $openVinoTarget inference failed: $openvinoEvidence"
    }
    $report.acceptance.openvino = $openvinoEvidence
    Set-AiAcquisitionAction -Report $report -Index $openVinoAcquisitionIndex -Action $(if ($packagesCurrent) { 'already-current' } else { 'installed-or-upgraded' })
}

if ($Profile -in @('SYCL', 'Full')) {
    [void](Ensure-AiVisualCppTools -Architecture X64)
    $setvars = Join-Path ${env:ProgramFiles(x86)} 'Intel\oneAPI\setvars.bat'
    if (-not (Test-Path $setvars)) { throw "oneAPI setvars.bat was not found at '$setvars'." }
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-sycl-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        $output = Join-Path $temporary 'sycl-smoke.exe'
        $selectorPrefix = if ($SyclDeviceSelector) { "set `"ONEAPI_DEVICE_SELECTOR=$SyclDeviceSelector`" && " } else { '' }
        $command = "$selectorPrefix" + "call `"$setvars`" >nul && icpx -fsycl `"$PSScriptRoot\sycl-smoke.cpp`" -o `"$output`" && `"$output`""
        $syclEvidence = (& $env:ComSpec /d /s /c $command 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $syclEvidence -notmatch 'SYCL_DEVICE_READY:') {
            throw "oneAPI SYCL GPU kernel failed: $syclEvidence"
        }
        $report.acceptance.sycl = [ordered]@{ selector = $SyclDeviceSelector; evidence = $syclEvidence }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
Write-Host "INTEL_AI_READY: profile=$Profile device=$selectedDevice"
Write-Host 'INSTALL_OK: intel-ai'

# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCsOKuU8vWXTZcI
# ZzWTObhJfNMyWIy1RqTdfTw9lL0VE6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIF+Nmhu7l5pfqCFxkTKWNEw/CKgoOvz96/AWIkwK0NfOMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAOm9UEbND+6LsZX1I
# nsMUOUajox5qVzObpIqMdJ9FkZRk4Jzw7S6N7vt3oA2b/G6WOLuui5bgmGa7Ld8Q
# KE/yxC74gEsGqmS7avfD8pt2bXbdxIVjlODVhNn/atNvkzcHk+QncnyDzlJxlsQs
# T2O19DFHBjBIkS5VtzW9bl3KiMYVVJEYw8bF72KezToXSrVjTxcV8MVkJe2ENGp6
# inSEIHK8VpUW/9Pa68h0iFS4ZdjbtJNk58RkmEN3A/v0nHZs/fEtxu9F7eLiAtrF
# RK/ZEIVL3KXP0UzipZH7WLmXnSc0otqh/+Uff06BLa794EDxgF9QCBhQUvnDOz/r
# gMs8nKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCUABuk42P65BhP
# EqKoiTjXiX9GYMUyAbrO8VpfwF6qbgIGaqpqJCQ+GBMyMDI2MTAwOTIxNDQ1Mi4x
# MDhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiY1tD5nQ5P2HwABAAACJjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDJaFw0yNzA1MTcxOTQwMDJa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046OTYwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/
# /w+ZZIL5RFFpVI8D3ZyuNu8IzcAEOD30OLYjh337rXjcrIlOSzpJc4ZeUxEyli6x
# 6F6zm4NR8dbPb9diDp/hOUzHWGxiA1Z3RXKBb/4F/ojyvN43SEGWqSfVc3I3BlsY
# T35ecVAJ9kVf90YOv29tFjJBBZkYvrT/DwwyRLscOyP4p+9/lyJjD+ULs3YXBhVr
# fZ+MbQB+BYKLqRvBKbj/wR9akNrMxQINoGaD5jZO/N/nSsmG2P1zv/cv4gSoMBnW
# eQIBkjd2I5w1DeXupp2vSiNmR5sA2ZkBK3yiQWaJvRxODlkfiyHk9Mkk/TrYTjmj
# PCbhe+uqhHNRy8UlbOvWsCq0tRtUykHv39DgqAfJNrE8OSt835rBzDprrcAhwmgf
# hoVi4AKeqwikY0nUa48K0Qy80XT4fiEA3ExEZNaRFo9Nq/GwbfgqKqGmc9xhKuRF
# cjtua4KHZvnAvpWgEFSOCkovXs/BcLnkEHM9xZ8iUag5CyhNqXYYE/z0pcXdYaNI
# kQ68EWmuvLm7g9oofV2vOm5GVNoghnkWG6nGPo/JwEgmA9oSS0EfvFRMWPA/gpSv
# F3shArKHnaEpVSSi3DNbyiuYiEs9Ko0IkZc8xKFeQRaqGRxrB+2r/7B3X81Tps99
# KhFwg+wD87od22F2MUg1x7twt3gaVnFk0IZIwUPCGwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFF3hn9fYJN2Y/Z9LVbBPIxAzXHsQMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA2Ux0tr9sYCjsq0FRyiVpx15OurNXv6Qk7iX+ArVPlz3w4tqjcTNm1dt3t
# Tua2wJMpJhPH8n7UXhmT98d5Du44Ll4adnse4SQfVg3QL6aRkXHnJUn8y9iftB/P
# y22n9xnwPFfj3QlDOSgLuHleu97U0iH2ZaluYabWXJihdiYpK8cPHFlqZOAiot0+
# GD8dP+RMuvpxt/F2LmYelpoZwriiFOUmlxEUV7xJHyZZlDquskeyuq01DTv91N4q
# M8cfPPhl/2pc4HeMf/nd2HouifJbDQFNd4WPhLzn0Sy3u1Zh3+S3tjQdqN+dyw60
# RaV+RXCoOLgFZ3MAg/GoDl+fvb5hy/1a71ctX8wEad1Pf6def2pqfl3wFc++hkF8
# DXXTZofJN4YVaN3InwbAGQDDkNK4lqecCixxmSKwidPynGeE5OtvNoK1pkLsm/i8
# F1RjGczZ/kSF2VDkqG866iQ+jVbGOQ6Du3eyyFcFKZoDJ4B5mEAS9aT2SKqllLey
# bOboH6r67siR5B/2Hnu7+KYuYZy0BEadtA6ngG4cnSR9JsrkhhsKmb11ujqwgJyN
# x92MsoGGwNgN1aI0QID8CsjCFwpfmMzlA44xHKYv3hmjxeqBS4uU5rQeiAnVgpJe
# aVGKm/lzPDtnppGV+7XhRp5b1ZxT/Z7Xxc+I7H7/jCtQDZoaZTCCB3EwggVZoAMC
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
# U1MgRVNOOjk2MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCi/fMxFtkqr7XMXdsRyWU0lSKH
# Z6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nM3RjAiGA8yMDI2MTAwOTA5NDk1OFoYDzIwMjYxMDEwMDk0OTU4
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuczdGAgEAMAcCAQACAgEtMAcCAQAC
# AhGpMAoCBQDudIjGAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBADRn1gIF
# Sa9li6/nFUkh/Ji86H/IrMygijFrLyJI/OYppuYAqZBiiAKxMPK2e3uJA+uwknCi
# uHGHozhiFiN/fhCeEpY2UxnqVRkoyuyrx0Coi0s2M2l+G5a1l09zMv9y6CwxEZUb
# Pqbwq7KIJKULHGwgX8KxdegqqvX2rgyb/z5EJEp+SrcPCx3ZL/SVabGq9HqTriW2
# HSZ78TQInQLwMdoE1HtwmQuXobNtxldSM4vQDqm03X5Ixqz/BQJneiqJ0QHmf7nQ
# Q3dG85/nMSySgXhacRYNjRQBttvVBPHskdEgPYwq5pnciu9uyfFxyyZEP3mRhAbb
# W872hCj2t8dXViAxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiY1tD5nQ5P2HwABAAACJjANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCCMDJv9
# eWwyM/szA/kFnh5Z2XfZOwKBAnZAMGrBmHZXqDCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIMwyXGFnTNsZRBrs6GN/BbV0okaNP3VBYqLFjUsFnbgqMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAImNbQ+Z0OT9h8A
# AQAAAiYwIgQgjJ2aXkgXmf+y/ZruhosMR+SuA3xIeWXJ2xuHkAqNN+swDQYJKoZI
# hvcNAQELBQAEggIAoo0QQaHfb1Xt7/OrxatX60hic7Ly6xbQ9cSW6kZttaIHaLVM
# nPVnKBd60g+B7bDETKnOo5u4UL9Pql6dnOumDdWdR3Ox540jQykNHRd7MSxdRRGC
# QONdS9+vQ2Jm7cMz8+cdLYCVLOJvCo58lWqkfWctVUnEoMQ/Ep8qVnFbvool9smf
# 920xIYrPP8iDaHoYp6AutH9bM54qtuWEhhjlLNzGJoiI+Xe+tts1Y3Rp/O1NgmOL
# nd+GOYuZ5ZIts+/clYn5nCmQcnpyMFjFAxkDsk83muH4zCFeyWM+EQKSYRYOkUKb
# 8Z8VJKa+jUAEchus20uzBJIATvAPEs0N2PoM/cKyxlPH06hoJKmNwMJE/hTXXiik
# RSE4FG6AGe6V6TK+BtI0mxziM8V6zBQErMvMZgX9vn24t9eZezg0OMBNgKGQG/h0
# 5mc14ShC8ZBPTX4ZFtvgxyM8VDdDMJiF1N5Sx9t++lDPG3vC+Y2+AA4zIcRHXBF0
# j5rAQmnr/l2THvTjhBW9ystN5qixX4+PqhtRvXXBUa0EtrPwear4/QzRkB2NunIo
# s1cGZMvyjlr3VX354R7jJ1dBDkpyFdcgwKkjeCzChL9s4hRtYBUuLm96f2JTXtpd
# UV/nJgzFzATnGR/k1iulhf1I/+CTZB6LgF69P6bZo10kD9+10PzU3lmcSzQ=
# SIG # End signature block
