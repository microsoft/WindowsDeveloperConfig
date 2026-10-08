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
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD0hRn2Xe+MHjxZ
# 5m3TGC7j/2Rd74QKBDNhSDM5UTglN6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIDoWUmn+CcMP2/ydRrD/Lekd2P4Y
# Hq8iExd0saJ5F+wHMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAnKRGpMlKjpo+9ROUPNoczdwo4kAbjSdpEN745xCtBtfnNJgOu3tCpt6zn/sV
# LjJT25jxMm1ydMEV3TNlPsQsnOQQKDQLGXjedlCitbl/ABYAV2ilU5BLhvZleY2S
# nBwVxfOxvIzWlQDmRGqCO3sHGHsQKyhkLqg1D/s3ciusWZMj6VyGs/rmwQ+fiA2L
# A9MyhCRGESMHj7st4CUz81KbsC0z4CkoGPqw1F6FDk1Cp+w70++l/OaA28RpFtOD
# aMvd3Of9G5fyTy9OIwlZHwWSTRbt0Ij4nCXJ2l04nLux6WjYbqMMQGXkxxTiaNQJ
# qki7UI7ZHX2TQblM9GJFhmRxn6GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAerVVVEAoSGe+aYseq4KCUpkrKImo882GawtvKphCWLgIGaqqLqwqAGBMy
# MDI2MTAwODAzMDIwNi4wNzVaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAiAk4ebgF7m0jgABAAACIDANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTJa
# Fw0yNzA1MTcxOTM5NTJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDRYY7yr7ijW6CR178uKveIMufutWOicxgJwKOce/2GOQce
# us6ZWfX14i3jNg3JOP7MGJMkOAucwWBwiA8URp+ZYkGjpVoVkGZsV27WjqLwpf2A
# wqBsJ/TzqwE7JFFaxup3Ldxj8GjdJymDFRrdVN/pYHoBFrjD1IkIDu8b1CWn8tgo
# miKRSY+STvJq99mVkdphMBIUGOegQny8qRd24VME0xi8Oomks9Zq9EjDeKHGpvAb
# XUEQ6m3cROoEPhTE/miweQH9TqJt3IOsqPv3L8urojB747XBC2y0CDIHlKLcLl3Z
# G8D7JXKnWTFen3msMPJpcvrQ3zUBVJrH/mI3RxHmCh9ppDP0uG1+PJwk6H/x+sfo
# G9hW64xoXkpx6DEfNZNfcXdKbXF28XEXdLNnzo3SLNVymeQJhNqOSKhnU84QnKmr
# jEk541JiurlDCkCWO9lUBUMb9x0nyfXUbNRPVLgP+PTMRdXOowJdYCzCQfN2ZqL0
# s4YI28F1Dbn7Bgw2E4P1E9unsvMzJHtzhS2Th3TpCfBbOGalIlF9x/DJZ/ssm/yy
# zT9YtIFeqmfNxBPTE3aOuh6HxmTICzfYAATvWNhBbo19QwsjPeA9JvhqTLC2KUNg
# rXroGy4eDZo0n7jFYjZkUih1Ty+8E6qEvV2Na6Z5gUyD5a+tHGDmq69CmUiHfwID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFNvInOCIhxGA8mY7l1g07UHvyNgzMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQCtKGBto1BSvm4WFI+J0NSyVhU1LHL7F3fbjZ2d
# 7F5Kn/FCTBZXpzrDVl63FLRNcIFpnJy4/nlg43r7T5sJPdo4Ms8ADSHQEJnHSu3x
# 9UpjCzREBPi9+nHhvDgRx/1WmBD6gQUZJLOhcN2TxW4KJyhinMtiBFtkNRZ2vmZ1
# MAdNXTm5d0Lwk3wzj+/f7VCCTWCXJSoqNa3VU/6sACHI97Evbnzg8bd3hxrfz6Cc
# CVuf77egvRHinthJuwSRePP7aVmcevb1nWUIAICdBebHQOrzNIeWBIQwvcFaS3SF
# c+49rqrwQOMFDR4FYBzS7b0QeBVxFuLL2iVu4KAHMNUhLLSD4iKLDFBNTOtTzTlh
# GvMgG77A1cjeQrDMHa6oReMDeUDqHUrxv8g7IRdIh+h0gDLkzN0xIuzli0Bv7Jty
# bGJbV6JxaDF4CzSCIMRpK59nI6iKo4LgnbQBZJW7+6akYsKG/pXPlfxNv2InpD10
# tSCkCvw9kr6W1+NRN+EuZczRgAwWlcK9XJZ3uu/v/oxHtO7/kmVIs51F9qV6Y2QN
# Xd6tU46YPrK98m2QDys+lvLNimK0e1xZ7Z1GawKohKGvlLALWDlZQqgHfJ31CB0L
# lIDI7iLyYTpd2iyKjqskbQiyMtICH+RmH/oCg7JOK0ZA3XIMba9aSWgBF3QZ6pG3
# EGeQqjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
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
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIIC
# NQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkYwMDItMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCTGA9v
# psJ6glqCLmI0rggGx4YEEqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nFe3TAiGA8yMDI2MTAwODAwMTQyMVoY
# DzIwMjYxMDA5MDAxNDIxWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucV7dAgEA
# MAcCAQACAieaMAcCAQACAhLSMAoCBQDucrBdAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBACjR5v0cVZOdGMAnoV+FrHADvduIbOwCumafzcWj+RzPzjfSlbqi
# J+bMY41PUlCjT/UXwpQpouj679MndtzyY/Q5LolWriUk/HdzWtClIoEbbiE0ppyS
# eqiuMJ1kM79B1GagtAH3VLASQrcN9s6Q9+LiQNvlgj2jvDMb9UK/eG9/3FtUk7lU
# QB/jPo1CKxkZvefnuQc1weRvdgbH+0ZWZ+wNxl/6+bwefZxOzLrx09mMCXTNAP2y
# nQO8mim5TEYTksmZMrR6292kPB6njghMi5mP/9njb+HyTTmtJMA6vIwbA0tpgV1V
# piHCIcb7ZvQ+dRPfrf1vAY5CVX1pMUa16/UxggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiAk4ebgF7m0jgABAAACIDANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCBQgbk13bkL2JEangTfRP46gPV1afuR9I4YNyr5pWpaiDCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EION7vyOlPA1VqlEp0QIVGlNd8S5YWBnK
# j97LuTWHSO2vMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIgJOHm4Be5tI4AAQAAAiAwIgQg/55tbzekP78zJ9GMptedn3fejrcos7sH
# zJANkoc8Sc8wDQYJKoZIhvcNAQELBQAEggIAb43dFdEpfR2OGOPtncnW5b32Nj9p
# Uekf8eYsrFPGPvc7C3vI2NPuCuG2CqoTe2MdpeuxX4URtSUInlXAMcA8XCRWjQmW
# UcWlMDI6ELb3hXUROBEL7aUluh9SJAI+TRZ9cB//C+UfqRidm9utymO7oVdmguUV
# Zhz5NOvObxYemv3gdnMk14GD86SuU+xfmhy4Lcf4WuRBNAeI+I/fAVpFUNuengoS
# hg3Q/JMNLKpJb1AtmR34r+awQbZhFvm2iVQOAxjv9rDQhr/o0YbNfKKfjMgyRy5Z
# mF9jjsOz6DE737Hq8OUUrOqTK+DElhuy5w/sfsYO3xL/h98Oqm/YavezuqzcbEvV
# huV2aNhJ46uWetTkZSSSyaSBltCU116zuSS3vDLhdYX38bc4aixtLQmFeXoBwTfP
# 6sRgZjg3DJ+mgKFHimRWlwB+oJ/1Rv4FHFUbQicpP7TE/sVqqQzLbotOCyV949UF
# zfnkrStTcTg/iscSEhBOixBV4CAWwSGg9CWHJU6LxTXfnH29YHuNfnL83R6XNNuJ
# cmxeXpzp0b8Eoy7bmrBkO0XtzzR9kIpZZ+VgbSfhaYuaOw1FiU7PKP5kzES+vQw7
# UqvI031cC+FSOHRzS4moZo6/w8hOY6YOMAdDC2wmAXYf1f4854OSSiE6740NoXcH
# ONnWP2EydgqaX8o=
# SIG # End signature block
