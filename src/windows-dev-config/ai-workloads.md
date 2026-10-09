# AI tooling workloads

Get a working local AI setup on Windows. These flows look at your hardware, install the right PyTorch build for your GPU (or CPU), and can add a local model runtime like Ollama, llama.cpp, or Foundry Local. Each one finishes by actually running something — a tensor op, a kernel, or a small model — so "done" means it works, not just that it installed.

This isn't a replacement for PyPI/Conda, and it won't install every vendor SDK. You get the stack that matches your machine and nothing else.

← Back to [Windows Dev Config](./README.md) · [All workloads](./workloads.md)

## Quick start

Open PowerShell and run one of these. Each one elevates, downloads, verifies signatures, and installs. Not sure? Start with the first one.

| Workload | What you get | Run |
| --- | --- | --- |
| Local AI | PyTorch for your hardware, plus Triton where it's supported | `irm https://aka.ms/devconfig/local-ai/setup.ps1 \| iex` |
| Local AI + Ollama | Local AI + Ollama and a small test model | `irm https://aka.ms/devconfig/local-ai/ollama/setup.ps1 \| iex` |
| Local AI + llama.cpp | Local AI + the right llama.cpp build and a small test model | `irm https://aka.ms/devconfig/local-ai/llama.cpp/setup.ps1 \| iex` |
| Local AI + Foundry Local | Local AI + Foundry Local and a small test model | `irm https://aka.ms/devconfig/local-ai/foundry/setup.ps1 \| iex` |

**Just one piece:**

| Workload | What you get | Run |
| --- | --- | --- |
| PyTorch | PyTorch for CPU, CUDA, ROCm, or Intel XPU in its own venv | `irm https://aka.ms/devconfig/pytorch/setup.ps1 \| iex` |
| NVIDIA CUDA | CUDA Toolkit + MSVC; compiles and runs a test kernel | `irm https://aka.ms/devconfig/cuda/setup.ps1 \| iex` |
| AMD ROCm / HIP | ROCm SDK for supported AMD GPUs; compiles and runs a HIP kernel | `irm https://aka.ms/devconfig/rocm/setup.ps1 \| iex` |
| Intel AI | OpenVINO, with optional oneAPI/SYCL | `irm https://aka.ms/devconfig/intel-ai/setup.ps1 \| iex` |
| llama.cpp | The right llama.cpp build for your GPU + a small test model | `irm https://aka.ms/devconfig/llama.cpp/setup.ps1 \| iex` |
| Ollama | Ollama + a small test model | `irm https://aka.ms/devconfig/ollama/setup.ps1 \| iex` |
| Foundry Local | Foundry Local + a small test model | `irm https://aka.ms/devconfig/foundry/setup.ps1 \| iex` |

GPU drivers are a prerequisite. These flows check your driver but never install or replace it.

## What gets installed

`local-ai` detects your GPU and picks a PyTorch backend: **NVIDIA CUDA → AMD ROCm → Intel XPU → CPU**. Everything Python-side lives in a contained venv.

| Entry point | Installs |
| --- | --- |
| `local-ai` | PyTorch for your GPU. On NVIDIA with Triton, also MSVC and the CUDA Toolkit. On AMD, the ROCm runtime inside the venv (not the full SDK). On Intel, the XPU build + `triton-xpu` (not full oneAPI). |
| `local-ai` + runtime | The above, plus llama.cpp, Ollama, or Foundry Local. |
| `pytorch` | Same PyTorch stack as `local-ai`, without a runtime. |
| `cuda` | CUDA Toolkit + MSVC. No PyTorch. |
| `rocm` | ROCm SDK + `hipcc`. No PyTorch. |
| `intel-ai` | OpenVINO. `-Profile SYCL` or `Full` adds oneAPI. No PyTorch. |
| `llama.cpp` | One llama.cpp build for your hardware + test model. No PyTorch. |
| `ollama` | Ollama + test model. Ollama picks its own GPU backend. |
| `foundry` | Foundry Local + test model. Foundry picks its own execution provider. |

You don't need the standalone `cuda` or `rocm` flows to use PyTorch — they're for native kernel/toolchain work.

## Hardware support

| | Windows x64 | Windows ARM64 |
| --- | --- | --- |
| NVIDIA | CUDA, PyTorch + Triton, llama.cpp | CUDA 13.4 preview, PyTorch + Triton, llama.cpp (RTX Spark) |
| AMD | ROCm/HIP, PyTorch, llama.cpp | Not available from AMD |
| Intel | OpenVINO (CPU/GPU/NPU), oneAPI/SYCL, PyTorch XPU, llama.cpp | Not available from Intel |
| Qualcomm | — | llama.cpp (Adreno OpenCL), Foundry Local |
| Anyone | PyTorch CPU, llama.cpp Vulkan/CPU, Ollama, Foundry Local | PyTorch CPU, llama.cpp CPU, Ollama, Foundry Local |

