$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\_harness\assertions.ps1')

$script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\local-ai\install.ps1') -Raw
Assert-True ($script -match "ValidateSet\('Auto', 'CPU', 'CUDA', 'ROCm', 'XPU'\)") 'Scenario should expose deterministic PyTorch backend selection'
Assert-True ($script -match "ValidateSet\('None', 'LlamaCpp', 'Ollama', 'Foundry'\)") 'Scenario should keep model runtimes optional'
Assert-True ($script -match 'collect-ai-hardware\.ps1') 'Scenario should capture hardware before acquisition'
Assert-True ($script -match '\.\.\\_common\\collect-ai-hardware\.ps1') 'Signed scenario should resolve inventory inside the packaged Workloads tree'
Assert-True ($script -match 'Workloads\\pytorch\\install\.ps1') 'Scenario should always provide the core PyTorch path'
Assert-True ($script -match 'LOCAL_AI_SCENARIO_READY') 'Scenario should emit a clear readiness marker'
Assert-True ($script -match 'LOCAL_AI_SCENARIO_PLAN_OK') 'Scenario should expose a non-mutating plan marker'
Assert-True ($script -match 'LOCAL_AI_SCENARIO_UNSUPPORTED') 'Scenario should propagate child plan blockers instead of claiming plan success'

$smoke = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\smoke.py') -Raw
Assert-True ($smoke -match 'torch\.nn\.Sequential') 'PyTorch readiness should execute a minimal neural model'
Assert-True ($smoke -match 'model_forward_verified') 'PyTorch report should identify the model forward pass'

$coding = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\llama.cpp\coding-demo.ps1') -Raw
Assert-True ($coding -match 'Qwen2\.5-Coder-1\.5B-Instruct') 'Optional coding demo should use the documented practical coding model'
Assert-True ($coding -match 'CODING_DEMO_READY') 'Optional coding demo should emit a clear readiness marker'
Assert-True ($coding -notmatch '\[string\]\s*\$Prompt') 'Coding demo should keep its validation prompt fixed'

$readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\windows-dev-config\ai-workloads.md') -Raw
Assert-True ($readme -match 'Workloads\\local-ai\\install\.ps1') 'AI workloads doc should lead with the local AI scenario entry point'
Assert-True ($readme -match 'aka\.ms/devconfig/local-ai/setup\.ps1') 'AI workloads doc should provide the local AI short link'
Assert-True ($readme -match 'bootstrap\.ps1''\s*\r?\n& \(\[scriptblock\]::Create\(\(irm \$url\)\)\) -Scenario local-ai') 'AI workloads doc should document the production product-level dispatcher'
Assert-True ($readme -match 'LOCAL_AI_SCENARIO_READY') 'AI workloads doc should document the scenario readiness marker'
Assert-True ($readme -match '(?s)-AiBackend Auto.*?-RequireTriton.*?-AiRuntime Ollama') 'AI workloads doc should document the Windows ARM64 NVIDIA product golden path'
Assert-True ($readme -match '\\src\\Workloads\\local-ai\\install\.ps1.*?-Backend Auto.*?-RequireTriton.*?-Runtime Ollama') 'AI workloads doc should distinguish cloned-repository scenario usage from bootstrap'
Assert-True ($readme -match 'CODING_DEMO_READY') 'AI workloads doc should document the optional coding-demo readiness marker'
Assert-True ($readme -match 'replacement for PyPI/Conda') 'AI workloads doc should state the scenario non-goal'
foreach ($entryPoint in @('local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry')) {
    Assert-True ($readme -match [regex]::Escape("| ``$entryPoint")) "AI workloads doc transitive-acquisition table should include $entryPoint"
}

