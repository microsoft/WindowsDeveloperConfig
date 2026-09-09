$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$reportPath = Join-Path $env:LOCALAPPDATA 'DevConfig\reports\intel-ai-latest.json'
if (-not (Test-Path -LiteralPath $reportPath)) { throw "Intel AI report not found at '$reportPath'." }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$profile = $report.request.Profile
$device = $report.request.SelectedDevice

if ($profile -in @('OpenVINO', 'Full')) {
    $python = Join-Path $env:LOCALAPPDATA 'DevConfig\intel-ai\openvino\.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) { throw "OpenVINO environment not found at '$python'." }
    $output = (& $python (Join-Path $PSScriptRoot '..\..\Workloads\intel-ai\openvino-smoke.py') $device 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $output -notmatch '^OPENVINO_SMOKE=') {
        throw "OpenVINO probe failed: $output"
    }
}
if ($profile -in @('SYCL', 'Full') -and -not $report.acceptance.sycl) {
    throw 'The Intel AI report does not contain successful SYCL acceptance evidence.'
}
Write-Output 'Intel AI ready'
