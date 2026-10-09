<#
.SYNOPSIS
  Install the NVIDIA CUDA Toolkit and compile/execute a minimal GPU kernel.

.PARAMETER ToolkitOnly
  Permit installing/verifying nvcc when no usable NVIDIA GPU and driver are
  present. By default the flow fails before installation when no NVIDIA GPU is
  detected and fails after installation when nvidia-smi is not usable.

.PARAMETER SkipWorkloadSmoke
  Skip compiling and executing the CUDA kernel. The default proves that the
  compiler, host toolchain, driver, and GPU work together.

.PARAMETER DeviceIndex
  Zero-based NVIDIA device index used for nvidia-smi qualification and kernel
  execution on same-vendor multi-adapter systems.
#>
[CmdletBinding()]
param(
    [switch] $ToolkitOnly,
    [switch] $SkipWorkloadSmoke,
    [ValidateRange(0, 63)] [int] $DeviceIndex = 0,
    [switch] $PlanOnly,
    [string] $ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\_common\ai-report.ps1')

$architecture = Get-DevConfigArchitecture
$catalog = (Get-AiCatalog).Components
$component = if ($architecture -eq 'Arm64') { $catalog.CudaArm64 } else { $catalog.CudaX64 }
$report = New-AiWorkloadReport -Id 'cuda' -Request @{
    ToolkitOnly = [bool]$ToolkitOnly
    SkipWorkloadSmoke = [bool]$SkipWorkloadSmoke
    DeviceIndex = $DeviceIndex
    PlanOnly = [bool]$PlanOnly
}
if (-not $ReportPath) { $ReportPath = Get-AiDefaultReportPath -Id 'cuda' }
trap {
    Write-AiFailureReport -Report $report -Path $ReportPath -ErrorRecord $_
    throw $_
}
try {
    $plan = Resolve-CudaInstallPlan -Architecture $architecture -WindowsBuild (Get-WindowsBuildNumber)
} catch {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($_.Exception.Message)
        Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
        Write-Host 'PLAN_UNSUPPORTED: cuda'
        return
    }
    throw
}
if (-not $PlanOnly) { Assert-AiAdministrator }

$gpu = Get-NvidiaGpu
$driver = $null
$driverError = $null
if ($gpu) {
    try {
        $driver = Get-NvidiaDriverInfo -DeviceIndex $DeviceIndex
    } catch {
        $driverError = $_.Exception.Message
    }
}
if (-not $gpu -and -not $ToolkitOnly) {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add('No NVIDIA GPU detected; default kernel acceptance would fail. Use -ToolkitOnly for compiler-only planning.')
    } else {
    throw "No NVIDIA GPU was detected. CUDA Toolkit can be installed without a GPU only with -ToolkitOnly; GPU execution requires supported NVIDIA hardware and a current driver."
    }
}
if ($driverError) {
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($driverError)
    } else {
        throw $driverError
    }
}
if ($gpu -and -not $driver -and -not $driverError -and -not $ToolkitOnly) {
    $message = "NVIDIA device index $DeviceIndex is present, but nvidia-smi did not report a usable driver. Install/update the NVIDIA driver and rerun."
    if ($PlanOnly) {
        [void]$report.result.blockers.Add($message)
    } else {
        throw $message
    }
}
if ($driver -and -not $ToolkitOnly) {
    $hardwareError = if ($architecture -eq 'Arm64' -and
        $driver.ComputeCapability.Major -lt 12) {
        "CUDA 13.4 ARM64 Developer Preview requires an NVIDIA RTX Spark-class GPU with compute capability 12.x; device index $DeviceIndex reports capability $($driver.ComputeCapability). Driver/runtime compatibility is verified by the compiled kernel workload."
    } elseif ($architecture -eq 'X64' -and
        ($driver.DriverVersion -lt [version]'580.0' -or $driver.ComputeCapability -lt [version]'7.5')) {
        "The current stable CUDA 13 x64 flow requires driver 580+ and compute capability 7.5+; device index $DeviceIndex reports driver $($driver.DriverVersion), capability $($driver.ComputeCapability). Use -ToolkitOnly for compiler-only setup."
    } else {
        $null
    }
    if ($hardwareError) {
        if ($PlanOnly) {
            [void]$report.result.blockers.Add($hardwareError)
        } else {
            throw $hardwareError
        }
    }
}

