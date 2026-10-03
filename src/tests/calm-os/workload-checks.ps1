[CmdletBinding()]
param(
    [string] $WorkloadPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $WorkloadPath) {
    $WorkloadPath = Join-Path $PSScriptRoot '..\..\windows-dev-config\workloads\devconfig.ps1'
}
$checks = 0

function Assert-PhaseOrder {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$full = & $WorkloadPath -Action Full
$partial = & $WorkloadPath -Action Partial
$uninstall = & $WorkloadPath -Action Uninstall
$cleanupFiles = @($uninstall.Phases | ForEach-Object { $_.File })
$eligible = @($full.Phases | Where-Object { $_['Uninstall'] })

Assert-PhaseOrder ($cleanupFiles[-1] -eq 'terminal.ps1') 'Terminal cleanup must run last.'
Assert-PhaseOrder ($cleanupFiles[-2] -eq 'packages.ps1') 'Package removal must finish before Terminal cleanup.'
Assert-PhaseOrder ((($cleanupFiles | Sort-Object) -join ',') -eq (($eligible.File | Sort-Object) -join ',')) 'Cleanup must retain every eligible phase exactly once.'

foreach ($file in @('copilot.ps1', 'powershell-profile.ps1', 'wsl.ps1')) {
    Assert-PhaseOrder (($cleanupFiles.IndexOf($file) -ge 0) -and
        ($cleanupFiles.IndexOf($file) -lt $cleanupFiles.IndexOf('packages.ps1'))) "$file must run before package removal."
}

foreach ($phase in $uninstall.Phases) {
    $original = $eligible | Where-Object { $_.File -eq $phase.File }
    Assert-PhaseOrder ((ConvertTo-Json $phase -Depth 10 -Compress) -ceq
        (ConvertTo-Json $original -Depth 10 -Compress)) "Cleanup must preserve the $($phase.File) phase definition."
}

$remaining = @($eligible | Where-Object { $_.File -notin @('packages.ps1', 'terminal.ps1') } | ForEach-Object { $_.File })
Assert-PhaseOrder (($cleanupFiles[0..($cleanupFiles.Count - 3)] -join ',') -ceq ($remaining -join ',')) 'Other cleanup phases must retain their relative order.'
Assert-PhaseOrder ($full.Phases[-1].File -eq 'wsl.ps1') 'Full setup must keep WSL last for reboot handling.'
Assert-PhaseOrder ($partial.Phases[-1].File -eq 'wsl.ps1') 'Partial setup must keep WSL last for reboot handling.'
Assert-PhaseOrder ((@($full.Phases.File).IndexOf('terminal.ps1')) -lt
    (@($full.Phases.File).IndexOf('copilot.ps1'))) 'Full setup must configure Terminal before Copilot.'
$partialFiles = @($full.Phases | Where-Object { $_.File -ne 'edge.ps1' } | ForEach-Object { $_.File })
Assert-PhaseOrder (($partial.Phases.File -join ',') -ceq ($partialFiles -join ',')) 'Partial setup must retain the Full phase order without Edge.'

Write-Output "$checks workload phase checks passed."
