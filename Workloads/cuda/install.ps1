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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAfXTKss4Nc3Onv
# GGSm8nq0FJRos/OAbL1TPvJeCkY5y6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# KoZIhvcNAQkEMSIEIPBojjjQ0YIM2dww7Tg2XlMuKojW+x79Hh0Zl613Vn4VMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAGj6PPdTIqtKXNbdI
# AxNnp26WFVd4B840mfMy/IxVyb8p32ASwaJtIksFDBMRHFcJWNIbmVdYu12pvoKJ
# zD+uU6eTIDQDbDEqlJHfGiaL87OekOpCoKCfmASc2pZEGZMD5qhiS5Lazs6Pj4hv
# 2s89/98gcuPSnnL0fBs2jBixhM/6j46P+fFse2umGKNRSHFp5HJmtT7ry82KlfiF
# difTBKlWERFgPTJ+aOViJU8h4hVilxThTYPnC6uxb0KNYD5+VcydtwYXwYnkNA3k
# 0pBdjUf471LmdcCG56EaL0syvovVixpji7bH5A4XisXPQscw5AFG05lSdTQTS/pe
# xnBDoKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDyYrJgvel6TJQJ
# N6w4uTUHy6iPXtAPJw8rS9J/q/hSoQIGarUlnK4XGBMyMDI2MTAwODAzMDIwMS4z
# MjZaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTkzNS0wM0UwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAifVwIPDsS5XLQABAAACJzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDRaFw0yNzA1MTcxOTQwMDRa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTkzNS0wM0UwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDi
# xWy1fDOSL4qj3A1pady+elIDLwnF3UuLzJIOWwGHcEgrxxwtnyviUIDmmxylTUl1
# u+2rBPp2zT4BwwQhvGaJpExqvPLlDFlbfmSflKI86eFqofiZ7j8NTRO4l7wGg9Nj
# m+muNauTcFW2qdfIjKE950Okrm9MnMOGYy+fibNYdxTPRPq1T4MLZK3s3vdMyMEO
# ldcOQkSKpxD6/1Gk6gOmCu2KgI8f0ex6vYxnKDl9W0OLSEa/6y82oIbsm+1QBifO
# Q47xWKTG1CmvtGr85LzA75/MAcUmRw5/of/qET0UFV1WulMcJrI6DASAsNCNB+6W
# LrotuBZAj+VMlqbn5RMZ6Q4IY7JwaAiIXh7VjxrnwUOYZG8WEGhfrA98di+7LEn9
# AqvvEOyG+UQcjVhCCbMGXigJXSApeyeWupCsD0jgQMNCxfB5BLBDWxgdY3dJBEPg
# xfkgTDQLBggtVv2d5CYxHKgIItB4bI5eSb5jkIG2WotnFetT0legpw/Eozwf39ao
# 6tENY21eVWIzRw/GsmvwjYQF6vVrxOD0pGVsfqGF8s3VPeY7hI2TxHFMqNA0IB/a
# 2NLY7JTxYAKAP/11EJZt7xbqDLMgD1YDdGEzGpQijm3nAPCL2CebP/jmu90abJ2W
# 425yglGHTI/nCBrwSpfRCgwzrfFelJaCKM6+35aFfwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFNLW58N4MGSG6ud7jWqgT92orfReMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQAqncud4PSC1teb2H6nRuy7sDiKK13FXJirVB4Tfwjdo2Mb+QL4j7wZ/k4G
# 9P0CANHZFrDQcK0VFDTysrYu8Z0Aha14acDZPsyIoPvAGRRhaHEuf7NckRjkfa/y
# lo1KyII8jbL9N9sJAqBPL8V4FNBjljv+1GHDOw127rZz5ZSTPoAPb2SA0v5yDgcp
# UMfxglPyp6cnPPoQpTtD9OGx8Dwm2P+o1TPxBIy6I0T9RauulogVCvKwflfeLTcK
# AvnSG1rCjerSXmU1DNXOsAD/bsrSjgbX5mAbD7XTRMF/vawAWESFcn/BjjizxeWZ
# b00aYSlkJA2rVtFlMM481aVWXdAbXPP5RzUiWTlgyHf/G7lCxHYWGIZuB13T3aI6
# Y8mEgn/ou40aiFJo8r0+i0P5GdNneWtxiR0CMKUfko+5s/73cwe1Wfp8BKXa270c
# icVQasFf5sRV7pFm+V7fNRXwCu7anTOmga76zO7/2t+zOlibvphT+Q6Zd+B2qYsS
# n4xBaY+YzHpnycLW5cvJyhPxBCcb1oRYfhRzCADb2utI2EtGCjc2P2ii4LyR4QMb
# /n8cOweL9IqVTKKzzVk+zZJxV3vrp4LyuQXw0O30la6BcHdNAAAB9UC83zs3G9d+
# AlIfZLM97tMUNKWjbBpIirFx6LTDFXVtZQd7hqzLYByjbjH0ujCCB3EwggVZoAMC
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
# U1MgRVNOOkE5MzUtMDNFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAjHzqthPwO0GDckDMA6x54lIiM
# KqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nFuGzAiGA8yMDI2MTAwODAxMTkyM1oYDzIwMjYxMDA5MDExOTIz
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucW4bAgEAMAcCAQACAgXUMAcCAQAC
# AhKeMAoCBQDucr+bAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAFar76Mk
# OC1QaaFnrh0qKrQAM9cGYEY4FXKeJsyW2rllg3ksshQfno1hgjwopGEMzL+v4r02
# 8I1fJ7enpb15tEMudXViVqkJI5OT+SUkPzo5Hx8Nyl6ctKMrehUmrQErVsW/XG+h
# eMOscn9YuirdFEk35gqltgXAcHPa+HlgL+EcSpPxZLCO0ljD2uRY694KCdgVv3zS
# S3y+K8XErRpTZ9uNiTKuMdfJxxSAZlwHfVWUwE0p5PO4FIt3bPCKJM7eEnSolLEZ
# CpWwXEGSxmdzhIMMKItHbY9y/3+SCFLurhO8o0RA9tBvUDd0DsKwjgYwYanNqOTM
# NwHNCEBcIpvw/YwxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAifVwIPDsS5XLQABAAACJzANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBt7bU+
# dWys/+0qBmfFGI3LHa2UXmvuNTXk9ZjdCdqS1DCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIOXnARo1oVIcOLJKDqlE0adq/jZ9TXdlnXWRcXGThBFyMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIn1cCDw7EuVy0A
# AQAAAicwIgQggb0jjwGATQ4fPot3sG0B/UZ+M/Ct6k25Cw3JIq2r43YwDQYJKoZI
# hvcNAQELBQAEggIAW0gMuW5YFqd6OM08fB0ijn+SDrz3gaJrGPNIjf71nY81F91t
# xGO/GDjcqSkQfoRjaS4inhn8BweY+4YGRce+sMV/KR2L6BPPE9Y8X0aQYTO4U4Dd
# ZpUsycXQ3gBTpCpMBeQWphvbLwx/VpnzW8bR9d6JhuZAMGFUFXPHcLvMwkOdkXVc
# 0gHJAOhP1jkQxdhLFvE5dxE+SImQtWHiyzgqzpewNLg9S5mpNZiadkTAn0SdJ6cG
# Q7W4IHgd3PSXHlriNFcZFMEU0FBUSi8y+YraoDheyx07QcmeUkveZFBR/NKakpmf
# z61ed2eLh0gkAje25x/8ur2MaJtmnY1kS9sqdeDxYYAdmEbrI2bqJI7pX4Rg7X/v
# lHDZuGwZh+mtNov5x8SIawdtvcm+I4ue9FgyZhBES449YxJ+B+M+CteUKMDPHOOb
# lsOi1JSFIuB+4FQ/ToSvVvTNuaJDecr+lAJxDIa8C/2ywztJ24U5Dr+wsNFq44al
# HOVnEU304O8jnINzQ8LnHTJo92Wwt7tMeJ3k+/WAply/zIGanuWvklfvCMncQ/+t
# eoN1iXslavZlHNFHHTdEE5g0ed+7OGcM8+jmBjYAAU70M0Yw1Ipdy5MXda1qdTr0
# WaJL0l6hzkQvytPbR3JZ0FNxVugE7alwjOz+2Nqd5v0MnLwsTwYswv+qdog=
# SIG # End signature block
