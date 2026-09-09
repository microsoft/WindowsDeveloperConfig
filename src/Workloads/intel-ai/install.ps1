<#
.SYNOPSIS
  Install and verify Intel OpenVINO acceleration, with optional oneAPI/SYCL tooling.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CPU', 'GPU', 'NPU')] [string] $Device = 'Auto',
    [ValidateSet('OpenVINO', 'SYCL', 'Full')] [string] $Profile = 'OpenVINO',
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
$catalog = (Get-AiCatalog).Components
$component = $catalog.IntelOpenVino
$report = New-AiWorkloadReport -Id 'intel-ai' -Request @{
    Device = $Device
    SelectedDevice = $selectedDevice
    Profile = $Profile
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
    Add-AiReportPhase -Report $report -Name 'openvino-inference' -Status $(if ($Profile -eq 'SYCL') { 'skipped' } else { 'planned' }) -Evidence @{ device = $selectedDevice }
    Add-AiReportPhase -Report $report -Name 'sycl-kernel' -Status $(if ($Profile -eq 'OpenVINO') { 'skipped' } else { 'planned' }) -Evidence @{ device = 'GPU' }
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
    $openvinoEvidence = (& $venvPython (Join-Path $PSScriptRoot 'openvino-smoke.py') $selectedDevice 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $openvinoEvidence -notmatch '^OPENVINO_SMOKE=') {
        throw "OpenVINO $selectedDevice inference failed: $openvinoEvidence"
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
        $command = "call `"$setvars`" >nul && icpx -fsycl `"$PSScriptRoot\sycl-smoke.cpp`" -o `"$output`" && `"$output`""
        $syclEvidence = (& $env:ComSpec /d /s /c $command 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $syclEvidence -notmatch 'SYCL_DEVICE_READY:') {
            throw "oneAPI SYCL GPU kernel failed: $syclEvidence"
        }
        $report.acceptance.sycl = $syclEvidence
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Complete-AiWorkloadReport -Report $report -Ready $true -Path $ReportPath
Write-Host "INTEL_AI_READY: profile=$Profile device=$selectedDevice"
Write-Host 'INSTALL_OK: intel-ai'
