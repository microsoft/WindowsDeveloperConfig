$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1')
. (Join-Path $PSScriptRoot '..\..\Workloads\_common\ai-report.ps1')

$catalog = Get-AiCatalog
$required = @(
    'Component', 'Architectures', 'Maturity', 'SourceType', 'VersionPolicy',
    'Integrity', 'CachePath', 'InstallPath', 'NormalChannelLimitation',
    'ExpectedStableSource', 'MigrationTrigger', 'CleanupUpgrade'
)
foreach ($entry in $catalog.Components.GetEnumerator()) {
    foreach ($field in $required) {
        Assert-True ($entry.Value.ContainsKey($field)) "$($entry.Key) should define promotion field $field"
    }
}

$wingetArgs = Get-DevConfigWingetInstallArguments -Id 'Microsoft.FoundryLocal'
Assert-Equal ($wingetArgs -join ' ') 'install --id Microsoft.FoundryLocal --exact --source winget --silent --accept-package-agreements --accept-source-agreements' 'Shared WinGet command should be exact and noninteractive'
$directSetup = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1') -Raw
Assert-True ($directSetup.Contains('''--installPath'', "`"$installPath`""')) 'Build Tools install path should remain one quoted Start-Process argument'
Assert-True ($directSetup -match 'Get-AiWingetPackageEvidence') 'Package evidence should respect the selected WinGet frontend'

$report = New-AiWorkloadReport -Id 'unit' -Request @{ PlanOnly = $true }
Add-AiReportAcquisition -Report $report -Entry @{ component = 'test'; sourceType = 'unit'; action = 'planned' }
Set-AiAcquisitionAction -Report $report -Index 0 -Action 'already-current'
Add-AiReportPhase -Report $report -Name 'plan' -Status 'planned' -Evidence @{ backend = 'CPU' }
Assert-Equal $report.schemaVersion 1 'Report schema version should be stable'
Assert-Equal $report.acquisitions.Count 1 'Report should collect acquisitions'
Assert-Equal $report.acquisitions[0].action 'already-current' 'Report should finalize acquisition actions'
Assert-Equal $report.phases.Count 1 'Report should collect phases'
Assert-True $report.result.planOnly 'Report should preserve plan mode'

$schemaPath = Join-Path $PSScriptRoot '..\..\docs\ai-workload-report.schema.json'
Assert-True (Test-Path -LiteralPath $schemaPath) 'Checked-in report schema should exist'

$failurePath = Join-Path $env:TEMP "devconfig-report-failure-$([guid]::NewGuid().ToString('N')).json"
try {
    $failureReport = New-AiWorkloadReport -Id 'failure-unit' -Request @{}
    try { throw 'synthetic hardware failure' } catch {
        Write-AiFailureReport -Report $failureReport -Path $failurePath -ErrorRecord $_
    }
    $savedFailure = Get-Content -LiteralPath $failurePath -Raw | ConvertFrom-Json
    Assert-True (-not $savedFailure.result.ready) 'Failure report should not claim readiness'
    Assert-True ($savedFailure.result.blockers[0] -like '*synthetic hardware failure*') 'Failure report should retain the actionable exception'
} finally {
    Remove-Item -LiteralPath $failurePath -Force -ErrorAction SilentlyContinue
}

Write-Host "UNIT_OK: ai-common ($script:AssertionCount assertions)"
