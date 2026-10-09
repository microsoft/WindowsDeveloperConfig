<#
.SYNOPSIS
  Install a hardware-selected llama.cpp backend, acquire a pinned small GGUF,
  and prove the selected backend with benchmark and inference evidence.

.PARAMETER Backend
  Auto prefers supported NVIDIA CUDA, AMD ROCm, Intel SYCL, Qualcomm Adreno
  OpenCL, x64 Vulkan, then CPU. OpenVINO is an explicit Windows x64 option.
  Explicit backend requests fail instead of silently selecting another backend.

.PARAMETER Device
  Optional llama.cpp runtime device identifier such as CUDA0, Vulkan0, or SYCL0.
  Use this to target a same-vendor secondary adapter. When omitted, the selected
  backend chooses its default device and the actual device is recorded.

.PARAMETER SkipModelSmoke
  Skip the default Qwen3-0.6B GGUF download and inference. The install then
  verifies only the CLI and does not claim workload readiness.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CUDA', 'ROCm', 'SYCL', 'OpenVINO', 'Vulkan', 'OpenCL', 'CPU')] [string] $Backend = 'Auto',
    [string] $Device = '',
    [switch] $SkipModelSmoke,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$driver = Get-NvidiaDriverInfo
$amdGpuName = Get-AmdGpuName
$amdGfxTarget = if ($amdGpuName) { Get-AmdGfxTarget -GpuName $amdGpuName } else { $null }
$intelGpuName = Get-IntelGpuName
$qualcommGpuName = Get-QualcommGpuName
$hasOpenCl = Test-AiOpenClRuntimeAvailable
$vulkanGpuName = Get-VulkanGpuName
$hasVulkan = Test-AiVulkanRuntimeAvailable -GpuName $vulkanGpuName
$component = (Get-AiCatalog).Components.LlamaCppRolling
$report = New-AiWorkloadReport -Id 'llama.cpp' -Request @{
    Backend = $Backend
    Device = $Device
    SkipModelSmoke = [bool]$SkipModelSmoke
    PlanOnly = [bool]$PlanOnly
    SelectedBackend = $null
    DetectedNvidiaDevice = $(if ($driver) { $driver.Name } else { $null })
    NvidiaDriverVersion = $(if ($driver) { $driver.DriverVersion.ToString() } else { $null })
    NvidiaComputeCapability = $(if ($driver) { $driver.ComputeCapability.ToString() } else { $null })
    DetectedAmdDevice = $amdGpuName
    DetectedIntelDevice = $intelGpuName
    DetectedQualcommDevice = $qualcommGpuName
    OpenClAvailable = $hasOpenCl
    VulkanAvailable = $hasVulkan
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'llama.cpp' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
try {
    $plan = Resolve-LlamaCppInstallPlan `
        -Architecture $architecture `
        -Backend $Backend `
        -HasNvidia ([bool]$driver) `
        -DriverVersion $(if ($driver) { $driver.DriverVersion } else { [version]'0.0' }) `
        -ComputeCapability $(if ($driver) { $driver.ComputeCapability } else { [version]'0.0' }) `
        -NvidiaGpuName $(if ($driver) { $driver.Name } else { $null }) `
        -AmdGpuName $amdGpuName `
        -AmdGfxTarget $amdGfxTarget `
        -IntelGpuName $intelGpuName `
        -QualcommGpuName $qualcommGpuName `
        -HasOpenCl $hasOpenCl `
        -HasVulkan $hasVulkan `
        -VulkanGpuName $vulkanGpuName
} catch {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($_.Exception.Message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: llama.cpp'
        return
    }
    throw
}
$report.request.SelectedBackend = $plan.Backend
$report.request.SelectedVendor = $plan.Vendor
$report.request.SelectedDevice = $plan.DeviceName
$report.request.SelectedRuntime = $plan.Runtime
$report.result.fallbackUsed = $Backend -eq 'Auto' -and $plan.Backend -in @('Vulkan', 'CPU')
if ($report.result.fallbackUsed) {
    [void]$report.result.warnings.Add("Auto selected the compatibility fallback '$($plan.Backend)'; this is not reported as vendor-native acceleration.")
}
if (-not $PlanOnly) { Assert-AiAdministrator }
$vcRedistPackage = Ensure-AiWingetPackage -Id "Microsoft.VCRedist.2015+.$($architecture.ToLowerInvariant())" -PlanOnly:$PlanOnly
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = 'Visual C++ Redistributable'
    sourceType = 'winget'
    packageId = $vcRedistPackage.Id
    architecture = $architecture
    action = $vcRedistPackage.Action
    packageEvidence = $(if ($PlanOnly) { $null } else { $vcRedistPackage.Evidence })
})
$legacyDestination = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp'
$destination = Join-Path $legacyDestination 'runtime'
$assetCache = Join-Path $legacyDestination 'asset-cache'
if ($PlanOnly) {
    $acquisition = [pscustomobject]@{
        Action = 'resolve-rolling-release'
        Tag = $null
        Assets = @()
        Source = 'github'
        CacheDirectory = $assetCache
    }
} else {
    $acquisition = Install-VerifiedGitHubReleaseAssets `
        -Repository $component.Repository `
        -AssetPatterns $plan.AssetPatterns `
        -Destination $destination `
        -VersionMarker '.devconfig-version' `
        -RequiredFile @('llama-cli.exe', 'llama-bench.exe') `
        -CacheDirectory $assetCache
    Remove-UserPathEntry -Path $legacyDestination
    Add-UserPathEntry -Path $destination -Prepend
    $llamaCli = Join-Path $destination 'llama-cli.exe'
    $llamaBench = Join-Path $destination 'llama-bench.exe'
    if (-not (Test-Path -LiteralPath $llamaCli) -or -not (Test-Path -LiteralPath $llamaBench)) {
        throw "The verified $($acquisition.Tag) $($plan.Runtime) asset set was extracted to '$destination', but required llama.cpp executables were not found."
    }
}
$assetIdentity = @($acquisition.Assets | ForEach-Object {
    [ordered]@{
        name = $_.name
        sha256 = ([string]$_.digest).Substring(7)
        bytes = $_.size
        cachePath = Join-Path (Join-Path $assetCache $acquisition.Tag) $_.name
    }
})
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $plan.Vendor
    architecture = $architecture
    maturity = $plan.Maturity
    sourceType = $component.SourceType
    repository = $component.Repository
    backend = $plan.Backend
    runtime = $plan.Runtime
    selectedDevice = $plan.DeviceName
    requestedRuntimeDevice = $Device
    driverPrecondition = $(if ($plan.Backend -eq 'CUDA' -and $driver) { "NVIDIA $($driver.DriverVersion), compute capability $($driver.ComputeCapability)" } else { 'Use the installed vendor display/compute driver reported in host.gpus; this flow does not replace GPU drivers.' })
    amdGfxTarget = $plan.AmdGfxTarget
    assetPatterns = $plan.AssetPatterns
    resolvedTag = $acquisition.Tag
    resolvedAssets = $assetIdentity
    versionPolicy = $plan.VersionPolicy
    integrity = $component.Integrity
    cachePath = $assetCache
    installPath = $destination
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    action = $acquisition.Action
})
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'model-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'planned' }) -Evidence @{
        model = 'Qwen3-0.6B-Q4_K_M.gguf'
        backend = $plan.Backend
        runtime = $plan.Runtime
        device = $plan.DeviceName
    }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host 'PLAN_OK: llama.cpp'
    return
}

Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--version') -DisplayName 'llama.cpp CLI verification'
Invoke-CheckedCommand -FilePath $llamaCli -ArgumentList @('--help') -DisplayName 'llama.cpp help verification'
$statePath = Join-Path $legacyDestination 'selected-backend.json'
Write-DevConfigTextFile -Path $statePath -Content ([ordered]@{
    backend = $plan.Backend
    runtime = $plan.Runtime
    expectedDevice = $plan.DeviceName
    requestedDevice = $Device
} | ConvertTo-Json -Compress)

$modelPlan = Get-LlamaModelSmokePlan
$inferenceEvidence = $null
if ($SkipModelSmoke) {
    Write-Warning 'LLAMA_CPP_MODEL_SMOKE_SKIPPED: CLI is ready, but no model inference was performed.'
} else {
    $modelDirectory = Join-Path $env:LOCALAPPDATA 'DevConfig\llama.cpp\models'
    $modelPath = Join-Path $modelDirectory $modelPlan.FileName
    Write-Host "Downloading pinned $($modelPlan.Repository) model $($modelPlan.FileName) (approximately $([math]::Round($modelPlan.Size / 1MB)) MB, $($modelPlan.License))."
    Install-VerifiedDownload `
        -Uri $modelPlan.Url `
        -Destination $modelPath `
        -Sha256 $modelPlan.Sha256 `
        -ExpectedSize $modelPlan.Size
    $benchArguments = @(
        '-m', $modelPath,
        '-ngl', $(if ($plan.Backend -eq 'CPU') { '0' } else { '999' }),
        '-p', '32', '-n', '1', '-r', '1', '-o', 'json', '-v'
    )
    if ($plan.Backend -eq 'CPU') {
        $benchArguments += @('--device', 'none')
    } elseif ($Device) {
        $benchArguments += @('--device', $Device)
    }
    $benchmarkResult = Invoke-AiNativeCommandSeparated `
        -FilePath $llamaBench `
        -Arguments $benchArguments `
        -TimeoutSeconds 300
    $benchmark = $benchmarkResult.StandardOutput.Trim()
    if ($benchmarkResult.ExitCode -ne 0) {
        throw "llama-bench failed while collecting backend evidence (exit $($benchmarkResult.ExitCode)): $($benchmarkResult.StandardError)"
    }
    $parsedBenchmark = ConvertFrom-AiJsonArrayWithDiagnostics -Json $benchmark -Diagnostics $benchmarkResult.StandardError
    $backendEvidence = Get-LlamaBenchmarkBackendEvidence `
        -Data @($parsedBenchmark.Data) `
        -Diagnostics $parsedBenchmark.Diagnostics `
        -Backend $plan.Backend `
        -ExpectedDeviceName $(if ($Device) { $null } else { $plan.DeviceName }) `
        -RequestedDevice $Device
    $arguments = Get-LlamaInferenceArguments -ModelPath $modelPath -Marker $modelPlan.Marker
    $arguments += @('-ngl', $(if ($plan.Backend -eq 'CPU') { '0' } else { '999' }))
    if ($plan.Backend -eq 'CPU') {
        $arguments += @('--device', 'none')
    } elseif ($Device) {
        $arguments += @('--device', $Device)
    }
    $inferenceResult = Invoke-AiNativeCommandSeparated `
        -FilePath $llamaCli `
        -Arguments $arguments `
        -TimeoutSeconds 300
    $output = @(
        $inferenceResult.StandardOutput
        $inferenceResult.StandardError
    ) -join "`n"
    $output = $output.Trim()
    if ($inferenceResult.ExitCode -ne 0 -or $output -notmatch [regex]::Escape($modelPlan.Marker)) {
        throw "llama.cpp model inference did not produce marker '$($modelPlan.Marker)' (exit $($inferenceResult.ExitCode)). Output: $output"
    }
    $report.acceptance.inference = [ordered]@{
        model = $modelPlan.FileName
        modelSha256 = $modelPlan.Sha256
        modelBytes = $modelPlan.Size
        modelLicense = $modelPlan.License
        marker = $modelPlan.Marker
        backendPlan = $plan.Backend
        runtimePlan = $plan.Runtime
        selectedVendor = $plan.Vendor
        selectedDevice = $plan.DeviceName
        requestedRuntimeDevice = $Device
        requestedRuntimeDevices = $backendEvidence.RequestedDevices
        actualRuntimeDevices = $backendEvidence.GpuInfo
        amdGfxTarget = $plan.AmdGfxTarget
        backendEvidence = $backendEvidence
        benchmark = $parsedBenchmark.Data
        benchmarkJson = $parsedBenchmark.Json
        benchmarkDiagnostics = $parsedBenchmark.Diagnostics
        benchmarkJsonRepaired = $parsedBenchmark.JsonRepaired
    }
    $inferenceEvidence = [ordered]@{
        model = $modelPlan.FileName
        marker = $modelPlan.Marker
        backend = $plan.Backend
        runtime = $plan.Runtime
        device = $backendEvidence.GpuInfo
        hardwareAccelerated = $backendEvidence.HardwareAccelerated
        actualOffloadedLayers = $backendEvidence.ActualOffloadedLayers
        benchmarkJsonRepaired = $parsedBenchmark.JsonRepaired
    }
    Write-Host "LLAMA_CPP_READY: architecture=$architecture, backend=$($plan.Backend), runtime=$($plan.Runtime), device=$($backendEvidence.GpuInfo -join ','), model=$($modelPlan.FileName), sha256=$($modelPlan.Sha256)."
}
Add-AiReportPhase -Report $report -Name 'llama-inference' -Status $(if ($SkipModelSmoke) { 'skipped' } else { 'ready' }) -Evidence $inferenceEvidence
Complete-AiWorkloadReport -Report $report -Ready (-not $SkipModelSmoke) -Path $ReportPath
Write-Host 'INSTALL_OK: llama.cpp'

# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD0hRn2Xe+MHjxZ
# 5m3TGC7j/2Rd74QKBDNhSDM5UTglN6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIDoWUmn+CcMP2/ydRrD/Lekd2P4YHq8iExd0saJ5F+wHMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAgHc7WonG9BPg0/Cn
# +Kj1fMMCTk2p4M6OxtWnoejGSleL3zxXwjz/G++OCTrirpU8D280ns4/vw38uki6
# 9+mLCDoVftcsnqAln8w6s6esmQL0CdjSSKS6AiEip1ev8D+IhGQtuCJ0KsXBk5nJ
# ZkL87K9PjHaV99pBN3lRy1WFYXNIbFZd9b4UxLyNHAu2n8Cvw8RdIomZvoufDZTv
# DSUtfM4jxDAoFiwZo6We8kI4nYh+P0ivTVQudLOk6wfj7NneIvBoRo/YFXq0BCcu
# I3CAVGEN5V3UbXmM2WlIo1mrKzCouf0dWi4BnVA1SXdjs1fGXUDhs1LfHQx/tSF9
# CeOliqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAheDTTdHlOXBSs
# CLlZanoqIfA4SnkABacluukvlt/+hAIGaqqMDwjvGBMyMDI2MTAwOTIxNDQ1NC40
# NzVaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiAk4ebgF7m0jgABAAACIDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTJaFw0yNzA1MTcxOTM5NTJa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDR
# YY7yr7ijW6CR178uKveIMufutWOicxgJwKOce/2GOQceus6ZWfX14i3jNg3JOP7M
# GJMkOAucwWBwiA8URp+ZYkGjpVoVkGZsV27WjqLwpf2AwqBsJ/TzqwE7JFFaxup3
# Ldxj8GjdJymDFRrdVN/pYHoBFrjD1IkIDu8b1CWn8tgomiKRSY+STvJq99mVkdph
# MBIUGOegQny8qRd24VME0xi8Oomks9Zq9EjDeKHGpvAbXUEQ6m3cROoEPhTE/miw
# eQH9TqJt3IOsqPv3L8urojB747XBC2y0CDIHlKLcLl3ZG8D7JXKnWTFen3msMPJp
# cvrQ3zUBVJrH/mI3RxHmCh9ppDP0uG1+PJwk6H/x+sfoG9hW64xoXkpx6DEfNZNf
# cXdKbXF28XEXdLNnzo3SLNVymeQJhNqOSKhnU84QnKmrjEk541JiurlDCkCWO9lU
# BUMb9x0nyfXUbNRPVLgP+PTMRdXOowJdYCzCQfN2ZqL0s4YI28F1Dbn7Bgw2E4P1
# E9unsvMzJHtzhS2Th3TpCfBbOGalIlF9x/DJZ/ssm/yyzT9YtIFeqmfNxBPTE3aO
# uh6HxmTICzfYAATvWNhBbo19QwsjPeA9JvhqTLC2KUNgrXroGy4eDZo0n7jFYjZk
# Uih1Ty+8E6qEvV2Na6Z5gUyD5a+tHGDmq69CmUiHfwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFNvInOCIhxGA8mY7l1g07UHvyNgzMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQCtKGBto1BSvm4WFI+J0NSyVhU1LHL7F3fbjZ2d7F5Kn/FCTBZXpzrDVl63
# FLRNcIFpnJy4/nlg43r7T5sJPdo4Ms8ADSHQEJnHSu3x9UpjCzREBPi9+nHhvDgR
# x/1WmBD6gQUZJLOhcN2TxW4KJyhinMtiBFtkNRZ2vmZ1MAdNXTm5d0Lwk3wzj+/f
# 7VCCTWCXJSoqNa3VU/6sACHI97Evbnzg8bd3hxrfz6CcCVuf77egvRHinthJuwSR
# ePP7aVmcevb1nWUIAICdBebHQOrzNIeWBIQwvcFaS3SFc+49rqrwQOMFDR4FYBzS
# 7b0QeBVxFuLL2iVu4KAHMNUhLLSD4iKLDFBNTOtTzTlhGvMgG77A1cjeQrDMHa6o
# ReMDeUDqHUrxv8g7IRdIh+h0gDLkzN0xIuzli0Bv7JtybGJbV6JxaDF4CzSCIMRp
# K59nI6iKo4LgnbQBZJW7+6akYsKG/pXPlfxNv2InpD10tSCkCvw9kr6W1+NRN+Eu
# ZczRgAwWlcK9XJZ3uu/v/oxHtO7/kmVIs51F9qV6Y2QNXd6tU46YPrK98m2QDys+
# lvLNimK0e1xZ7Z1GawKohKGvlLALWDlZQqgHfJ31CB0LlIDI7iLyYTpd2iyKjqsk
# bQiyMtICH+RmH/oCg7JOK0ZA3XIMba9aSWgBF3QZ6pG3EGeQqjCCB3EwggVZoAMC
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
# U1MgRVNOOkYwMDItMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCTGA9vpsJ6glqCLmI0rggGx4YE
# EqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nNZHDAiGA8yMDI2MTAwOTEyMTQyMFoYDzIwMjYxMDEwMTIxNDIw
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuc1kcAgEAMAcCAQACAgRbMAcCAQAC
# AhJjMAoCBQDudKqcAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAECHcr71
# F8GfmscUOXc66r9BYZ0mfkWtlI8kCZqBgik1ir/05XwGMky9tkwwKw2ky6R85/vY
# SVONh/7iErs5CKmCYhL1Hp1qN3WblD/MeK8m1yL1sk+0oTQMbCjFRrRxWoNuCsbp
# WFFDEgUh/cPwarU+QnbhWNruNjnUdS2IF2RUJ6mQoH6wSsk1tGZXWsR7HAC8GD9+
# 80lWzT0Oh1Db3gxZy9DGpynOuIvdlxNIftUO21kvArHtrSGau77tJD+NpfgEAd+X
# GSokoAOxi/MSTSyitgYuFSNgAxJog+dCLm/Myj8wwaWJm8OqRJM+mrpwOcG7Owhv
# syJNC70yLFqB0aYxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiAk4ebgF7m0jgABAAACIDANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCD2GeTY
# 1oLWbMvlcwBMB1ofw6ABUm9dNuxoDzebKieAajCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EION7vyOlPA1VqlEp0QIVGlNd8S5YWBnKj97LuTWHSO2vMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIgJOHm4Be5tI4A
# AQAAAiAwIgQg8EcMB/Fe+UUQOpAmv7YC1QRNTCF4MYvnVuAGY0kVzOIwDQYJKoZI
# hvcNAQELBQAEggIAFVAc34VDOIyYwkMTLM/K2aTxJG6Ts4AkO2fvB3Aa/dF+fA0f
# JsPde0xDhl+9YL0Junl+k17dpGfQYRAnboQEB46TLqF0QXb2EbEkVlyBrw14I2X7
# KEzjcSy7cnqjd2ENsWM13Uz7q91hbx0kqb7aQhu/0scr/VSKcvZcI2wyhIFG2pUs
# l9b6jf1lh+BuLC2FkGAW8bkOtPrLCeKeaJo6pplB6LHFeLLkgL6mGoxRx855p9Vs
# PIwGcCydwfTBq3sd8OTs9iMjeQ2BLfqQ0nhMEAMIgA5pvyno02Kosm5Z+ZaFGAFE
# efiIp1oeHCkbE4vmj/QID7Oz3JAYNX4sOrbp6VBtCQ7L3hEnOqurCASZkPbsef+7
# FYUt2OF6jcxBMna79KzhIqt4SU03TorFZtl4VMvJJBcQNEPY1BMpWlkwDQTLtaic
# J6G9zlD1i08tS0plPIyfV5Q3xQLKU4uBOfwoxSDpb80AZ47L4oLuoBHTN13eoqpc
# K+0gYrxel11vXvGfZ7sdmPL6i+Y51VKdCku4emIiXjp9PsQ9vEwiHf0OaJvT2EDU
# WTu0Yf2pAGeNwqW7XUmo+G+dHYQGgSliPUydpqisduEusiVMQvR/vGhSN7N+Nfyx
# iuqqgZmgqaFPSLW92O183jHLRlCV02iLkDDn02qYEhqRs9g4ZgYMIyxC+zY=
# SIG # End signature block
