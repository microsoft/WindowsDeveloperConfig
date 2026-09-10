$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$hipcc = Join-Path $env:LOCALAPPDATA 'DevConfig\rocm\.venv\Scripts\hipcc.exe'
if (-not (Test-Path -LiteralPath $hipcc)) { throw "hipcc not found at '$hipcc'." }
$reportPath = Join-Path $env:LOCALAPPDATA 'DevConfig\reports\rocm-latest.json'
$deviceIndex = 0
if (Test-Path -LiteralPath $reportPath) {
    $request = (Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json).request
    if ($request.PSObject.Properties['DeviceIndex']) { $deviceIndex = [int]$request.DeviceIndex }
}
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "devconfig-hip-probe-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
try {
    $executable = Join-Path $temporary 'hip-smoke.exe'
    & $hipcc (Join-Path $PSScriptRoot '..\..\Workloads\rocm\hip-smoke.cpp') -O2 -o $executable
    if ($LASTEXITCODE -ne 0) { throw "HIP compile failed with exit code $LASTEXITCODE." }
    $output = (& $executable $deviceIndex 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $output -notmatch '^HIP_KERNEL_READY') {
        throw "HIP kernel failed: $output"
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'ROCm ready'