$pytorch = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\install.ps1') -Raw
Assert-True ($pytorch -match '\$plan\.InstallTriton.*CUDA.*XPU') 'PyTorch should gate native toolchains on supported Triton backends'
Assert-True ($pytorch -match 'Ensure-AiVisualCppTools') 'PyTorch Triton should ensure the native MSVC toolchain'
Assert-True ($pytorch -match 'Ensure-AiCudaToolkit') 'PyTorch CUDA Triton should ensure the standalone CUDA toolkit'
Assert-True ($pytorch -match 'Add-AiReportAcquisition') 'PyTorch should report its transitive acquisitions'

$fixtureRoot = Join-Path $env:TEMP "devconfig-triton-plan-$([guid]::NewGuid().ToString('N'))"
$testSourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
try {
    foreach ($relativePath in @(
        'Workloads\local-ai\install.ps1'
        'Workloads\pytorch\install.ps1'
        'Workloads\_common\ai-support.ps1'
        'Workloads\_common\ai-catalog.psd1'
        'Workloads\_common\ai-report.ps1'
        'windows-dev-config\steps\_environment.ps1'
    )) {
        $destination = Join-Path $fixtureRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $testSourceRoot $relativePath) -Destination $destination
    }
    @'
. (Join-Path $PSScriptRoot 'ai-support.ps1')
. (Join-Path $PSScriptRoot '..\..\windows-dev-config\steps\_environment.ps1')
function Get-DevConfigArchitecture { 'X64' }
function Get-AiDetectedVendor { 'None' }
function Get-AmdGpuName {}
function Get-IntelGpuName {}
function Get-NvidiaDriverInfo {}
function Get-NvidiaGpu {}
function Assert-AiAdministrator { throw 'Plan tests must not apply changes.' }
function Get-PythonEnvironmentVersions { throw 'Plan tests must not change the environment.' }
function Ensure-AiWingetPackage {
    param($Id, [switch] $PlanOnly)
    if (-not $PlanOnly) { throw 'Plan tests must not install packages.' }
    [pscustomobject]@{ Id = $Id; Action = 'install-or-upgrade'; Source = 'winget' }
}
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'Workloads\_common\direct-setup.ps1') -Encoding UTF8
    @'
