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
$pipeline = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\.pipelines\OneBranch.SignAndPackage.yml') -Raw
Assert-True ($pipeline -match 'files_to_sign:\s*''src/\*\*/\*\.ps1;src/\*\*/\*\.psd1''') 'Release signing should include PowerShell data files'
& {
    . (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\_security.ps1')
    $fixture = Join-Path $env:TEMP "devconfig-data-signing-$([guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $fixture | Out-Null
        $dataPath = Join-Path $fixture 'catalog.psd1'
        Set-Content -LiteralPath $dataPath -Value '@{ Value = 1 }' -Encoding UTF8
        Assert-ThrowsLike {
            Assert-DevConfigMicrosoftSigned -Directory $fixture
        } '*catalog.psd1 *NotSigned*' 'Production verification should reject unsigned data files'

        $signatureStatus = 'Valid'
        $signerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        function Get-AuthenticodeSignature {
            param([string] $LiteralPath)
            [pscustomobject]@{
                Status = $signatureStatus
                SignerCertificate = [pscustomobject]@{ Subject = $signerSubject }
            }
        }
        Assert-DevConfigMicrosoftSigned -Directory $fixture
        $signerSubject = 'CN=Other publisher'
        Assert-ThrowsLike {
            Assert-DevConfigMicrosoftSigned -Directory $fixture
        } '*catalog.psd1 *unexpected signer*' 'Production verification should reject data files from other publishers'
        $signatureStatus = 'HashMismatch'
        Assert-ThrowsLike {
            Assert-DevConfigMicrosoftSigned -Directory $fixture
        } '*catalog.psd1 *HashMismatch*' 'Production verification should reject tampered signed data files'

        $sourceDirectory = Join-Path $fixture 'src\Workloads'
        $releaseDirectory = Join-Path $fixture 'Workloads'
        New-Item -ItemType Directory -Path $sourceDirectory, $releaseDirectory | Out-Null
        $sourceData = Join-Path $sourceDirectory 'catalog.psd1'
        $releaseData = Join-Path $releaseDirectory 'catalog.psd1'
        Set-Content -LiteralPath $sourceData -Value '@{ Value = 1 }' -Encoding UTF8
        Set-Content -LiteralPath $releaseData -Value @('@{ Value = 1 }', '', '# SIG # Begin signature block', '# Test signature', '# SIG # End signature block') -Encoding UTF8
        Assert-Equal (Import-PowerShellDataFile -LiteralPath $releaseData).Value 1 'Signature footer should not change catalog import'
        $report = & (Join-Path $PSScriptRoot '..\..\tools\check-signed-drift.ps1') -RepoRoot $fixture | ConvertFrom-Json
        Assert-Equal $report.files[0].status 'ok' 'Signed data file comparison should ignore the signature footer'
        Set-Content -LiteralPath $releaseData -Value @('@{ Value = 2 }', '', '# SIG # Begin signature block', '# Test signature', '# SIG # End signature block') -Encoding UTF8
        $report = & (Join-Path $PSScriptRoot '..\..\tools\check-signed-drift.ps1') -RepoRoot $fixture | ConvertFrom-Json
        Assert-Equal $report.files[0].status 'drifted' 'Signed data file comparison should detect changed catalog content'
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
$trackedContent = @(git -C (Join-Path $PSScriptRoot '..\..\..') ls-files 'src/Workloads/**' |
    Where-Object { [IO.Path]::GetExtension($_) -notin @('.ps1', '.psd1') } |
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
    if not path.lower().endswith((".ps1", ".psd1"))
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
Assert-Equal ($wingetArgs -join ' ') 'install --id Microsoft.FoundryLocal --exact --source winget --silent --accept-package-agreements --accept-source-agreements' 'Default install arguments should retain workstation behavior'
$wingetArgs = Get-DevConfigWingetInstallArguments -Id 'Microsoft.FoundryLocal' -DisableInteractivity
Assert-True ($wingetArgs -contains '--disable-interactivity') 'AI installs should opt into disabled interactivity'
$upgradeArgs = Get-DevConfigWingetUpgradeArguments -Id 'Microsoft.VisualStudio.2022.BuildTools'
Assert-Equal ($upgradeArgs -join ' ') 'upgrade --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --silent --accept-package-agreements --accept-source-agreements' 'Default upgrade arguments should not disable interactivity'
$upgradeArgs = Get-DevConfigWingetUpgradeArguments -Id 'Microsoft.VisualStudio.2022.BuildTools' -DisableInteractivity
Assert-True ($upgradeArgs -contains '--disable-interactivity') 'AI upgrades should opt into disabled interactivity'
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
    param([scriptblock] $ScriptBlock, [string] $Name, [int] $MaxAttempts, [int] $InitialDelaySeconds, [scriptblock] $ShouldRetry)
    & $ScriptBlock
}
$Script:DevConfigWinGetMode = 'Module'
$script:cliArguments = $null
$script:cliCalls = 0
$script:cliChecks = 0
$script:cliAvailable = $true
$script:cliExitCode = 0
$script:cliThrows = $false
$script:moduleStatus = 'Throw'
function Test-DevConfigWingetCliUsable { $script:cliChecks++; return $script:cliAvailable }
function Install-WinGetPackage {
    if ($script:moduleStatus -eq 'Throw') { throw 'module install error' }
    $result = [pscustomobject]@{ Status = $script:moduleStatus; ExtendedErrorCode = $null }
    $result | Add-Member -MemberType ScriptMethod -Name Succeeded -Value { $this.Status -eq 'Ok' }
    $result | Add-Member -MemberType ScriptMethod -Name ErrorMessage -Value { 'module result error' }
    return $result
}
function Update-WinGetPackage { throw 'module upgrade error' }
function Invoke-DevConfigWingetCli {
    param([string[]] $Arguments)
    $script:cliCalls++
    $script:cliArguments = $Arguments
    $script:cliModeAtCall = $Script:DevConfigWinGetMode
    if ($script:cliThrows) { throw 'CLI query failed.' }
    return [pscustomobject]@{ ExitCode = $script:cliExitCode; Output = 'CLI output' }
}
Assert-ThrowsLike {
    Install-DevConfigWingetPackage -Id 'Legacy.Exception'
} 'module install error' 'Default installs should propagate module exceptions without CLI fallback'
Assert-Equal $script:cliCalls 0 'Default module failures must not invoke the CLI'
Assert-Equal $script:cliChecks 0 'Default module failures must not probe CLI availability'
Assert-Equal $Script:DevConfigWinGetMode 'Module' 'Default module failures must not change the selected frontend'
$script:moduleStatus = 'Failed'
Assert-ThrowsLike {
    Install-DevConfigWingetPackage -Id 'Legacy.Result'
} 'winget install Legacy.Result failed: module result error' 'Default installs should retain the existing failed-result message'
Assert-Equal $script:cliCalls 0 'Default failed module results must not invoke the CLI'
foreach ($script:moduleStatus in @('Ok', 'NoApplicableUpgrade')) {
    Install-DevConfigWingetPackage -Id 'Legacy.Success'
    Assert-Equal $script:cliCalls 0 'Successful and already-current module results must not invoke the CLI'
}
$script:moduleStatus = 'Throw'
foreach ($allowFallback in @($false, $true)) {
    foreach ($disableInteractivity in @($false, $true)) {
        $Script:DevConfigWinGetMode = 'Cli'
        Install-DevConfigWingetPackage -Id 'Options.Install' -AllowCliFallback:$allowFallback -DisableInteractivity:$disableInteractivity
        Assert-Equal ($script:cliArguments -contains '--disable-interactivity') $disableInteractivity 'CLI interactivity should be independent of the fallback option'
    }
}

$Script:DevConfigWinGetMode = 'Cli'
$script:cliExitCode = $Script:DevConfigWingetNoUpgrade
Install-DevConfigWingetPackage -Id 'Legacy.Current'
$script:cliExitCode = 9
Assert-ThrowsLike {
    Install-DevConfigWingetPackage -Id 'Legacy.CliFailure'
} '*failed with exit code 9' 'Default CLI failures should remain fatal'
$script:cliExitCode = 0
$Script:DevConfigWinGetMode = 'Module'
Install-DevConfigWingetPackage -Id 'Fallback.Install' -AllowCliFallback -DisableInteractivity
Assert-Equal $script:cliArguments[0] 'install' 'Module install error should fall back to CLI install'
Assert-True ($script:cliArguments -contains '--disable-interactivity') 'AI install fallback should remain noninteractive'
Assert-Equal $Script:DevConfigWinGetMode 'Cli' 'Successful AI fallback should retain CLI mode for subsequent operations'
$Script:DevConfigWinGetMode = 'Module'
$script:moduleStatus = 'Failed'
Install-DevConfigWingetPackage -Id 'Fallback.Result' -AllowCliFallback -DisableInteractivity
Assert-Equal $Script:DevConfigWinGetMode 'Cli' 'Failed module results should also use the opted-in fallback'
$script:moduleStatus = 'Throw'
$Script:DevConfigWinGetMode = 'Module'
$script:cliAvailable = $false
$callsBefore = $script:cliCalls
Assert-ThrowsLike {
    Install-DevConfigWingetPackage -Id 'Fallback.Unavailable' -AllowCliFallback -DisableInteractivity
} 'module install error' 'An unavailable CLI must not replace the original module failure'
Assert-Equal $script:cliCalls $callsBefore 'Fallback must not execute an unusable CLI'
$script:cliAvailable = $true
$Script:DevConfigWinGetMode = 'Module'
$script:updateModuleCalls = 0
function Update-WinGetPackage { $script:updateModuleCalls++; throw 'module upgrade error' }
Update-DevConfigWingetPackage -Id 'Fallback.Upgrade' -AllowCliFallback -DisableInteractivity
Assert-Equal $script:cliArguments[0] 'upgrade' 'Module upgrade error should fall back to CLI upgrade'
Assert-Equal $script:updateModuleCalls 1 'Upgrade fallback should attempt the module before CLI'
Assert-True ($script:cliArguments -contains '--disable-interactivity') 'AI upgrade fallback should remain noninteractive'

$Script:DevConfigWinGetMode = 'Module'
$script:cliExitCode = 9
Assert-ThrowsLike {
    Install-DevConfigWingetPackage -Id 'Fallback.Failure' -AllowCliFallback -DisableInteractivity
} '*CLI exit: 9*' 'A real nonzero install fallback failure should remain fatal'
Assert-Equal $Script:DevConfigWinGetMode 'Module' 'Failed fallback must not switch the selected frontend'
Assert-ThrowsLike {
    Update-DevConfigWingetPackage -Id 'Fallback.Failure' -AllowCliFallback -DisableInteractivity
} '*CLI exit: 9*' 'A real nonzero module and CLI failure should remain fatal'

# Exercise Ensure-AiWingetPackage's state machine without touching machine state.
$script:packageState = 'Current'
$script:installCount = 0
$script:upgradeCount = 0
$script:initializeCount = 0
$script:readinessCount = 0
$script:repairCount = 0
$script:readinessMode = 'Ready'
$script:wingetCallOrder = [Collections.Generic.List[string]]::new()
$Script:DevConfigWinGetMode = 'Module'
$script:cliExitCode = 0
$script:setCurrentOnAcquire = $true
# Match the module's error identity without installing it on the test host.
if (-not ('Microsoft.WinGet.Client.Engine.Exceptions.WinGetIntegrityException' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Microsoft.WinGet.Client.Engine.Exceptions {
    public class WinGetIntegrityException : System.Management.Automation.RuntimeException {
        public string Category { get; private set; }
        public WinGetIntegrityException(string category, string message) : base(message) {
            Category = category;
        }
    }
}
'@
}
function Initialize-DevConfigWinGet {
    $script:initializeCount++
    $script:wingetCallOrder.Add('initialize')
}
function Get-WinGetPackage {
    [CmdletBinding()]
    param($Source)
    $script:readinessCount++
    $script:wingetCallOrder.Add('ready')
    if ($script:readinessMode -in @('Fallback', 'FallbackFailure') -or
        ($script:readinessMode -in @('Repair', 'UnavailableAfterRepair') -and $script:repairCount -eq 0)) {
        throw [Runtime.InteropServices.COMException]::new('WinGet RPC unavailable.', -2147023174)
    }
    if ($script:readinessMode -in @('Unavailable', 'UnavailableAfterRepair', 'OtherIntegrity')) {
        $category = if ($script:readinessMode -eq 'OtherIntegrity') { 'AppInstallerNoLicense' } else { 'AppInstallerNotInstalled' }
        throw [Microsoft.WinGet.Client.Engine.Exceptions.WinGetIntegrityException]::new($category, 'Localized availability failure.')
    }
    if ($script:readinessMode -eq 'MessageOnly') { throw 'The App Installer is not installed.' }
    if ($script:readinessMode -eq 'Fatal') { throw 'WinGet readiness failed.' }
}
function Invoke-DevConfigWinGetDeployment {
    $script:repairCount++
    $script:wingetCallOrder.Add('repair')
}
function Get-DevConfigWingetPackageState {
    param($Id)
    $script:wingetCallOrder.Add('query')
    [pscustomobject]@{ State = $script:packageState; Package = $null }
}
function Install-DevConfigWingetPackage {
    param($Id, [switch] $AllowCliFallback, [switch] $DisableInteractivity)
    $script:installCount++
    $script:installOptions = @([bool]$AllowCliFallback, [bool]$DisableInteractivity)
    if ($script:setCurrentOnAcquire) { $script:packageState = 'Current' }
}
function Update-DevConfigWingetPackage {
    param($Id, [switch] $AllowCliFallback, [switch] $DisableInteractivity)
    $script:upgradeCount++
    $script:upgradeOptions = @([bool]$AllowCliFallback, [bool]$DisableInteractivity)
    if ($script:setCurrentOnAcquire) { $script:packageState = 'Current' }
}
function Wait-DevConfigWingetPackageSettled { param($Id) }
function Update-DevConfigSessionPath {}
function Test-DevConfigWingetPackageInstalled { param($Id) return $true }
function Get-AiWingetPackageEvidence { param($Id) return @{ id = $Id } }

$currentResult = Ensure-AiWingetPackage -Id 'State.Current'
Assert-Equal $currentResult.Action 'already-current' 'Installed current package should skip'
Assert-Equal ($script:wingetCallOrder -join ',') 'initialize,ready,query' 'AI should initialize WinGet and confirm readiness before its first package query'
Assert-Equal $script:installCount 0 'Current package should not install'
Assert-Equal $script:upgradeCount 0 'Current package should not upgrade'

$script:packageState = 'UpgradeAvailable'
$upgradeResult = Ensure-AiWingetPackage -Id 'State.Upgrade'
Assert-Equal $upgradeResult.Action 'upgraded' 'Installed outdated package should upgrade'
Assert-Equal $script:upgradeCount 1 'Upgrade state should invoke upgrade exactly once'
Assert-True ($script:upgradeOptions[0] -and $script:upgradeOptions[1]) 'AI should opt into fallback and disabled interactivity for upgrades'

$script:packageState = 'Absent'
$installResult = Ensure-AiWingetPackage -Id 'State.Absent'
Assert-Equal $installResult.Action 'installed' 'Absent package should install'
Assert-Equal $script:installCount 1 'Absent state should invoke install exactly once'
Assert-True ($script:installOptions[0] -and $script:installOptions[1]) 'AI should opt into fallback and disabled interactivity for installs'

$planResult = Ensure-AiWingetPackage -Id 'State.Plan' -PlanOnly
Assert-Equal $planResult.Action 'install-or-upgrade' 'PlanOnly should retain its acquisition description'
Assert-Equal $script:initializeCount 3 'PlanOnly must not initialize WinGet'
Assert-Equal $script:readinessCount 3 'PlanOnly must not query or repair WinGet'
Assert-Equal $script:repairCount 0 'Healthy package operations must not repair WinGet'
Assert-Equal $script:installCount 1 'PlanOnly must not install packages'
Assert-Equal $script:upgradeCount 1 'PlanOnly must not upgrade packages'
$script:packageState = 'Absent'
$script:setCurrentOnAcquire = $false
Assert-ThrowsLike {
    Ensure-AiWingetPackage -Id 'State.Unverified'
} '*did not verify*' 'The real ensure helper must reject an installation that never becomes current'

$installsBeforeReadiness = $script:installCount
$upgradesBeforeReadiness = $script:upgradeCount
foreach ($script:readinessMode in @('Repair', 'Fallback', 'Fatal', 'FallbackFailure')) {
    $script:wingetCallOrder.Clear()
    $script:readinessCount = 0
    $script:repairCount = 0
    $script:packageState = 'Current'
    $Script:DevConfigWinGetMode = 'Module'
    $script:cliExitCode = if ($script:readinessMode -eq 'FallbackFailure') { 9 } else { 0 }
    if ($script:readinessMode -in @('Fatal', 'FallbackFailure')) {
        $expectedError = if ($script:readinessMode -eq 'Fatal') { 'WinGet readiness failed.' } else { '*winget.exe cannot query packages*' }
        Assert-ThrowsLike {
            Ensure-AiWingetPackage -Id 'Readiness.Failure'
        } $expectedError 'Readiness failures should stop AI before package acquisition'
        Assert-Equal (@($script:wingetCallOrder | Where-Object { $_ -eq 'query' }).Count) 0 'Failed readiness must not proceed to a package state query'
        Assert-Equal $Script:DevConfigWinGetMode 'Module' 'Failed readiness must not select an unusable CLI'
    } else {
        $readyResult = Ensure-AiWingetPackage -Id 'Readiness.Recovered'
        Assert-Equal $readyResult.Action 'already-current' 'AI should continue after shared readiness recovery'
        Assert-Equal ($script:wingetCallOrder -join ',') 'initialize,ready,repair,ready,query' 'Shared recovery should complete before querying AI package state'
        $expectedMode = if ($script:readinessMode -eq 'Repair') { 'Module' } else { 'Cli' }
        Assert-Equal $Script:DevConfigWinGetMode $expectedMode 'AI should respect the frontend selected by shared readiness recovery'
        if ($script:readinessMode -eq 'Fallback') {
            Assert-Equal $script:cliArguments[0] 'list' 'Readiness fallback should verify that the CLI can query packages'
        }
    }
    Assert-Equal $script:repairCount ([int]($script:readinessMode -ne 'Fatal')) 'Only RPC failures should trigger the existing repair'
}
Assert-Equal $script:installCount $installsBeforeReadiness 'Readiness checks must not install a current package or continue after failure'
Assert-Equal $script:upgradeCount $upgradesBeforeReadiness 'Readiness checks must not upgrade a current package or continue after failure'

foreach ($case in @(
    @{ Mode = 'Unavailable'; Allow = $false; Repairs = 0; CliCalls = 0; ExitCode = 0; Throws = $false; Error = 'Localized availability failure.' }
    @{ Mode = 'UnavailableAfterRepair'; Allow = $false; Repairs = 1; CliCalls = 0; ExitCode = 0; Throws = $false; Error = 'Localized availability failure.' }
    @{ Mode = 'Unavailable'; Allow = $true; Repairs = 0; CliCalls = 1; ExitCode = 0; Throws = $false; Error = $null }
    @{ Mode = 'UnavailableAfterRepair'; Allow = $true; Repairs = 1; CliCalls = 1; ExitCode = 0; Throws = $false; Error = $null }
    @{ Mode = 'Unavailable'; Allow = $true; Repairs = 0; CliCalls = 1; ExitCode = $Script:DevConfigWingetNotFound; Throws = $false; Error = $null }
    @{ Mode = 'Unavailable'; Allow = $true; Repairs = 0; CliCalls = 1; ExitCode = 9; Throws = $false; Error = '*Localized availability failure*winget.exe cannot query packages*' }
    @{ Mode = 'Unavailable'; Allow = $true; Repairs = 0; CliCalls = 1; ExitCode = 0; Throws = $true; Error = '*Localized availability failure*CLI query failed*' }
    @{ Mode = 'OtherIntegrity'; Allow = $true; Repairs = 0; CliCalls = 0; ExitCode = 0; Throws = $false; Error = 'Localized availability failure.' }
    @{ Mode = 'MessageOnly'; Allow = $true; Repairs = 0; CliCalls = 0; ExitCode = 0; Throws = $false; Error = 'The App Installer is not installed.' }
    @{ Mode = 'Fallback'; Allow = $false; Repairs = 1; CliCalls = 1; ExitCode = 0; Throws = $false; Error = $null }
)) {
    $script:readinessMode = $case.Mode
    $script:readinessCount = 0
    $script:repairCount = 0
    $script:cliCalls = 0
    $script:cliExitCode = $case.ExitCode
    $script:cliThrows = $case.Throws
    $Script:DevConfigWinGetMode = 'Module'
    $confirmReadiness = {
        if ($case.Allow) { Confirm-DevConfigWinGetReady -AllowCliFallback } else { Confirm-DevConfigWinGetReady }
    }
    if ($case.Error) {
        Assert-ThrowsLike $confirmReadiness $case.Error 'Readiness should preserve defaults, unrelated errors, and CLI failures'
        Assert-Equal $Script:DevConfigWinGetMode 'Module' 'Failed readiness must not select CLI fallback'
    } else {
        & $confirmReadiness
        Assert-Equal $Script:DevConfigWinGetMode 'Cli' 'Opted-in availability errors and existing RPC failures should select the verified CLI'
    }
    Assert-Equal $script:readinessCount (1 + $case.Repairs) 'Readiness should retry only through the existing RPC repair path'
    Assert-Equal $script:repairCount $case.Repairs 'App Installer availability fallback must not introduce additional repairs'
    Assert-Equal $script:cliCalls $case.CliCalls 'Only an eligible readiness failure should query the CLI'
    if ($script:cliCalls) {
        Assert-Equal $script:cliModeAtCall 'Module' 'Readiness must query the CLI before selecting it'
        Assert-Equal ($script:cliArguments -join ' ') 'list --source winget --accept-source-agreements --disable-interactivity' 'Fallback must verify a real noninteractive package query'
    }
}
$script:readinessMode = 'UnavailableAfterRepair'
$script:readinessCount = 0
$script:repairCount = 0
$script:cliCalls = 0
$script:cliExitCode = 0
$script:cliThrows = $false
$script:wingetCallOrder.Clear()
$Script:DevConfigWinGetMode = 'Module'
$readyResult = Ensure-AiWingetPackage -Id 'Readiness.AppInstallerUpdate'
Assert-Equal $readyResult.Action 'already-current' 'AI should opt into readiness fallback after an App Installer update'
Assert-Equal $Script:DevConfigWinGetMode 'Cli' 'AI package acquisition should retain the verified fallback'
Assert-Equal ($script:wingetCallOrder -join ',') 'initialize,ready,repair,ready,query' 'AI should resolve the changed readiness error before querying package state'
Assert-Equal $script:cliCalls 1 'AI should verify the CLI exactly once before proceeding'
Assert-Equal $script:installCount $installsBeforeReadiness 'Availability recovery must not reinstall a current package'
Assert-Equal $script:upgradeCount $upgradesBeforeReadiness 'Availability recovery must not upgrade a current package'
foreach ($mode in @('Module', 'Cli')) {
    foreach ($allow in @($false, $true)) {
        $Script:DevConfigWinGetMode = $mode
        $script:readinessMode = if ($mode -eq 'Cli') { 'Fatal' } else { 'Ready' }
        $script:readinessCount = 0
        $script:repairCount = 0
        $script:cliCalls = 0
        Confirm-DevConfigWinGetReady -AllowCliFallback:$allow
        Assert-Equal $Script:DevConfigWinGetMode $mode 'Ready frontends should remain selected regardless of the opt-in'
        Assert-Equal $script:readinessCount ([int]($mode -eq 'Module')) 'Already-selected CLI should bypass module readiness'
        Assert-Equal $script:repairCount 0 'Ready frontends must not trigger repair'
        Assert-Equal $script:cliCalls 0 'Ready frontends must not repeat CLI fallback queries'
    }
}
$Script:DevConfigWinGetMode = 'Module'
$script:readinessMode = 'Ready'
$script:cliExitCode = 0

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
