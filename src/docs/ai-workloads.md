# AI workloads — maintainer and partner reference

> 👋 **Just want to run it?** See [AI tooling workloads](../../doc/ai-workloads.md).

This is the deep reference for the AI flows: how backends get picked, where each artifact comes from, what's still on a preview channel, and how partners validate on real hardware. See the repo-wide [Developer Guide](./development.md) for CI and the signed/source layout.

The executable source of truth for supported cells and acquisition metadata is [`ai-catalog.psd1`](../Workloads/_common/ai-catalog.psd1) (`CapabilityMatrix`). Tests resolve every implemented cell and validate its acquisition metadata, probe, report contract, and partner command. Only cells cataloged as `upstream-unavailable` may stay unimplemented.

## How the bootstrap scenario works

`-Scenario <name>` downloads the full workload tree, verifies every signed PowerShell file plus the signed hash manifest for non-PowerShell content, copies it to a protected scenario directory, re-verifies, elevates, and runs only that workload's `install.ps1`. It doesn't run the workstation setup.

`-AllowUnsigned` branch tests use `%ProgramData%\CalmOS-Development` so they can't mix with the signed `%ProgramData%\CalmOS` payload. To test a branch:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Ref '<branch-or-sha>' -Scenario local-ai -AllowUnsigned
```

Set the test user's `CurrentUser` execution policy to `Bypass` first and restore it afterward — see [running it other ways](../windows-dev-config/README.md#running-it-other-ways).

## Architecture vs. GPU vendor

CPU architecture and GPU vendor are separate axes. Windows ARM64 can have an NVIDIA GPU (RTX Spark). AMD and Intel currently publish x64 Windows toolkits only. There's no generic "ARM GPU" toolkit. Foundry Local / Windows ML is the cross-vendor layer for DirectML and dynamically acquired NVIDIA, AMD, Intel, and Qualcomm execution providers.

### Detailed support matrix

| Workload | Windows x64 | Windows ARM64 | Notes |
| --- | --- | --- | --- |
| CUDA | WinGet CUDA 13 stable; driver 580+ and CC7.5+ | NVIDIA CUDA 13.4 Developer Preview | Installs MSVC, compiles with `nvcc -arch=native`, runs a kernel. `-ToolkitOnly` allows compiler-only setup. |
| AMD ROCm / HIP | ROCm Core SDK 10.0 on supported Radeon/Ryzen AI GPUs | Not published | AMD's stable Windows x64 feed; runs a compiled HIP kernel. No native Windows Triton. |
| Intel AI | OpenVINO CPU/GPU/NPU; optional oneAPI/SYCL | Not published | OpenVINO runs a generated model on the requested device. `-Profile Full` also runs a SYCL GPU kernel. |
| Foundry Local | Supported | Supported | Windows 11 24H2+. Uses WinML, no CUDA. Downloads `qwen3-0.6b` and runs a completion. |
| PyTorch CPU | Official CPU wheel | Official CPU wheel | Tensor op + minimal model forward pass. |
| PyTorch CUDA | Official CUDA wheel picked by driver/capability | Pinned NVIDIA CUDA 13.4 interim wheel (RTX Spark) | Standalone `cuda` not needed for tensors; Triton JIT pulls its toolchain automatically. |
| PyTorch ROCm | AMD Windows x64 feed, exact `device-<gfx>` tuple | Not published | Runtime lives in the venv; no standalone `rocm` SDK needed. |
| PyTorch XPU | Official XPU index: `torch`, `torchvision`, `triton-xpu` | Not published | Runtime lives in the venv; no full oneAPI. |
| Triton Windows CUDA | Community `triton-windows` | CUDA 13.4 preview stack | Runs a vector-add kernel. |
| Triton XPU | Official `triton-xpu` | Not published | Runs a cold `torch.compile` on the Intel GPU. |
| llama.cpp CUDA | Official rolling CUDA 13.3 / 12.4 + paired cudart | Qualified CUDA 13.4 preview + cudart | Auto picks the newest compatible CUDA runtime and proves GPU offload. ARM64 needs CC 12.x. |
| llama.cpp ROCm | Official rolling ROCm 10.0 | Not published | Needs a GPU in AMD's Windows ROCm matrix. |
| llama.cpp SYCL / OpenVINO | Official rolling SYCL + OpenVINO 2026.3.1 | Not published | Auto prefers SYCL on Intel GPUs. OpenVINO is explicit-only; no NPU claim. |
| llama.cpp OpenCL Adreno | — | Qualified `b10917` | Needs a Qualcomm/Adreno GPU and OpenCL loader. Newer releases need requalification. |
| llama.cpp Vulkan | Official rolling Vulkan | — | Auto fallback when no vendor-native backend is available. |
| llama.cpp CPU | Official rolling CPU | Official rolling CPU | Benchmark must show no GPU layers. |
| Ollama | WinGet `Ollama.Ollama` | WinGet `Ollama.Ollama` | Verifies architecture, native exe, package registration, model digest, inference, and actual CPU/GPU allocation. |

### Vendor setup layers

| Vendor | Native developer flow | PyTorch flow |
| --- | --- | --- |
| NVIDIA | `cuda` installs the toolkit and proves a native kernel. | `pytorch -Backend CUDA` uses its own wheel runtime. Triton's toolchain is acquired automatically. |
| AMD | `rocm` installs the ROCm SDK/HIP compiler and proves a HIP kernel. | `pytorch -Backend ROCm` installs AMD's device-specific runtime tuple in the venv. |
| Intel | `intel-ai -Profile OpenVINO` for inference; `SYCL`/`Full` add oneAPI. | `pytorch -Backend XPU` installs the XPU wheels + `triton-xpu`; no full oneAPI. |

## Backend selection

**PyTorch `-Backend Auto`:** supported NVIDIA CUDA → supported AMD ROCm → supported Intel XPU → CPU. Explicit `ROCm` or `XPU` can target a secondary adapter on mixed-GPU machines.

**llama.cpp `-Backend Auto`:** supported NVIDIA CUDA → supported AMD ROCm → supported Intel SYCL → Qualcomm Adreno OpenCL → x64 Vulkan → CPU. `OpenVINO` is available explicitly on x64.

The llama.cpp resolver takes every archive for a selection from one `bNNNNN` release, requires GitHub's SHA-256 digest for each asset, caches verified archives under `%LOCALAPPDATA%\DevConfig\llama.cpp\asset-cache`, and atomically replaces the runtime. `llama-bench -o json` must identify the selected backend/device, and diagnostics must show a nonzero `offloaded X/Y layers` for every accelerator path — a requested `-ngl` isn't proof. Physical hardware comes from `gpu_info`; `devices` is only the requested selector and must agree with `-Device`.

**Same-vendor targeting:** PyTorch `-DeviceIndex`, llama.cpp `-Device`, OpenVINO `-OpenVinoDeviceId`, and SYCL `-SyclDeviceSelector`. Foundry and Ollama manage their own devices; their reports record what was actually used.

Drivers are preconditions recorded in the report. These flows never update drivers; unsupported versions fail with remediation.

## Caching and reruns

- ARM64 PyTorch caches the verified wheel under `%LOCALAPPDATA%\DevConfig\pytorch\wheel-cache`. A matching rerun validates the recorded plan and installed torch/NumPy/Triton versions, skips downloads, and still reruns the tensor and Triton checks.
- The llama.cpp coding model (Qwen2.5-Coder-1.5B-Instruct Q4_K_M, 1,117,320,768 bytes, Apache-2.0) is opt-in. Its revision, size, and SHA-256 are verified before use.
- Ollama: before changing anything, setup confirms WinGet has an applicable installer for the architecture and records the `OllamaSetup.exe` URL and SHA-256. ARM64 machines with the old Dev Config-managed archive are migrated once (processes, startup, PATH, and metadata removed; models kept).

## ARM64 NVIDIA previews

On ARM64, CUDA downloads NVIDIA's checksum- and Authenticode-verified 13.4 Developer Preview installer (~3.8 GB) under the NVIDIA CUDA EULA. The RTX Spark PyTorch CUDA wheel is also a pinned developer preview (~1.85 GB). Both are labeled as previews, and an ARM64 NVIDIA machine is never reported GPU-ready after a CPU fallback.

## Validation status

Windows ARM64 on NVIDIA RTX Spark is validated end to end for CUDA, PyTorch CUDA, Triton, Foundry Local, llama.cpp, and Ollama. The Ollama run migrated to WinGet `Ollama.Ollama` 0.40.0, verified native ARM64 `ollama.exe`, package registration, installer SHA-256 `135bf4d927b1de03e884cd2fe66729bdf4d6a2983c5a453b99eb403489e460e1`, the `qwen3:0.6b` digest, real inference, and `/api/ps` at 100% GPU. A rerun reported `already-current`, and model-preserving uninstall/reinstall passed. The coding demo generated `group_anagrams` through llama.cpp CUDA.

AMD ROCm/HIP, Intel OpenVINO/oneAPI/XPU, NVIDIA x64 llama.cpp CUDA, and Qualcomm ARM64 llama.cpp OpenCL are hardware-gated and ready for partner runs. The gap is physical hardware coverage, not planning, asset discovery, or unit tests.

### Known vendor boundaries

| Vendor | GPU | NPU | Arch | Status | Boundaries |
| --- | --- | --- | --- | --- | --- |
| NVIDIA | `cuda`, PyTorch CUDA/Triton, llama.cpp CUDA | None here; Foundry/WinML is separate | x64 pending; ARM64 validated | ARM64 CUDA/PyTorch are previews | Foundry on the tested ARM64 NVIDIA device used `CPUExecutionProvider`. |
| AMD | ROCm/HIP, PyTorch ROCm, llama.cpp ROCm | Not implemented (ROCm isn't the Ryzen AI NPU) | x64 | Hardware pending | No native Windows Triton. Foundry AMD EP and Ollama AMD acceleration unvalidated. |
| Intel | OpenVINO GPU, oneAPI/SYCL, PyTorch XPU, llama.cpp SYCL/OpenVINO | OpenVINO NPU only when it actually executes | x64 | Hardware pending | XPU/SYCL target GPUs, not NPUs. |
| Qualcomm | llama.cpp OpenCL; Foundry/WinML | Only via a validated runtime like WinML/Foundry | ARM64 | Hardware pending | No native PyTorch accelerator. Ollama ARM64 is reported as CPU/NVIDIA unless Adreno evidence appears. |
| Fallback | Vulkan x64; CPU x64/ARM64 | None | Both | Fallback | Never labeled vendor-native. Mali and others aren't implemented. |

## Preview and rolling acquisition

All acquisition metadata lives in [`ai-catalog.psd1`](../Workloads/_common/ai-catalog.psd1). Moving from a preview/rolling artifact to a stable channel is a data change once the detection rule and real-hardware acceptance pass.

| Component | Current | Maturity | Stable candidate | Promote when |
| --- | --- | --- | --- | --- |
| CUDA x64 | WinGet `Nvidia.CUDA` | Stable | — | Current |
| CUDA ARM64 | Pinned NVIDIA 13.4.0 prerelease (SHA-256 + Authenticode) | Interim preview | Official 13.4.1, SHA-256 `39af79e5…2442` | 13.4.1 passes `nvcc` kernel + Triton JIT on RTX Spark |
| PyTorch CUDA x64 | Official `cu126`/`cu130` index | Stable | — | New tuple passes tensor + Triton |
| PyTorch CUDA ARM64 | Pinned NVIDIA `2.15.0.dev...+cu134` wheel | Interim nightly | NVIDIA `nvtorch_oot` 2.14.0 trio | Trio imports, CUDA tensor, rerun, Triton vector-add on RTX Spark |
| PyTorch ROCm x64 | AMD feed `torch[device-<gfx>]==2.13.0+rocm10.0.0` | Stable | — | New tuple lists GPU and passes tensor test |
| PyTorch XPU x64 | Official `torch==2.14.0+xpu` | Stable | — | New tuple passes tensor + `torch.compile` |
| Triton Windows CUDA | PyPI `triton-windows==3.8.0.post28` | Community-stable | No upstream Windows package | Official package appears and passes |
| Triton XPU | `triton-xpu==3.8.0` | Stable | — | Current |
| Foundry Local | WinGet `Microsoft.FoundryLocal` 0.10.3 | Qualified preview | Official v2.0.1 (SDK still alpha) | x64 + ARM64 install/migration, EP, inference, cached rerun |
| llama.cpp (all backends) | Official rolling `bNNNNN` assets; Adreno pinned to `b10917` | Rolling | WinGet `ggml.llamacpp` only maps to x64 Vulkan | Backend-specific package variants appear and pass benchmark/inference |
| Ollama x64 / ARM64 | WinGet `Ollama.Ollama` (0.40.0+ on ARM64) | Stable | — | Current |
| ROCm/HIP x64 | AMD stable feed, exact gfx tuple | Stable | — | Current |
| Intel OpenVINO / oneAPI x64 | PyPI OpenVINO / WinGet oneAPI | Stable | — | Current |

## Partner validation

Check out the exact commit you're validating, then open **elevated PowerShell** at the repo root. PR/source runs use unsigned files under `src\`, so set the test user's `CurrentUser` execution policy to `Bypass` first and restore it afterward. Signed copies under top-level `Workloads\` are also tested for `AllSigned` compatibility by `src\tests\ai-common\all-signed.ps1`; a first run may prompt to trust the Microsoft publisher.

Quick llama.cpp plan checks:

```powershell
$ReportRoot = Join-Path $env:TEMP "devconfig-ai-$env:COMPUTERNAME"
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null