param([string] $OutputPath)
'{}' | Set-Content -LiteralPath $OutputPath -Encoding UTF8
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'Workloads\_common\collect-ai-hardware.ps1') -Encoding UTF8
    foreach ($case in @(
        @{ RequireTriton = $false; Runtime = 'None' }
        @{ RequireTriton = $true; Runtime = 'None' }
        @{ RequireTriton = $true; Runtime = 'Ollama' }
    )) {
        $reportRoot = Join-Path $fixtureRoot "reports\$($case.RequireTriton)-$($case.Runtime)"
        $messages = @(& (Join-Path $fixtureRoot 'Workloads\local-ai\install.ps1') `
            -Backend CPU -PlanOnly -RequireTriton:$case.RequireTriton -Runtime $case.Runtime -ReportRoot $reportRoot 6>&1 |
            ForEach-Object { $_.ToString() })
        Assert-True (Test-Path -LiteralPath (Join-Path $reportRoot 'hardware.json') -PathType Leaf) 'Scenario planning should retain the inventory report'
        $report = Get-Content -LiteralPath (Join-Path $reportRoot 'pytorch.json') -Raw | ConvertFrom-Json
        Assert-True $report.result.planOnly 'The child report should identify plan mode'
        Assert-True (-not $report.result.ready) 'Planning must not claim workload readiness'
        Assert-Equal $report.request.RequireTriton $case.RequireTriton 'The scenario should forward the Triton requirement'
        Assert-Equal $report.result.blockers.Count ([int]$case.RequireTriton) 'Required Triton should block the unsupported CPU plan'
        Assert-Equal $report.acquisitions.Count 3 'A plan should retain Python, PyTorch and Visual C++ runtime acquisitions even when Triton is unsupported'
        Assert-Equal $report.acquisitions[2].packageId 'Microsoft.VCRedist.2015+.x64' 'Scenario planning should include the architecture-native runtime prerequisite'
        Assert-Equal $report.acquisitions[2].action 'install-or-upgrade' 'Scenario planning should describe rather than apply the runtime prerequisite'
        Assert-Equal (@($report.phases | Where-Object name -eq 'triton')[0].status) 'unsupported' 'The report should identify unsupported CPU Triton'
        Assert-Equal (@($messages | Where-Object { $_ -like 'PLAN_UNSUPPORTED: pytorch*' }).Count) ([int]$case.RequireTriton) 'The child should emit the correct planning marker'
        Assert-Equal (@($messages | Where-Object { $_ -like 'LOCAL_AI_SCENARIO_UNSUPPORTED:*' }).Count) ([int]$case.RequireTriton) 'The scenario should report child blockers without throwing'
        Assert-Equal (@($messages | Where-Object { $_ -like 'LOCAL_AI_SCENARIO_PLAN_OK:*' }).Count) ([int](-not $case.RequireTriton)) 'A blocked scenario must not claim plan success'
        Assert-Equal (@($messages | Where-Object { $_ -like 'LOCAL_AI_SCENARIO_READY:*' }).Count) 0 'Planning must not emit the scenario readiness marker'
    }

    @'
$global:devConfigScenarioFixture.HelperLoads++
function Enter-DevConfigSingleInstance {
    $global:devConfigScenarioFixture.Entries++
    if ($global:devConfigScenarioFixture.Busy) { return $false }
    $global:devConfigScenarioFixture.Held = $true
    return $true
}
function Exit-DevConfigSingleInstance {
    if (-not $global:devConfigScenarioFixture.Held) { throw 'The scenario released a lock it did not own.' }
    $global:devConfigScenarioFixture.Releases++
    $global:devConfigScenarioFixture.Held = $false
}
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'windows-dev-config\steps\_elevation.ps1') -Encoding UTF8
    @'
param([string] $OutputPath)
$global:devConfigScenarioFixture.Calls.Add('hardware')
if ($global:devConfigScenarioFixture.Held -eq $global:devConfigScenarioFixture.PlanOnly) {
    throw 'Hardware collection observed the wrong scenario lock state.'
}
if ($global:devConfigScenarioFixture.Failure -eq 'hardware') { throw 'Scenario fixture failure: hardware' }
'{}' | Set-Content -LiteralPath $OutputPath -Encoding UTF8
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'Workloads\_common\collect-ai-hardware.ps1') -Encoding UTF8
    $childFixture = @'
param($Backend, [switch] $RequireTriton, [switch] $PlanOnly, [string] $ReportPath)
$workload = Split-Path -Leaf $PSScriptRoot
$global:devConfigScenarioFixture.Calls.Add($workload)
if ($global:devConfigScenarioFixture.Held -eq [bool]$PlanOnly) {
    throw "The $workload child observed the wrong scenario lock state."
}
if ($global:devConfigScenarioFixture.Failure -eq $workload) { throw "Scenario fixture failure: $workload" }
$blockers = if ($global:devConfigScenarioFixture.Blocker -eq $workload) { @('Fixture blocker') } else { @() }
@{ result = @{
    blockers = @($blockers)
    ready = -not $PlanOnly -and $global:devConfigScenarioFixture.NotReady -ne $workload
} } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
'@
    foreach ($workload in @('pytorch', 'llama.cpp', 'ollama', 'foundry')) {
        $directory = Join-Path $fixtureRoot "Workloads\$workload"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $directory 'install.ps1') -Value $childFixture -Encoding UTF8
    }
    foreach ($case in @(
        @{ Name = 'core-only' }
        @{ Name = 'llama'; Runtime = 'LlamaCpp' }
        @{ Name = 'ollama'; Runtime = 'Ollama' }
        @{ Name = 'foundry'; Runtime = 'Foundry' }
        @{ Name = 'busy'; Busy = $true }
        @{ Name = 'inventory-error'; Failure = 'hardware' }
        @{ Name = 'pytorch-error'; Failure = 'pytorch' }
        @{ Name = 'runtime-error'; Runtime = 'Ollama'; Failure = 'ollama' }
        @{ Name = 'pytorch-blocker'; Runtime = 'Ollama'; Blocker = 'pytorch' }
        @{ Name = 'runtime-blocker'; Runtime = 'Foundry'; Blocker = 'foundry' }
        @{ Name = 'pytorch-not-ready'; NotReady = 'pytorch' }
        @{ Name = 'runtime-not-ready'; Runtime = 'Foundry'; NotReady = 'foundry' }
        @{ Name = 'plan-while-busy'; Runtime = 'Ollama'; Busy = $true; PlanOnly = $true }
    )) {
        $global:devConfigScenarioFixture = @{
            HelperLoads = 0; Entries = 0; Releases = 0; Held = $false
            Busy = [bool]$case['Busy']; PlanOnly = [bool]$case['PlanOnly']
            Failure = [string]$case['Failure']; Blocker = [string]$case['Blocker']; NotReady = [string]$case['NotReady']
            Calls = [Collections.Generic.List[string]]::new()
        }
        $runtime = if ($case.ContainsKey('Runtime')) { $case.Runtime } else { 'None' }
        $reportRoot = Join-Path $fixtureRoot "reports\lock-$($case.Name)"
        $invokeScenario = {
            & (Join-Path $fixtureRoot 'Workloads\local-ai\install.ps1') `
                -Backend CPU -Runtime $runtime -PlanOnly:$global:devConfigScenarioFixture.PlanOnly -ReportRoot $reportRoot
        }
        if ($case['Busy'] -and -not $case['PlanOnly']) {
            Assert-ThrowsLike { & $invokeScenario 6>$null } 'Setup is already running*' 'A busy setup lock should reject the scenario'
            Assert-Equal $global:devConfigScenarioFixture.Calls.Count 0 'A rejected scenario must not collect hardware or start child installers'
            Assert-True (-not (Test-Path -LiteralPath $reportRoot)) 'A rejected scenario must not overwrite reports from the active run'
        } elseif ($case['Failure']) {
            Assert-ThrowsLike { & $invokeScenario 6>$null } 'Scenario fixture failure:*' 'Scenario child errors should propagate through lock cleanup'
        } elseif ($case['NotReady']) {
            Assert-ThrowsLike { & $invokeScenario 6>$null } '*did not report result.ready=true.' 'The scenario should retain its readiness checks'
        } else {
            $messages = @(& $invokeScenario 6>&1 | ForEach-Object { $_.ToString() })
            $marker = if ($case['Blocker']) { 'UNSUPPORTED' } elseif ($case['PlanOnly']) { 'PLAN_OK' } else { 'READY' }
            Assert-Equal (@($messages | Where-Object { $_ -like "LOCAL_AI_SCENARIO_${marker}:*" }).Count) 1 'The scenario should retain its completion marker'
            if ($case['Blocker'] -eq 'pytorch') {
                Assert-Equal ($global:devConfigScenarioFixture.Calls -join ',') 'hardware,pytorch' 'A core blocker should still skip the optional runtime'
            } else {
                $runtimeName = if ($runtime -eq 'LlamaCpp') { 'llama.cpp' } else { $runtime.ToLowerInvariant() }
                $expectedCalls = if ($runtime -eq 'None') { 'hardware,pytorch' } else { "hardware,pytorch,$runtimeName" }
                Assert-Equal ($global:devConfigScenarioFixture.Calls -join ',') $expectedCalls 'The lock should cover the complete scenario in its existing order'
            }
        }
        Assert-Equal $global:devConfigScenarioFixture.HelperLoads ([int](-not $case['PlanOnly'])) 'PlanOnly should not load the setup lock helper'
        Assert-Equal $global:devConfigScenarioFixture.Entries ([int](-not $case['PlanOnly'])) 'Only an applying scenario should acquire the shared lock'
        Assert-Equal $global:devConfigScenarioFixture.Releases ([int](-not $case['PlanOnly'] -and -not $case['Busy'])) 'Every acquired lock should be released once, including errors and early returns'
        Assert-True (-not $global:devConfigScenarioFixture.Held) 'The scenario must not leave its setup lock held'
    }
} finally {
    Remove-Variable -Name devConfigScenarioFixture -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

$llama = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\llama.cpp\install.ps1') -Raw
Assert-True ($llama -notmatch 'Ensure-AiCudaToolkit') 'llama.cpp CUDA assets should not independently install the full CUDA toolkit'
Assert-True ($llama -match 'resolvedAssets') 'llama.cpp should report paired/runtime asset acquisition'

$ollama = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\ollama\install.ps1') -Raw
Assert-True ($ollama -match 'gpuFraction') 'Ollama should report its source-managed allocation'
$foundry = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\foundry\install.ps1') -Raw
Assert-True ($foundry -match 'selectedExecutionProvider') 'Foundry should report its source-managed EP'

$bootstrap = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\windows-dev-config\bootstrap.ps1') -Raw
Assert-True ($bootstrap -match "ValidateSet\('', 'local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry'\)") 'Bootstrap should expose the supported AI dispatchers'
Assert-True ($bootstrap -match 'Workloads\\\$Scenario\\install\.ps1') 'Bootstrap should route to the selected AI installer without running dev-config.ps1'
Assert-True ($bootstrap -match 'Assert-DevConfigMicrosoftSigned -Directory \$workloadsDir') 'Signed scenario payload should be Microsoft-signature verified'
Assert-True ($bootstrap -match 'Assert-DevConfigWorkloadContent -WorkloadsRoot \$workloadsDir') 'Signed scenario should verify non-PowerShell content before copy'
Assert-True ($bootstrap -match 'Assert-DevConfigWorkloadContent -WorkloadsRoot \(Join-Path \$scenarioRoot ''Workloads''\)') 'Installed scenario content should be reverified after protected copy'
Assert-True ($bootstrap -match 'Assert-DevConfigProtectedTree -Directory \$workloadsDir') 'Scenario payload should be protected before copy'
Assert-True ($bootstrap -match 'Copy-Item -LiteralPath \$workloadsDir') 'Bootstrap should copy the complete multi-file Workloads dependency tree'
Assert-True ($bootstrap -match 'Join-Path \$setupDir ''steps''') 'Bootstrap should copy the shared Windows Dev Config helper steps'
Assert-True ($bootstrap -match '& \$shell @scenarioArguments') 'Bootstrap should wait for the scenario shell without waiting on persistent runtime descendants'
Assert-True ($bootstrap -match 'if \(\$Scenario\)\s*\{\s*\$proc\.WaitForExit\(\)') 'Only scenario elevation should wait for the launcher rather than its process tree'
Assert-True ($bootstrap -match '-AiBackend.*-AiRuntime') 'Bootstrap elevation should forward scenario selection'
Assert-True ($bootstrap -match '-PlanOnly:\$PlanOnly') 'Bootstrap elevation should forward non-mutating plan mode'
Assert-True ($bootstrap -match "AI backend/runtime/report options require -Scenario") 'Bootstrap should reject scenario-only options without the dispatcher'
Assert-True ($bootstrap -match "'CalmOS-Development'") 'Unsigned scenario testing should not contaminate the production CalmOS payload'
Assert-True ($bootstrap -match 'ElevationErrorPath') 'Bootstrap should return exact verified-elevation failures to the caller'

$parseErrors = $null
$bootstrapAst = [Management.Automation.Language.Parser]::ParseInput($bootstrap, [ref]$null, [ref]$parseErrors)
Assert-Equal @($parseErrors).Count 0 'The merged bootstrap should parse without errors'
$elevationHelper = $bootstrapAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CalmOsElevationCommand'
}, $true)
$retryHelper = $bootstrapAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DevConfigWebRequest'
}, $true)
$childCalls = @($elevationHelper.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -like '& (Join-Path $PSHOME $shellName) @arguments*'
}, $true))
Assert-Equal $childCalls.Count 1 'All modes should share the streaming child-bootstrap invocation'
Assert-Equal $childCalls[0].Redirections.Count 0 'Child diagnostics must not become terminating native-stream errors on Windows PowerShell'
Assert-Equal $childCalls[0].Parent.PipelineElements.Count 1 'Child output must not be buffered until setup exits'