Write-AiPhase -Name 'Plan' -Detail "$architecture / NVIDIA CUDA $($plan.ToolkitVersion)"
Add-AiReportAcquisition -Report $report -Entry ([ordered]@{
    component = $component.Component
    vendor = $component.Vendor
    architecture = $architecture
    maturity = $component.Maturity
    sourceType = $component.SourceType
    packageId = Get-AiCatalogValue -Entry $component -Name 'PackageId'
    version = Get-AiCatalogValue -Entry $component -Name 'Version'
    uri = Get-AiCatalogValue -Entry $component -Name 'Uri'
    sha256 = Get-AiCatalogValue -Entry $component -Name 'Sha256'
    versionPolicy = $component.VersionPolicy
    integrity = $component.Integrity
    cachePath = $component.CachePath
    installPath = $component.InstallPath
    reasonNormalChannelInsufficient = $component.NormalChannelLimitation
    expectedStableSource = $component.ExpectedStableSource
    migrationTrigger = $component.MigrationTrigger
    cleanupUpgrade = $component.CleanupUpgrade
    promotionCandidate = Get-AiCatalogValue -Entry $component -Name 'PromotionCandidate'
    action = if ($PlanOnly) { 'planned' } else { 'pending' }
})

$toolchain = Ensure-AiVisualCppTools -Architecture $architecture -PlanOnly:$PlanOnly
Add-AiReportPhase -Report $report -Name 'host-compiler' -Status $(if ($PlanOnly) { 'planned' } else { 'ready' }) -Evidence $toolchain

$cudaAcquisition = Ensure-AiCudaToolkit -Architecture $architecture -PlanOnly:$PlanOnly
$report.acquisitions[0].action = $cudaAcquisition.Action
if (-not $PlanOnly -and $architecture -eq 'X64') {
    $report.acquisitions[0].packageEvidence = $cudaAcquisition.PackageEvidence
}
if ($PlanOnly) {
    Add-AiReportPhase -Report $report -Name 'cuda-kernel' -Status 'planned' -Evidence @{
        source = (Join-Path $PSScriptRoot 'smoke.cu')
        target = "NVIDIA device index $DeviceIndex"
        driver = $driver
    }
    Complete-AiWorkloadReport -Report $report -Ready $false -Path $ReportPath
    Write-Host $(if ($report.result.blockers.Count) { 'PLAN_UNSUPPORTED: cuda' } else { 'PLAN_OK: cuda' })
    return
}