.\src\Workloads\llama.cpp\install.ps1 -Backend CUDA -PlanOnly -ReportPath "$ReportRoot\llama-cuda-plan.json"
.\src\Workloads\llama.cpp\install.ps1 -Backend ROCm -PlanOnly -ReportPath "$ReportRoot\llama-rocm-plan.json"
.\src\Workloads\llama.cpp\install.ps1 -Backend SYCL -PlanOnly -ReportPath "$ReportRoot\llama-sycl-plan.json"
.\src\Workloads\llama.cpp\install.ps1 -Backend OpenCL -PlanOnly -ReportPath "$ReportRoot\llama-adreno-plan.json"
```

For full runs, use this harness. It inventories hardware, runs a plan, stops on blockers, applies, and requires `result.ready=true`:

```powershell
$ErrorActionPreference = 'Stop'
$ReportRoot = Join-Path $env:TEMP "devconfig-ai-$env:COMPUTERNAME"
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null

.\src\tools\collect-ai-hardware.ps1 `
  -OutputPath "$ReportRoot\hardware.json" *>&1 |
  Tee-Object "$ReportRoot\hardware.console.log"

function Invoke-PartnerFlow {
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Script,
    [hashtable] $Parameters = @{}
  )
  $planPath = Join-Path $ReportRoot "$Name-plan.json"
  $finalPath = Join-Path $ReportRoot "$Name-report.json"
  $planParameters = @{} + $Parameters
  $planParameters.PlanOnly = $true
  $planParameters.ReportPath = $planPath
  & $Script @planParameters *>&1 |
    Tee-Object (Join-Path $ReportRoot "$Name-plan.console.log")
  $plan = Get-Content $planPath -Raw | ConvertFrom-Json
  if ($plan.result.blockers.Count) {
    throw "$Name blocked: $($plan.result.blockers -join '; ')"
  }
  $finalParameters = @{} + $Parameters
  $finalParameters.ReportPath = $finalPath
  & $Script @finalParameters *>&1 |
    Tee-Object (Join-Path $ReportRoot "$Name-report.console.log")
  $final = Get-Content $finalPath -Raw | ConvertFrom-Json
  if (-not $final.result.ready) {
    throw "$Name did not produce result.ready=true."
  }
}
```

