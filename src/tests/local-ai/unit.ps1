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
Assert-True ($readme -match 'LOCAL_AI_SCENARIO_READY') 'README should document the scenario readiness marker'
Assert-True ($readme -match 'CODING_DEMO_READY') 'README should document the optional coding-demo readiness marker'
Assert-True ($readme -match 'replacement for PyPI/Conda') 'README should state the scenario non-goal'

Write-Host "UNIT_OK: local-ai ($script:AssertionCount assertions)"