$elevationBranch = $bootstrapAst.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -match '\$principal\.IsInRole'
}, $true)
$reportNormalization = @($bootstrapAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$ReportRoot' -and
        $node.Extent.Text -match 'GetUnresolvedProviderPathFromPSPath'
}, $true))
Assert-Equal $reportNormalization.Count 1 'Bootstrap should normalize a supplied report root once'
Assert-True ($reportNormalization[0].Extent.EndOffset -lt $elevationBranch.Extent.StartOffset) 'Report root should be normalized before elevation'
& {
    $normalizeReportRoot = [scriptblock]::Create($reportNormalization[0].Extent.Text)
    foreach ($path in @('', ".\AI reports\O'Brien", "C:\AI reports\O'Brien", '\\server\share\reports')) {
        $ReportRoot = $path
        $expected = if ($path) {
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
        } else { '' }
        . $normalizeReportRoot
        Assert-Equal $ReportRoot $expected 'Report root should resolve against the caller without requiring an existing directory'
        Push-Location $env:SystemRoot
        try {
            . $normalizeReportRoot
            Assert-Equal $ReportRoot $expected 'Normalized report root should remain stable in a different child directory'
        } finally {
            Pop-Location
        }
    }
}
$elevationBody = $elevationBranch.Clauses[0].Item2.Extent.Text
$invokeElevation = [scriptblock]::Create($elevationBody.Substring(1, $elevationBody.Length - 2))
& {
    . ([scriptblock]::Create($elevationHelper.Extent.Text))
    . ([scriptblock]::Create($retryHelper.Extent.Text))
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $Method, $TimeoutSec, [switch] $UseBasicParsing)
        $script:preflightRequests += $Uri
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch] $Wait, [switch] $PassThru)
        $script:elevationProcess = [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
            Verb = $Verb
            Wait = [bool]$Wait
            WaitForExitCalled = $false
            ExitCode = $exitCode
        }
        $script:elevationProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $this.WaitForExitCalled = $true }
        $script:elevationProcess
    }
    function Remove-Item {
        [CmdletBinding()]
        param($LiteralPath, [switch] $Force)
        $script:diagnosticRemovals += $LiteralPath
    }
    $Ref = 'a' * 40
    $refName = $Ref
    $repo = 'microsoft/WindowsDeveloperConfig'
    $InstallRoot = "C:\Bootstrap tests\O'Brien"
    $shell = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    $escapedShell = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shell)
    $NoLaunch = $true
    $AiBackend = 'CPU'
    $AiRuntime = 'Ollama'
    $RequireTriton = $true
    $PlanOnly = $true
    $ReportRoot = "C:\AI reports\O'Brien"
    foreach ($case in @(
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = '' }
        @{ Action = 'Partial'; Workload = 'devconfig'; Scenario = '' }
        @{ Action = 'Uninstall'; Workload = 'devconfig'; Scenario = '' }
        @{ Action = 'Full'; Workload = 'winui'; Scenario = '' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'local-ai' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'pytorch' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'cuda' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'rocm' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'intel-ai' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'llama.cpp' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'ollama' }
        @{ Action = 'Full'; Workload = 'devconfig'; Scenario = 'foundry' }
    )) {
        $Action = $case.Action
        $Workload = $case.Workload
        $Scenario = $case.Scenario
        $AiBackend = if ($Scenario -in @('local-ai', 'pytorch')) { 'CPU' } else { 'Auto' }
        $AiRuntime = if ($Scenario -eq 'local-ai') { 'Ollama' } else { 'None' }
        $RequireTriton = $Scenario -in @('local-ai', 'pytorch')
        $workloadSuffix = if ($Workload -ne 'devconfig') { " -Workload $Workload" } else { '' }
        foreach ($AllowUnsigned in @($false, $true)) {
            $flow = if ($AllowUnsigned) { 'src/windows-dev-config' } else { 'windows-dev-config' }
            $arguments = @('-NoProfile')
            if (-not $AllowUnsigned) { $arguments += '-ExecutionPolicy', 'RemoteSigned' }
            foreach ($exitCode in @(0, 7)) {
                $script:preflightRequests = @()
                $script:diagnosticRemovals = @()
                if ($exitCode -eq 0) {
                    & $invokeElevation 6>$null
                } else {
                    $expectedError = "Elevated setup exited with code 7. No further setup was started."
                    if ($Scenario) { $expectedError += "`nThe elevated process did not return diagnostic output." }
                    Assert-ThrowsLike { & $invokeElevation 6>$null } $expectedError 'Elevation failures should retain mode-specific diagnostics'
                }
                Assert-Equal $script:elevationProcess.FilePath $shell 'Elevation should preserve shell selection'
                Assert-Equal $script:elevationProcess.Verb 'RunAs' 'Elevation should continue to request UAC'
                Assert-Equal $script:elevationProcess.Wait (-not $Scenario) 'Existing actions should wait for the full process tree'
                Assert-Equal $script:elevationProcess.WaitForExitCalled ([bool]$Scenario) 'Only AI should allow persistent descendants to outlive setup'
                Assert-Equal $script:preflightRequests.Count ([int]($Workload -eq 'winui')) 'WinUI should retain its pre-elevation workload check'
                Assert-Equal $script:diagnosticRemovals.Count ([int][bool]$Scenario) 'Only AI should use diagnostic files'
                $command = $script:elevationProcess.ArgumentList[-1]
                Assert-True ($command.StartsWith('"function Invoke-DevConfigWebRequest {')) 'Every elevated command should embed the download retry helper'
                $invocation = $command.Substring($command.LastIndexOf("} -Ref '"))
                Assert-True ($invocation.Contains(" -InstallRoot 'C:\Bootstrap tests\O''Brien'")) 'Elevation should escape quoted paths'
                Assert-Equal ($invocation.Contains(" -Action '$Action'")) (-not $Scenario) 'Only workstation launches should forward Action'
                Assert-Equal ($invocation.Contains(" -Workload 'winui'")) ($Workload -eq 'winui') 'Default workloads should remain omitted'
                Assert-Equal ($invocation.Contains(' -Scenario ')) ([bool]$Scenario) 'AI dispatch should be opt-in'
                Assert-Equal ($invocation.Contains(' -ElevationErrorPath ')) ([bool]$Scenario) 'Legacy elevated commands should not require diagnostic paths'
                Assert-Equal ($invocation.Contains(' -AllowUnsigned')) $AllowUnsigned 'Elevation should preserve source/release selection'
                Assert-True ($invocation.Contains(' -NoLaunch')) 'Elevation should preserve staging-only mode'
                if ($Scenario) {
                    Assert-True ($invocation.Contains(" -AiBackend '$AiBackend' -AiRuntime '$AiRuntime'")) 'AI backend and runtime should survive elevation'
                    Assert-Equal ($invocation.Contains(' -RequireTriton')) $RequireTriton 'Triton selection should survive elevation'
                    Assert-True ($invocation.Contains(' -PlanOnly')) 'AI planning mode should survive elevation'
                    Assert-True ($invocation.Contains(" -ReportRoot 'C:\AI reports\O''Brien'")) 'AI report paths should be escaped and forwarded'
                }
            }
        }
    }
}

Write-Host "UNIT_OK: local-ai ($script:AssertionCount assertions)"
