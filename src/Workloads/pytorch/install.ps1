<#
.SYNOPSIS
  Install PyTorch into a contained virtual environment and run a tensor smoke test.

.PARAMETER Backend
  Auto selects a verified NVIDIA CUDA wheel on x64 when the installed driver is
  compatible, otherwise CPU. CPU and CUDA force an explicit choice.

.PARAMETER SkipTriton
  Do not install Triton Windows even when the detected PyTorch CUDA stack is compatible.

.PARAMETER RequireTriton
  Fail unless this host has a supported Triton Windows combination.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CPU', 'CUDA')] [string] $Backend = 'Auto',
    [switch] $SkipTriton,
    [switch] $RequireTriton
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($SkipTriton -and $RequireTriton) {
    throw '-SkipTriton and -RequireTriton cannot be used together.'
}

. (Join-Path $PSScriptRoot '..\_common\ai-support.ps1')

& (Join-Path $PSScriptRoot '..\_common\apply-configuration.ps1') `
    -Id 'pytorch' `
    -ConfigFile (Join-Path $PSScriptRoot 'configuration.winget') `
    -RequireCommands @('python') `
    -DeferSentinel

$pythonCommand = Assert-CommandAvailable -CommandName 'python' -Remediation 'Reopen the terminal and rerun the PyTorch flow.'
$pythonPath = $pythonCommand.Source
$pythonVersionText = (& $pythonPath -c 'import platform; print(platform.python_version())').Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Python failed while reporting its version.'
}
$pythonVersion = [version]$pythonVersionText
$architecture = Get-DevConfigArchitecture
$pythonMachine = (& $pythonPath -c 'import platform; print(platform.machine())').Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Python failed while reporting its architecture.'
}
Assert-PythonArchitecture -Architecture $architecture -PythonMachine $pythonMachine

$driver = Get-NvidiaDriverInfo
$hasNvidia = [bool]$driver
$plan = Resolve-PyTorchPlan `
    -Architecture $architecture `
    -Backend $Backend `
    -PythonVersion $pythonVersion `
    -HasNvidia $hasNvidia `
    -DriverMajor $(if ($driver) { $driver.DriverMajor } else { 0 }) `
    -ComputeCapability $(if ($driver) { $driver.ComputeCapability } else { [version]'0.0' }) `
    -SkipTriton:$SkipTriton

if ($RequireTriton -and -not $plan.InstallTriton) {
    throw "Triton Windows is required but unsupported: $($plan.TritonReason)"
}

$root = Join-Path $env:LOCALAPPDATA 'DevConfig\pytorch'
$venv = Join-Path $root '.venv'
$statePath = Join-Path $root 'install-state.json'
$desiredState = [ordered]@{
    architecture = $plan.Architecture
    backend = $plan.Backend
    torch = $plan.TorchRequirement
    index = $plan.IndexUrl
    triton = $plan.TritonRequirement
    python = "$($pythonVersion.Major).$($pythonVersion.Minor)"
}
$desiredJson = $desiredState | ConvertTo-Json -Compress

if ((Test-Path -LiteralPath $statePath) -and (Test-Path -LiteralPath $venv)) {
    $currentJson = (Get-Content -LiteralPath $statePath -Raw).Trim()
    if ($currentJson -ne $desiredJson) {
        Write-Host 'The requested PyTorch plan changed; recreating the contained environment.'
        Remove-Item -LiteralPath $venv -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $root -Force | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python.exe'))) {
    Invoke-CheckedCommand -FilePath $pythonPath -ArgumentList @('-m', 'venv', $venv) -DisplayName 'PyTorch virtual environment creation'
}

$venvPython = Join-Path $venv 'Scripts\python.exe'
Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '--upgrade', 'pip') -DisplayName 'pip upgrade'

$torchDryRun = Get-PipInstallArguments -Requirement $plan.TorchRequirement -IndexUrl $plan.IndexUrl -DryRun
Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $torchDryRun -DisplayName 'PyTorch compatible-wheel check'
$torchInstall = Get-PipInstallArguments -Requirement $plan.TorchRequirement -IndexUrl $plan.IndexUrl
Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $torchInstall -DisplayName 'PyTorch installation'
Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @('-m', 'pip', 'check') -DisplayName 'PyTorch dependency check'
Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @((Join-Path $PSScriptRoot 'smoke.py'), '--backend', $plan.Backend) -DisplayName 'PyTorch tensor smoke test'

if ($plan.InstallTriton) {
    $tritonDryRun = Get-PipInstallArguments -Requirement $plan.TritonRequirement -DryRun
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $tritonDryRun -DisplayName 'Triton Windows compatible-wheel check'
    $tritonInstall = Get-PipInstallArguments -Requirement $plan.TritonRequirement
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList $tritonInstall -DisplayName 'Triton Windows installation'
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @((Join-Path $PSScriptRoot 'triton-smoke.py')) -DisplayName 'Triton Windows GPU kernel smoke test'
    Write-Host "TRITON_READY: $($plan.TritonRequirement)"
} else {
    Write-Host "TRITON_SKIPPED: $($plan.TritonReason)"
}

Set-Content -LiteralPath $statePath -Value $desiredJson -Encoding ascii
Write-Host "PYTORCH_READY: backend=$($plan.Backend), runtime=$($plan.Runtime), environment=$venv"
Write-Host "Activate with: & '$venv\Scripts\Activate.ps1'"
Write-Host 'INSTALL_OK: pytorch'
