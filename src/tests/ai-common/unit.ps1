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

. (Join-Path $PSScriptRoot '..\..\Workloads\_common\content-hashes.ps1')
$workloadsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\Workloads')).Path
Assert-DevConfigWorkloadContent -WorkloadsRoot $workloadsRoot
$trackedContent = @(git -C (Join-Path $PSScriptRoot '..\..\..') ls-files 'src/Workloads/**' |
    Where-Object { [IO.Path]::GetExtension($_) -ne '.ps1' } |
    ForEach-Object { $_.Substring('src/Workloads/'.Length).Replace('/', '\') })
Assert-Equal @($Script:DevConfigWorkloadContentHashes.Keys | Sort-Object).Count $trackedContent.Count 'Signed content manifest should cover every tracked non-PowerShell Workloads file'
foreach ($path in $trackedContent) {
    Assert-True $Script:DevConfigWorkloadContentHashes.ContainsKey($path) "Signed content manifest should declare $path"
}
$blobHashScript = @'
import hashlib
import json
import subprocess

paths = subprocess.check_output(
    ["git", "ls-files", "src/Workloads/**"], text=True
).splitlines()
print(json.dumps({
    path[len("src/Workloads/"):].replace("/", "\\"):
        hashlib.sha256(subprocess.check_output(["git", "show", f"HEAD:{path}"])).hexdigest()
    for path in paths
    if not path.lower().endswith(".ps1")
}, sort_keys=True))
'@
$blobHashScriptPath = Join-Path $env:TEMP "devconfig-blob-hashes-$([guid]::NewGuid().ToString('N')).py"
try {
    [IO.File]::WriteAllText($blobHashScriptPath, $blobHashScript, [Text.UTF8Encoding]::new($false))
    $blobHashResult = Invoke-DevConfigNativeCommand -FilePath 'python' -Arguments @($blobHashScriptPath)
    if ($blobHashResult.ExitCode -ne 0) {
        throw "Could not calculate canonical Git blob hashes: $($blobHashResult.Output)"
    }
    $blobHashes = $blobHashResult.Output.Trim() | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $blobHashScriptPath -Force -ErrorAction SilentlyContinue
}
foreach ($path in $trackedContent) {
    Assert-Equal $Script:DevConfigWorkloadContentHashes[$path] $blobHashes.$path "Signed content hash should match canonical Git blob bytes for $path"
}
$tamperedRoot = Join-Path $env:TEMP "devconfig-content-tamper-$([guid]::NewGuid().ToString('N'))"
try {
    Copy-Item -LiteralPath $workloadsRoot -Destination $tamperedRoot -Recurse
    New-Item -ItemType Directory -Path (Join-Path $tamperedRoot 'pytorch\__pycache__') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tamperedRoot 'pytorch\__pycache__\torch.pyc') -Value 'untrusted bytecode'
    Assert-ThrowsLike {
        Assert-DevConfigWorkloadContent -WorkloadsRoot $tamperedRoot
    } '*not declared by signed content manifest*' 'Signed content verification should reject unexpected Python bytecode'
} finally {
    Remove-Item -LiteralPath $tamperedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$capabilities = @(Get-AiCapabilityMatrix)
Assert-True ($capabilities.Count -ge 30) 'Capability matrix should enumerate every supported and explicitly unavailable Windows AI cell'
Assert-Equal @($capabilities.Id | Sort-Object -Unique).Count $capabilities.Count 'Capability ids should be unique'
$requiredCapabilityIds = @(
    'cuda-nvidia-x64', 'cuda-nvidia-arm64', 'rocm-amd-x64',
    'intel-openvino-cpu-x64', 'intel-openvino-gpu-x64', 'intel-openvino-npu-x64',
    'intel-sycl-gpu-x64', 'intel-full-gpu-x64',
    'pytorch-cpu-x64', 'pytorch-cpu-arm64', 'pytorch-cuda-x64', 'pytorch-cuda-arm64',
    'pytorch-rocm-x64', 'pytorch-xpu-x64',
    'triton-cuda-x64', 'triton-cuda-arm64', 'triton-xpu-x64',
    'llama-cpu-x64', 'llama-cpu-arm64', 'llama-cuda-x64', 'llama-cuda-arm64',
    'llama-rocm-x64', 'llama-sycl-x64', 'llama-openvino-x64', 'llama-vulkan-x64',
    'llama-opencl-adreno-arm64',
    'foundry-source-managed-x64', 'foundry-source-managed-arm64',
    'ollama-source-managed-x64', 'ollama-source-managed-arm64',
    'rocm-arm64-unavailable', 'pytorch-rocm-arm64-unavailable',
    'pytorch-xpu-arm64-unavailable', 'pytorch-qualcomm-arm64-unavailable',
    'triton-amd-windows-unavailable', 'generic-arm-gpu-toolkit-unavailable',
    'amd-ryzen-ai-npu-unavailable', 'intel-ai-arm64-unavailable',
    'other-windows-gpu-unavailable'
)
foreach ($id in $requiredCapabilityIds) {
    Assert-True ($id -in $capabilities.Id) "Capability matrix should include required cell $id"
}
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$implementedStatuses = @('implemented-supported', 'source-managed')
foreach ($cell in $capabilities) {
    Assert-True ($cell.Status -in @('implemented-supported', 'source-managed', 'upstream-unavailable')) "$($cell.Id) should use a defined capability status"
    if ($cell.Status -in $implementedStatuses) {
        foreach ($field in @('Workload', 'Architecture', 'Vendor', 'DeviceFamily', 'Backend', 'Maturity', 'Acquisition', 'Prerequisites', 'Resolver', 'ResolverArguments', 'Expected', 'ProbePath', 'ReportEvidence', 'PartnerCommand')) {
            Assert-True $cell.ContainsKey($field) "$($cell.Id) should define supported-cell field $field"
        }
        Assert-True ([bool](Get-Command -Name $cell.Resolver -CommandType Function -ErrorAction SilentlyContinue)) "$($cell.Id) resolver should exist"
        foreach ($identity in @($cell.Acquisition)) {
            if ($identity -like 'component:*') {
                $componentKey = $identity.Substring('component:'.Length)
                Assert-True $catalog.Components.ContainsKey($componentKey) "$($cell.Id) should reference catalog component $componentKey"
            } else {
                Assert-True ($identity -like 'winget:*') "$($cell.Id) acquisition '$identity' should use a known identity prefix"
            }
        }
        Assert-True (Test-Path -LiteralPath (Join-Path $repositoryRoot $cell.ProbePath)) "$($cell.Id) verification probe should exist"
        Assert-True ([bool]$cell.ReportEvidence) "$($cell.Id) should define report evidence"
        Assert-True ($cell.PartnerCommand -match '-ReportPath') "$($cell.Id) should provide a report-producing partner command"
        $resolvedCell = Resolve-AiCapabilityCell -Id $cell.Id
        Assert-True ($null -ne $resolvedCell) "$($cell.Id) resolver fixture should return a plan"
    } else {
        Assert-True $cell.ContainsKey('Blocker') "$($cell.Id) should explain the authoritative upstream boundary"
        try {
            Resolve-AiCapabilityCell -Id $cell.Id
            throw "Capability '$($cell.Id)' unexpectedly resolved."
        } catch {
            Assert-Equal $_.Exception.Message $cell.Blocker "$($cell.Id) should return its actionable blocker"
        }
    }
}
$capabilityReportPath = Join-Path $env:TEMP "devconfig-capabilities-$([guid]::NewGuid().ToString('N')).json"
try {
    & (Join-Path $repositoryRoot 'src\tools\get-ai-capabilities.ps1') -OutputPath $capabilityReportPath
    $capabilityReport = Get-Content -LiteralPath $capabilityReportPath -Raw | ConvertFrom-Json
    Assert-Equal $capabilityReport.capabilities.Count $capabilities.Count 'Capability report tool should emit every catalog cell'
    Assert-True (@($capabilityReport.capabilities | Where-Object status -eq 'source-managed').Count -gt 0) 'Capability report should preserve source-managed status'
} finally {
    Remove-Item -LiteralPath $capabilityReportPath -Force -ErrorAction SilentlyContinue
}

$wingetArgs = Get-DevConfigWingetInstallArguments -Id 'Microsoft.FoundryLocal'
Assert-Equal ($wingetArgs -join ' ') 'install --id Microsoft.FoundryLocal --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' 'Shared WinGet install command should be exact and noninteractive'
$upgradeArgs = Get-DevConfigWingetUpgradeArguments -Id 'Microsoft.VisualStudio.2022.BuildTools'
Assert-Equal ($upgradeArgs -join ' ') 'upgrade --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity' 'Shared WinGet upgrade command should be exact and noninteractive'
Assert-Equal (Get-AiWingetPackageAction -State Current) 'skip' 'Current packages should skip acquisition'
Assert-Equal (Get-AiWingetPackageAction -State UpgradeAvailable) 'upgrade' 'Outdated packages should upgrade'
Assert-Equal (Get-AiWingetPackageAction -State Absent) 'install' 'Absent packages should install'
Assert-True ([bool](Get-Command Ensure-DevConfigWingetPackage -ErrorAction SilentlyContinue)) 'Shared production package ensure function should be exported at script scope'

$currentShape = [pscustomobject]@{
    Id = 'Current.Package'
    Name = 'Current package'
    InstalledVersion = '1.0.0'
    IsUpdateAvailable = $false
}
$currentEvidence = ConvertTo-AiWingetPackageEvidence -Package $currentShape -RequestedId 'Current.Package'
Assert-Equal $currentEvidence.installedVersion '1.0.0' 'Evidence should support current module object shape without AvailableVersion'
Assert-Equal $currentEvidence.availableVersion '' 'Missing optional AvailableVersion should not fail evidence collection'

$olderShape = [pscustomobject]@{
    PackageIdentifier = 'Older.Package'
    PackageName = 'Older package'
    Version = '2.0.0'
    LatestVersion = '2.1.0'
    UpdateAvailable = $true
}
$olderEvidence = ConvertTo-AiWingetPackageEvidence -Package $olderShape -RequestedId 'fallback'
Assert-Equal $olderEvidence.id 'Older.Package' 'Evidence should support alternate identifier names'
Assert-Equal $olderEvidence.availableVersion '2.1.0' 'Evidence should support alternate latest-version names'
Assert-True $olderEvidence.updateAvailable 'Evidence should support alternate update flags'

$minimalEvidence = ConvertTo-AiWingetPackageEvidence -Package ([pscustomobject]@{}) -RequestedId 'Minimal.Package'
Assert-Equal $minimalEvidence.id 'Minimal.Package' 'Minimal package objects should retain the requested id'
Assert-Equal $minimalEvidence.installedVersion '' 'Minimal package objects should not fail under StrictMode'

# Keep fallback tests fast and deterministic by invoking each retry body once.
function Invoke-DevConfigRetry {
    param([scriptblock] $ScriptBlock, [string] $Name, [int] $MaxAttempts, [int] $InitialDelaySeconds)
    & $ScriptBlock
}
$Script:DevConfigWinGetMode = 'Module'
$script:cliArguments = $null
function Test-DevConfigWingetCliUsable { return $true }
function Install-WinGetPackage { throw 'module install error' }
function Update-WinGetPackage { throw 'module upgrade error' }
function Invoke-DevConfigWingetCli {
    param([string[]] $Arguments)
    $script:cliArguments = $Arguments
    return [pscustomobject]@{ ExitCode = 0; Output = '' }
}
Install-DevConfigWingetPackage -Id 'Fallback.Install'
Assert-Equal $script:cliArguments[0] 'install' 'Module install error should fall back to CLI install'
$Script:DevConfigWinGetMode = 'Module'
$script:updateModuleCalls = 0
function Update-WinGetPackage { $script:updateModuleCalls++; throw 'module upgrade error' }
Update-DevConfigWingetPackage -Id 'Fallback.Upgrade'
Assert-Equal $script:cliArguments[0] 'upgrade' 'Module upgrade error should fall back to CLI upgrade'
Assert-Equal $script:updateModuleCalls 1 'Upgrade fallback should attempt the module before CLI'

$Script:DevConfigWinGetMode = 'Module'
function Invoke-DevConfigWingetCli {
    param([string[]] $Arguments)
    return [pscustomobject]@{ ExitCode = 9; Output = 'real failure' }
}
Assert-ThrowsLike {
    Update-DevConfigWingetPackage -Id 'Fallback.Failure'
} '*CLI exit: 9*' 'A real nonzero module and CLI failure should remain fatal'

# Exercise Ensure-AiWingetPackage's state machine without touching machine state.
$script:packageState = 'Current'
$script:installCount = 0
$script:upgradeCount = 0
function Initialize-DevConfigWinGet {}
function Get-DevConfigWingetPackageState { param($Id) [pscustomobject]@{ State = $script:packageState; Package = $null } }
function Install-DevConfigWingetPackage { param($Id) $script:installCount++ }
function Update-DevConfigWingetPackage { param($Id) $script:upgradeCount++ }
function Wait-DevConfigWingetPackageSettled { param($Id) }
function Ensure-DevConfigWingetPackage {
    param($Id)
    $operation = Get-AiWingetPackageAction -State $script:packageState
    if ($operation -eq 'install') { $script:installCount++; return 'installed' }
    if ($operation -eq 'upgrade') { $script:upgradeCount++; return 'upgraded' }
    return 'already-current'
}
function Update-DevConfigSessionPath {}
function Test-DevConfigWingetPackageInstalled { param($Id) return $true }
function Get-AiWingetPackageEvidence { param($Id) return @{ id = $Id } }

$currentResult = Ensure-AiWingetPackage -Id 'State.Current'
Assert-Equal $currentResult.Action 'already-current' 'Installed current package should skip'
Assert-Equal $script:installCount 0 'Current package should not install'
Assert-Equal $script:upgradeCount 0 'Current package should not upgrade'

$script:packageState = 'UpgradeAvailable'
$upgradeResult = Ensure-AiWingetPackage -Id 'State.Upgrade'
Assert-Equal $upgradeResult.Action 'upgraded' 'Installed outdated package should upgrade'
Assert-Equal $script:upgradeCount 1 'Upgrade state should invoke upgrade exactly once'

$script:packageState = 'Absent'
$installResult = Ensure-AiWingetPackage -Id 'State.Absent'
Assert-Equal $installResult.Action 'installed' 'Absent package should install'
Assert-Equal $script:installCount 1 'Absent state should invoke install exactly once'

$directSetup = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\_common\direct-setup.ps1') -Raw
Assert-True ($directSetup.Contains('''--installPath'', "`"$installPath`""')) 'Build Tools install path should remain one quoted Start-Process argument'
Assert-True ($directSetup -match 'Get-AiWingetPackageEvidence') 'Package evidence should respect the selected WinGet frontend'
Assert-True ($directSetup -match 'Enable-AiUtf8Console') 'Standalone AI entry points should normalize UTF-8 console capture'

$freshProcessScript = Join-Path $env:TEMP "devconfig-lastexitcode-$([guid]::NewGuid().ToString('N')).ps1"
try {
    @(
        'Set-StrictMode -Version Latest',
        ". '$((Resolve-Path (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\_environment.ps1')).Path)'",
        '$result = Invoke-DevConfigNativeCommand -FilePath $env:ComSpec -Arguments @(''/d'',''/c'',''exit 0'')',
        'if ($result.ExitCode -ne 0) { throw "unexpected exit $($result.ExitCode)" }',
        'try { Invoke-DevConfigNativeCommand -FilePath ''__missing_devconfig_command__.exe'' } catch { Write-Output MISSING_NATIVE_FAILED }',
        'Write-Output FRESH_LASTEXITCODE_OK'
    ) | Set-Content -LiteralPath $freshProcessScript -Encoding utf8
    $freshResult = & pwsh -NoProfile -File $freshProcessScript 2>&1 | Out-String
    Assert-True ($freshResult -match 'FRESH_LASTEXITCODE_OK') 'Fresh StrictMode process should execute native command without preexisting LASTEXITCODE'
    Assert-True ($freshResult -match 'MISSING_NATIVE_FAILED') 'Fresh StrictMode process should treat native launch failure as failure'
} finally {
    Remove-Item -LiteralPath $freshProcessScript -Force -ErrorAction SilentlyContinue
}

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