Foundry Local needs Windows 11 24H2 (build 26100) or later. It uses Windows ML and doesn't need CUDA.

**Tested so far:** Windows ARM64 on NVIDIA RTX Spark, end to end. AMD, Intel, NVIDIA x64, and Qualcomm paths are built and unit-tested, and are waiting on real hardware runs.

## Options

For anything beyond the defaults, call bootstrap directly:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Scenario local-ai
```

| Parameter | What it does |
| --- | --- |
| `-Scenario <name>` | `local-ai`, `pytorch`, `cuda`, `rocm`, `intel-ai`, `llama.cpp`, `ollama`, or `foundry` |
| `-PlanOnly` | Show what would be installed. Changes nothing. |
| `-ReportRoot <dir>` | Where to write JSON reports |
| `-AiBackend` | `Auto` (default), `CPU`, `CUDA`, `ROCm`, `XPU` — `local-ai` and `pytorch` only |
| `-RequireTriton` | Fail if Triton can't be installed — `local-ai` and `pytorch` only |
| `-AiRuntime` | `LlamaCpp`, `Ollama`, or `Foundry` — `local-ai` only |

For example, the full NVIDIA stack with Ollama:

```powershell
& ([scriptblock]::Create((irm $url))) `
  -Scenario local-ai -AiBackend Auto -RequireTriton -AiRuntime Ollama `
  -ReportRoot "$env:TEMP\devconfig-local-ai"
```

When it works you'll see `PYTORCH_READY`, `TRITON_READY`, `OLLAMA_READY`, and finally `LOCAL_AI_SCENARIO_READY`.

### From a clone

Already have the repo? Skip bootstrap and run the installers from an elevated shell:

```powershell
.\src\Workloads\local-ai\install.ps1 -Backend Auto -RequireTriton -Runtime Ollama
.\src\Workloads\pytorch\install.ps1 -Backend CUDA -RequireTriton
.\src\Workloads\llama.cpp\install.ps1 -Backend ROCm
```

These are unsigned source files. See [running unsigned](./README.md#running-it-other-ways) for the execution policy steps. The signed copies live under `.\Workloads\` (e.g. `.\Workloads\local-ai\install.ps1`).

Every installer accepts `-PlanOnly` and `-ReportPath`. Reports land in `%LOCALAPPDATA%\DevConfig\reports\<flow>-latest.json` by default. To see what hardware the scripts detect:

```powershell
.\src\tools\collect-ai-hardware.ps1
```

## Test models

The runtimes download a small Qwen model and run a quick prompt to prove inference works.

| Runtime | Model | Size | Cache |
| --- | --- | --- | --- |
| Foundry Local | `qwen3-0.6b` | ~593 MB | `foundry cache location` |
| llama.cpp | `Qwen3-0.6B-Q4_K_M.gguf` | ~397 MB | `%LOCALAPPDATA%\DevConfig\llama.cpp\models` |
| Ollama | `qwen3:0.6b` | ~522 MB | `%USERPROFILE%\.ollama\models` |

Skip the download with `-SkipModelSmoke` (or `-SkipWorkloadSmoke` for CUDA). That only checks the install, not that it actually runs.

### Coding demo

Want to see something more useful than a smoke test? After llama.cpp is set up:

```powershell
.\Workloads\llama.cpp\coding-demo.ps1
```

It downloads Qwen2.5-Coder-1.5B (~1 GB) and has it write a small Python function. You'll see `CODING_DEMO_READY` when it's done.

## Uninstalling Ollama

```powershell
.\Workloads\ollama\install.ps1 -Uninstall                # keeps your models
.\Workloads\ollama\install.ps1 -Uninstall -RemoveModels  # removes them too
```

## Known gaps

- **AMD:** no native Windows Triton. ROCm targets GPUs, not Ryzen AI NPUs.
- **Intel:** XPU and SYCL target GPUs. NPU support is through OpenVINO only.
- **Qualcomm:** no PyTorch GPU backend. llama.cpp OpenCL and Foundry Local are the accelerated paths.
- **ARM64:** AMD and Intel don't publish Windows ARM64 toolkits.
- **Foundry Local and Ollama** pick their own device. The report tells you what they actually used, including CPU fallback.

Maintainer detail — version pinning, preview promotion, and partner hardware validation — is in [`src/docs/ai-workloads.md`](../docs/ai-workloads.md).
