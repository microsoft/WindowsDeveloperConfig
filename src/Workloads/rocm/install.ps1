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
