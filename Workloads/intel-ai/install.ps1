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
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCsOKuU8vWXTZcI
# ZzWTObhJfNMyWIy1RqTdfTw9lL0VE6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIF+Nmhu7l5pfqCFxkTKWNEw/CKgo
# Ovz96/AWIkwK0NfOMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAQnKzuRlxiqQrucF6aS/BVZ6XltKCAGqB4qozpynqLkNX+UCAWg/x5mkdwHoQ
# GZ/0T+mBN1nFccZKFgRLmV0sJcHgOKhxtZwA2Vujewsd24PbldE7/EHqDzEhRZwo
# a2NMtyMrf8HhinXh2mW/PLaWtMD2Ke8gaXMhimyBB7FHpSrUO0cX6mjCGNrFJu9O
# H3NhOU0yjbC7TpVLpT+cILoojvEnKHBeh079Dn5Q1gjfxpBkHFvCozKfSzujy2GS
# Z9fSp1+FjtnqCCQ767RVxMJREq+MUzwqzIowBHnwlmnJ0rN5bl2htUvkoZvenGTV
# G1BXBMHtNzGd9RwErg9o/wAyw6GCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCCbY6kfgOQ1hamn807UR+BSR8NLpeexuVdIF/37ryDPUAIGasTk6beTGBMy
# MDI2MTAwODAzMDIwMy41NDlaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoz
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACGqmgHQagD0OqAAEAAAIaMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyOFoXDTI2MTExMzE4NDgyOFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjMyMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAmYEAwSTz79q2V3ZWzQ5Ev7RK
# gadQtMBy7+V3XQ8R0NL8R9mupxcqJQ/KPeZGJTER+9Qq/t7HOQfBbDy6e0TepvBF
# V/RY3w+LOPMKn0Uoh2/8IvdSbJ8qAWRVoz2S9VrJzZpB8/f5rQcRETgX/t8N66D2
# JlEXv4fZQB7XzcJMXr1puhuXbOt9RYEyN1Q3Z7YjRkhfBsRc+SD/C9F4iwZqfQgo
# 82GG4wguIhjJU7+XMfrv4vxAFNVg3mn1PoMWGZWio+e14+PGYPVLKlad+0IhdHK5
# AgPyXKkqAhEZpYhYYVEItHOOvqrwukxVAJXMvWA3GatWkRZn33WDJVtghCW6XPLi
# 1cDKiGE5UcXZSV4OjQIUB8vp2LUMRXud5I49FIBcE9nT00z8A+EekrPM+OAk07aD
# fwZbdmZ56j7ub5fNDLf8yIb8QxZ8Mr4RwWy/czBuV5rkWQQ+msjJ5AKtYZxJdnaZ
# ehUgUNArU/u36SH1eXKMQGRXr/xeKFGI8vvv5Jl1knZ8UqEQr9PxDbis7OXp2WSM
# K5lLGdYVH8VownYF3sbOiRkx5Q5GaEyTehOQp2SfdbsJZlg0SXmHphGnoW1/gQ/5
# P6BgSq4PAWIZaDJj6AvLLCdbURgR5apNQQed2zYUgUbjACA/TomA8Ll7Arrv2oZG
# iUO5Vdi4xxtA3BRTQTUCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBTwqyIJ3QMoPasD
# cGdGovbaY8IlNjAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEA1a72WFq7B6bJT3VO
# J21nnToPJ9O/q51bw1bhPfQy67uy+f8x8akipzNL2k5b6mtxuPbZGpBqpBKguDwQ
# mxVpX8cGmafeo3wGr4a8Yk6Sy09tEh/Nwwlsyq7BRrJNn6bGOB8iG4OTy+pmMUh7
# FejNPRgvgeo/OPytm4NNrMMg98UVlrZxGNOYsifpRJFg5jE/Yu6lqFa1lTm9cHuP
# YxWa2oEwC0sEAsTFb69iKpN0sO19xBZCr0h5ClU9Pgo6ekiJb7QJoDzrDoPQHwbN
# A87Cto7TLuphj0m9l/I70gLjEq53SHjuURzwpmNxdm18Qg+rlkaMC6Y2KukOfJ7o
# CSu9vcNGQM+inl9gsNgirZ6yJk9VsXEsoTtoR7fMNU6Py6ufJQGMTmq6ZCq2eIGO
# XWMBb79ZF6tiKTa4qami3US0mTY41J129XmAglVy+ujSZkHu2lHJDRHs7FjnIXZV
# UE5pl6yUIl23jG50fRTLQcStdwY/LvJUgEHCIzjvlLTqLt6JVR5bcs5aN4Dh0YPG
# 95B9iDMZrq4rli5SnGNWev5LLsDY1fbrK6uVpD+psvSLsNpht27QcHRsYdAMALXM
# +HNsz2LZ8xiOfwt6rOsVWXoiHV86/TeMy5TZFUl7qB59INoMSJgDRladVXeT9fwO
# uirFIoqgjKGk3vO2bELrYMN0QVwwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjoz
# MjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUA8YrutmKpSrubCaAYsU4pt1Ft8DaggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5xXXEwIhgPMjAyNjEwMDgwMDA4MTdaGA8yMDI2MTAwOTAwMDgxN1owdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7nFdcQIBADAHAgEAAgIEFDAHAgEAAgIUGDAKAgUA
# 7nKu8QIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQCd72mVrIipGH3ktDLg
# 1iMiR0jZOtGScGc04HX6kluCWy8Swdtm40QRAIJxN0/BQaXw3Av2Fuw6hwVIY//Y
# ++YSgyS03vyX26xWhKr+G64pSfBBO8/1Cia2whvohh8GagtCzsubWQSaWyj/RbBl
# Cfxs+EytWjJMcuHbrTu8/4eTviuS0IzXBVw073Hx0x2rVssQhK3R8PYOWa50zHd2
# Gi7CyPV30+wVjIBNW/kS06KVuKaGJl3uGLtWLOKeML6rkHrGju4ui62mqIyNPT34
# DZOGSOnDlU0E4POQsS5qtyexL6SKrMdLbnzYyhB7VeH5DPdrdX9ttDce6UiM8FJR
# IO40MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIaqaAdBqAPQ6oAAQAAAhowDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQg2mXJoeaGSy1w80Iu
# pPKHYeY3b+3cSrd8k/S5dwhmHokwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCCdeiHHrbtpKcwB20doVU89WHIOH8S7w37uaHcDmemK+zCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACGqmgHQagD0OqAAEAAAIaMCIE
# IO2k83EQBsuq6YEbpuAx2gvEmgfqn0TzwELyxkMOcUsxMA0GCSqGSIb3DQEBCwUA
# BIICAIvMcDJXcsUso8pEmzE9jIcBKriyVIfr/paxCt6GCKrKW6jIbG+VUZJpjJ2p
# Y/opJpsXQ+JKDpCm/cY71QGYcWHBS0VDgMN18eosThY5La4AqGU1ncUWu+HvBo8t
# Ov72z27ZybJg8etkb6miTBJtroxa+BDJo5sVFAkPashscsdvDA5SGG24McZgQ0PA
# U5FVJ2sooKs/hdpI5lYWFuDcjAqjoOH88cuZIf2yZLHsxcQUXEVAkSs4u9ICO5qC
# YwG4T6SpNhLRuHojsvQIvPQlRsR+qYZncJYFozCttG5K8fN3d+MaPI1xjs0re/uU
# VDdWXug6im8VX8mOvfHpBVBvcq2Cf8MWi2B9CkI2kSoSx1c3D9CkT6WuyHQeUatL
# GBQoW9mx/USf7anijAEi7FOfaU+N5y6KOdR+l6OJuq1+D5CJ7wsJszgaw+l5OU1X
# YKOQdWAJ3/BrMgTVbxT3ukwBtLBw7Vux94sDwuXbn+t1kaKRh254FFEYN5ZD5L6N
# LxIkayfyO1IPcVDg9y1ydrMEnJOJuDqRVtCK8wX3r9fB/CQ01UMCcNLV78cav/aN
# dMeNwqa0NBRgvJWS7j449+/9fnabjG0ajbTwKKLS4BhLeZGvfFB+mCHai9QemROU
# QEOy22WANpGAjnctAzaSzJQIjqGYqbR1NYmznZAKzBAzJVru
# SIG # End signature block