$nvcc = Get-CudaNvccPath -ToolkitVersion $plan.ToolkitVersion
Invoke-CheckedCommand -FilePath $nvcc -ArgumentList @('--version') -DisplayName 'CUDA compiler verification'
$nvccVersionEvidence = (& $nvcc --version 2>&1 | Out-String).Trim()
if ($nvccVersionEvidence -match 'release\s+([0-9]+\.[0-9]+)') {
    $report.acquisitions[0].version = $Matches[1]
}
$readiness = Get-CudaReadiness `
    -ToolkitAvailable $true `
    -NvidiaGpuPresent ([bool]$gpu) `
    -DriverAvailable ([bool]$driver)

Write-Host 'CUDA_TOOLKIT_READY: nvcc is installed and runnable.'
if ($readiness.GpuReady) {
    Write-Host "CUDA_GPU_READY: $($driver.Name), driver $($driver.DriverVersion), compute capability $($driver.ComputeCapability)."
} elseif ($ToolkitOnly) {
    Write-Warning "CUDA toolkit is ready, but GPU execution is not: $($readiness.Status). Install/update the NVIDIA driver and confirm 'nvidia-smi' succeeds."
} else {
    throw "CUDA Toolkit is installed, but no usable NVIDIA driver/GPU was reported by nvidia-smi. Update the NVIDIA driver, reboot if requested, and rerun this flow."
}

$kernelReady = $false
if ($SkipWorkloadSmoke -or -not $readiness.GpuReady) {
    Write-Warning 'CUDA_WORKLOAD_SMOKE_SKIPPED: the toolkit is installed, but a compiled GPU kernel was not executed.'
} else {
    $vsDevCmd = Get-VsDevCmdPath -Architecture $architecture
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-cuda-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        $executable = Join-Path $temporary 'cuda-smoke.exe'
        $compileCommand = Get-CudaKernelCompileCommand `
            -Architecture $architecture `
            -VsDevCmd $vsDevCmd `
            -Nvcc $nvcc `
            -Source (Join-Path $PSScriptRoot 'smoke.cu') `
            -Output $executable
        & $env:ComSpec /d /s /c $compileCommand
        if ($LASTEXITCODE -ne 0) {
            throw "CUDA smoke kernel compilation failed with exit code $LASTEXITCODE."
        }
        $output = (& $executable $DeviceIndex 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "CUDA smoke kernel failed on the GPU (exit $LASTEXITCODE, output '$output')."
        }
        $kernelDevice = Get-CudaKernelDeviceEvidence -Output $output -ExpectedDeviceName $driver.Name -DeviceIndex $DeviceIndex
        Write-Host 'CUDA_WORKLOAD_READY: compiled and executed a CUDA kernel on the detected GPU.'
        $kernelReady = $true
        $report.acceptance.kernel = [ordered]@{
            compiled = $true
            executed = $true
            marker = 'CUDA_KERNEL_READY'
            deviceIndex = $kernelDevice.DeviceIndex
            device = $kernelDevice.Name
            computeCapability = $driver.ComputeCapability.ToString()
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

Add-AiReportPhase -Report $report -Name 'cuda-toolkit' -Status 'ready' -Evidence @{
    nvcc = $nvcc
    nvccVersion = $nvccVersionEvidence
    driver = $driver
}
if ($plan.Preview) {
    Write-Warning 'CUDA 13.4 for Windows ARM64 is an NVIDIA Developer Preview and is not intended for production certification or benchmarking.'
}
Complete-AiWorkloadReport -Report $report -Ready $kernelReady -Path $ReportPath
Write-Host 'INSTALL_OK: cuda'

# SIG # Begin signature block
# MIInUwYJKoZIhvcNAQcCoIInRDCCJ0ACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAfXTKss4Nc3Onv
# GGSm8nq0FJRos/OAbL1TPvJeCkY5y6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIPBojjjQ0YIM2dww7Tg2XlMuKojW
# +x79Hh0Zl613Vn4VMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAxFJYUS0fhbi7ORdDF0TADM/YdeVPUiGkGf5+V/T4bPRzEwyO5TYGtl/iFnOY
# +GjMu4OxLKSCk/bjeceVo5H19mWeFC0Rn33NFWtIA+lBGyZG9zJ6DVkkQJJ0OM1h
# 8ZYWPpRpWek9r5NNVLyk1GTDAfDqr9sXgUqGOkbwDj4qs8gvVAqmelKeysU8uJD4
# g6r1fiOBHQSacmvQlakizYQCAl0wacW/Y7WI80E2l7EfkDpm1PKxpBcK8/reKMst
# vkk/9FUl9dvP+JIfQ8N1AwuHhhhE/GsAjzf3Ww/e8w/8oV+0TED9X+E8p1fwO+AW
# lDF91OeK4P5JNOCs/gpjPE4Bp6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gG
# CSqGSIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCDoOkae6iL3Yya9YOaMxBISDiItJN07xHI9HXvfn4H44QIGaq5h2CQiGBMy
# MDI2MTAwOTAwMTc0MS40NjRaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# QzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEf4wggcoMIIFEKADAgECAhMzAAACGCXZkgXi5+XkAAEAAAIYMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgyNVoXDTI2MTExMzE4NDgyNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjRDMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsdzo6uuQJqAfxLnvEBfIvj6k
# nK+p6bnMXEFZ/QjPOFywlcjDfzI8Dg1nzDlxm7/pqbvjWhyvazKmFyO6qbPwClfR
# nI57h5OCixgpOOCGJJQIZSTiMgui3B8DPiFtJPcfzRt3FsnxjLXwBIjGgnjGfmQl
# 7zejA1WoYL/qBmQhw/FDFTWebxfo4m0RCCOxf2qwj31aOjc2aYUePtLMXHsXKPFH
# 0tp5SKIF/9tJxRSg0NYEvQqVilje8aQkPd3qzAux2Mc5HMSK4NMTtVVCYAWDUZ4p
# +6iDI9t5BNCBIsf5ooFNUWtxCqnpFYiLYkHfFfxhVUBZ8LGGxYsA36snD65s2Hf4
# t86k0e8WelH/usfhYqOM3z2yaI8rg08631IkwqUzyQoEPqMsHgBem1xpmOGSIUnV
# vTsAv+lmECL2RqrcOZlZax8K0aiij8h6UkWBN2IA/ikackTSGVRBQmWWZuLFWV/T
# 4xuNzscC0X7xo4fetgpsqaEA0jY/QevkTvLv4OlNN9eOL8LNh7Vm0R65P7oabOQD
# qtUFAwCgjgPJ0iV/jQCaMAcO3SYpG5wSAYiJkk4XLjNSlNxU2Idjs1sORhl7s7LC
# 6hOb7bVAHVwON74GxfFNiEIA6BfudANjpQJ0nUc/ppEXpT4pgDBHsYtV8OyKSjKs
# IxOdFR7fIJIjDc8DvUkCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBQkLqHEXDobY7dH
# uoQCBa4sX7aL0TAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAnkjRhjwPgdoIpvt4
# YioT/j0LWuBxF3ARBKXDENggraKvC0oRPwbjAmsXnPEmtuo5MD8uJ9Xw9eYrxqqk
# K4DF9snZMrHMfooxCa++1irLz8YoozC4tci+a4N37Sbke1pt1xs9qZtvkPgZGWn5
# BcwVfmAwSZLHi2CuZ06Y0/X+t6fNBnrbMVovNaDX4WPdyI9GEzxfIggDsck2Ipo4
# VXL/Arcz7p2F7bEZGRuyxjgMC+woCkDJaH/yk/wcZpAsixe4POdN0DW6Zb35O3Dg
# 3+a6prANMc3WIdvfKDl75P0aqcQbQAR7b0f4gH4NMkUct0Wm4GN5KhsE1YK7V/wA
# qDKmK4jx3zLz3a8Hsxa9HB3GyitlmC5sDhOl4QTGN5kRi6oCoV4hK+kIFgnkWjHh
# SRNomz36QnbCSG/BHLEm2GRU9u3/I4zUd9E1AC97IJEGfwb+0NWb3QEcrkypdGdW
# wl0LEObhrQR9B1V7+edcyNmsX0p2BX0rFpd1PkXJSbxf8IcEiw/bkNgagZE+VlDt
# xXeruLdo5k3lGOv7rPYuOEaoZYxDvZtpHP9P36wmW4INjR6NInn2UM+krP/xeLnR
# bDBkm9RslnoDhVraliKDH62BxhcgL9tiRgOHlcI0wqvVWLdv8yW8rxkawOlhCRqT
# 3EKECW8ktUAPwNbBULkT+oWcvBcwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
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
# HVUzWLOhcGbyoYIDWTCCAkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# QzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAnWtGrXWiuNE8QrKfm4CtGr57z+mggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO5yk3kwIhgPMjAyNjEwMDgyMjExMDVaGA8yMDI2MTAwOTIyMTEwNVowdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA7nKTeQIBADAKAgEAAgIWKQIB/zAHAgEAAgITdjAK
# AgUA7nPk+QIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQAw+MY1lqn118vQ
# THeTQTPaU+M8j01IMctlPwI6wCH0Exx74L8IMY1NFht1NdoaxHtAHP4WukNRgbHz
# Sjk4yH4undGoOgVJFKvl5eoMHM/w5HhyDcaZ6Ae6gUp58DWz4PIZwcTEuboGv0l7
# y+gJcqAj/B8kDfUDWwrsylaOzoKyv/r0fwyX0ud2YfI+25Om4ETuogOIRWylBqZy
# ltJqUrI8UTYbLbizDNvfeVt9/vj6WBX9bknvAdGkTMs6234b5SoFYnCVJMAJ+PMf
# KbipOCNvf2d8vzS6YR4nc+U8sbymICGmQyWv6y/h7VH/qn/Rwc9YfP4Ra7Mq6u/7
# aU/rlFrOMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIYJdmSBeLn5eQAAQAAAhgwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqG
# SIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgw43SwWsIoCUD
# zV7BKHxSPKawMtNruA+UG23iBFm8da0wgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHk
# MIG9BCCZE9yJuOTItIwWaES6lzGKK1XcSoz1ynRzaOVzx9eFajCBmDCBgKR+MHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACGCXZkgXi5+XkAAEAAAIY
# MCIEIMamcWmKzIQSVo0ajIdEabBU6jUnpC0LAeNk5yUfKeWqMA0GCSqGSIb3DQEB
# CwUABIICACiY87LynYojlbqwz3MU84tdDMI4qGDMCYirh2ObD6tyCb8q2DfHwjW/
# eX82/Ee+gigVoK7y67WpoCV2E7bTz9FPjBXoFEOcnkOrD4K0zRV/zTk5gqQsJ/YZ
# 0NpFDYiN8sWLIj2avb9/gh4YheI/4XqD0V6GCWTW/WN5/QzRb6+qmbqC7R8xAlkA
# lxkJomIdWLj1r19GumDPWUUcOrKps3xOxAPQTL2QvV6+i/0s2uvXCp+dnsE6mNM4
# jAj1hTtXC2GNaEykO8pVTkUKZ7I9UPTJkswfiHUA15n7KLCOwosEsQVUee7XHeM5
# QZst7V7QPyMvjI+zlMxxC1q4Fo1TpYvRAsSMaY8Lmw5xqNQLYBHd8ybYPlEPQlIn
# 3/55EH2wB8Q5L12Lca00DG5+UQ9KFSdK1ZVV5LeK919XluFK4NpLOTqKs8upd9SG
# TnZTiUrCF9W0aHsOlm8H+Iv1rSlxrUktK+BuFmwJ6Kys+NSR7abaRT+3RNedXbmV
# ySmm1Qy4QCf0fIyTObiMrca68Hpex4aJ1ch8deRVl/LtqVNc+iD0oCjWd2evl7Uq
# 5owkV/7zYiXs4y0AvE7vcpEKtW5mTFeyOBXHdO7mMTeKAaIo4FMCYcIyo4Wadpep
# fTXnCVpsBUYuOrH09ocO9bbXPKmdlE5Eonv+uVYl1Y8h+HkHMuix
# SIG # End signature block