Run your assigned device group:

```powershell
# NVIDIA Windows x64
Invoke-PartnerFlow nvidia-cuda .\src\Workloads\cuda\install.ps1
Invoke-PartnerFlow nvidia-pytorch .\src\Workloads\pytorch\install.ps1 `
  @{ Backend = 'CUDA'; RequireTriton = $true }
Invoke-PartnerFlow nvidia-llama .\src\Workloads\llama.cpp\install.ps1 `
  @{ Backend = 'CUDA' }

# AMD Windows x64
Invoke-PartnerFlow pytorch-rocm .\src\Workloads\pytorch\install.ps1 `
  @{ Backend = 'ROCm' }
Invoke-PartnerFlow amd-hip .\src\Workloads\rocm\install.ps1
Invoke-PartnerFlow amd-llama .\src\Workloads\llama.cpp\install.ps1 `
  @{ Backend = 'ROCm' }

# Intel Windows x64 GPU
Invoke-PartnerFlow pytorch-xpu .\src\Workloads\pytorch\install.ps1 `
  @{ Backend = 'XPU'; RequireTriton = $true }
Invoke-PartnerFlow intel-openvino-gpu .\src\Workloads\intel-ai\install.ps1 `
  @{ Device = 'GPU'; Profile = 'OpenVINO' }
Invoke-PartnerFlow intel-full-gpu .\src\Workloads\intel-ai\install.ps1 `
  @{ Device = 'GPU'; Profile = 'Full' }
