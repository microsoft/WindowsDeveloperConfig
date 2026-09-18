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

$readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\README.md') -Raw
Assert-True ($readme -match 'Workloads\\local-ai\\install\.ps1') 'README should lead with the local AI scenario entry point'
Assert-True ($readme -match 'bootstrap\.ps1''\s*\r?\n& \(\[scriptblock\]::Create\(\(irm \$url\)\)\) -Scenario local-ai') 'README should document the production product-level dispatcher'
Assert-True ($readme -match '(?s)gh pr view 104.*?headRefOid') 'README should resolve the live PR head for unsigned dispatcher testing'
Assert-True ($readme -match 'LOCAL_AI_SCENARIO_READY') 'README should document the scenario readiness marker'
Assert-True ($readme -match 'CODING_DEMO_READY') 'README should document the optional coding-demo readiness marker'
Assert-True ($readme -match 'replacement for PyPI/Conda') 'README should state the scenario non-goal'
foreach ($entryPoint in @('local-ai', 'pytorch', 'cuda', 'rocm', 'intel-ai', 'llama.cpp', 'ollama', 'foundry')) {
    Assert-True ($readme -match [regex]::Escape("| ``$entryPoint")) "README transitive-acquisition table should include $entryPoint"
}

$pytorch = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\pytorch\install.ps1') -Raw
Assert-True ($pytorch -match '\$plan\.InstallTriton.*CUDA.*XPU') 'PyTorch should gate native toolchains on supported Triton backends'
Assert-True ($pytorch -match 'Ensure-AiVisualCppTools') 'PyTorch Triton should ensure the native MSVC toolchain'
Assert-True ($pytorch -match 'Ensure-AiCudaToolkit') 'PyTorch CUDA Triton should ensure the standalone CUDA toolkit'
Assert-True ($pytorch -match 'Add-AiReportAcquisition') 'PyTorch should report its transitive acquisitions'

$llama = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\llama.cpp\install.ps1') -Raw
Assert-True ($llama -notmatch 'Ensure-AiCudaToolkit') 'llama.cpp CUDA assets should not independently install the full CUDA toolkit'
Assert-True ($llama -match 'resolvedAssets') 'llama.cpp should report paired/runtime asset acquisition'

$ollama = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\ollama\install.ps1') -Raw
Assert-True ($ollama -match 'gpuFraction') 'Ollama should report its source-managed allocation'
$foundry = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Workloads\foundry\install.ps1') -Raw
Assert-True ($foundry -match 'selectedExecutionProvider') 'Foundry should report its source-managed EP'

$bootstrap = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\windows-dev-config\bootstrap.ps1') -Raw
Assert-True ($bootstrap -match "ValidateSet\('', 'local-ai'\)") 'Bootstrap should expose only the supported local-ai dispatcher'
Assert-True ($bootstrap -match 'Workloads\\local-ai\\install\.ps1') 'Bootstrap should route to the scenario without running dev-config.ps1'
Assert-True ($bootstrap -match 'Assert-DevConfigMicrosoftSigned -Directory \$workloadsDir') 'Signed scenario payload should be Microsoft-signature verified'
Assert-True ($bootstrap -match 'Assert-DevConfigWorkloadContent -WorkloadsRoot \$workloadsDir') 'Signed scenario should verify non-PowerShell content before copy'
Assert-True ($bootstrap -match 'Assert-DevConfigWorkloadContent -WorkloadsRoot \(Join-Path \$InstallRoot ''Workloads''\)') 'Installed scenario content should be reverified after protected copy'
Assert-True ($bootstrap -match 'Assert-DevConfigProtectedTree -Directory \$workloadsDir') 'Scenario payload should be protected before copy'
Assert-True ($bootstrap -match 'Copy-Item -LiteralPath \$workloadsDir') 'Bootstrap should copy the complete multi-file Workloads dependency tree'
Assert-True ($bootstrap -match 'Join-Path \$setupDir ''steps''') 'Bootstrap should copy the shared Windows Dev Config helper steps'
Assert-True ($bootstrap -match '-AiBackend.*-AiRuntime') 'Bootstrap elevation should forward scenario selection'
Assert-True ($bootstrap -match '-PlanOnly:\$PlanOnly') 'Bootstrap elevation should forward non-mutating plan mode'
Assert-True ($bootstrap -match "AI backend/runtime/report options require -Scenario local-ai") 'Bootstrap should reject scenario-only options without the dispatcher'

Write-Host "UNIT_OK: local-ai ($script:AssertionCount assertions)"