Invoke-PartnerFlow intel-llama-sycl .\src\Workloads\llama.cpp\install.ps1 `
  @{ Backend = 'SYCL' }
Invoke-PartnerFlow intel-llama-openvino .\src\Workloads\llama.cpp\install.ps1 `
  @{ Backend = 'OpenVINO' }

# Intel Windows x64 NPU (separate from XPU/SYCL GPU paths)
Invoke-PartnerFlow intel-openvino-npu .\src\Workloads\intel-ai\install.ps1 `
  @{ Device = 'NPU'; Profile = 'OpenVINO' }

# Qualcomm/Adreno Windows ARM64
Invoke-PartnerFlow qualcomm-llama .\src\Workloads\llama.cpp\install.ps1 `
  @{ Backend = 'OpenCL' }
Invoke-PartnerFlow qualcomm-foundry .\src\Workloads\foundry\install.ps1
```

For example, the AMD and Intel PyTorch runs write `$ReportRoot\pytorch-rocm-report.json` and `$ReportRoot\pytorch-xpu-report.json`. Run each flow twice to check idempotence.

Send back the whole `$ReportRoot` folder and say whether any installer asked for or did a reboot. `INSTALL_OK` alone isn't a pass — the final JSON needs `result.ready=true`, no blockers, and evidence for the intended backend/device. Foundry's Qualcomm run passes with any truthfully reported provider, including CPU fallback.

| Evidence | What to check |
| --- | --- |
| Host | `host.architecture`, GPU vendor/model/driver in `host.gpus`, relevant `host.npus` |
| Acquisition | Each `acquisitions[]` entry: source, version, integrity, install path |
| Selection | Requested vs. selected backend/device/profile; explicit selector if used |
| CUDA / HIP | Compiler/runtime version, device, compute capability or gfx target, kernel marker |
| PyTorch / Triton | Package tuple, `torch.version.cuda`/`hip`, device, tensor marker, Triton or `torch.compile` evidence |
| Intel AI | OpenVINO requested/actual device and provider; SYCL GPU and kernel marker |
| llama.cpp | Release tag/assets/digests, `backends`, `gpu_info`, actual `offloaded X/Y layers`, model hash, inference marker |
| Foundry | Device/EP, inference marker, `fallbackUsed` |
| Ollama | Model digest, inference marker, backend/process evidence, VRAM and `gpuFraction` when accelerated |
| Outcome | `result.ready=true`, all `warnings` and `blockers`, plan and final console logs |
