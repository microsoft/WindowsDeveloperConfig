<p align="center">
  <img src="./doc/images/devconfigs.svg" alt="Windows Developer Config logo" width="96" />
</p>

<h1 align="center">Windows Developer Config</h1>

<p align="center">
  Opinionated setups for Windows dev boxes. Idempotent. CI-tested.
</p>

<h3 align="center">
  <a href="#%EF%B8%8F-windows-dev-config">Windows Dev Config</a>
  <span> · </span>
  <a href="#-wsl-comfort">WSL Comfort</a>
  <span> · </span>
  <a href="#-focused-workloads">Workloads</a>
  <span> · </span>
  <a href="#-troubleshooting">Troubleshooting</a>
</h3>

---

Go from a fresh Windows install to a fully configured dev box in one command. These CI-tested setups install your tools, settings, and shells the same way every time — so any machine can be your machine in minutes.

## 🎯 Pick your setup

Three developer setups live in this repo. Pick the one that matches what you want:

| You want... | Go to |
| --- | --- |
| A complete dev workstation: tools, OS settings, WSL, and terminal. One command, restarts once. | [Windows Dev Config](#%EF%B8%8F-windows-dev-config) |
| A polished WSL shell: zsh/bash, Starship, CLI tools, and a themed terminal profile. Interactive or unattended. | [WSL Comfort](#-wsl-comfort) |
| A focused language or Windows AI toolchain. One command each. | [Workloads](#-focused-workloads) |

Most of the single-language workloads use [`winget configure`](https://learn.microsoft.com/en-us/windows/package-manager/winget/configure). If you've never used it before, enable it once:

```powershell
winget configure --enable
```

> [!IMPORTANT]
> If `winget` is being invoked from a **non-elevated** environment, the Microsoft Visual C++ Redistributable ([aka.ms/vcredist](https://aka.ms/vcredist)) must also be installed — without it `winget configure` fails with an internal error. Install it once with the command for your machine's architecture:
>
> ```powershell
> # x64:
> winget install Microsoft.VCRedist.2015+.x64
>
> # ARM64:
> winget install Microsoft.VCRedist.2015+.arm64
> ```

If that fails or `winget configure` is still not recognized, see [Troubleshooting](#-troubleshooting). Windows Dev Config doesn't use `winget configure` and needs none of this.

<br/>

## 🖥️ Windows Dev Config

*Turns a fresh Windows 11 box into a clean, distraction-free dev workstation in one shot.*

A set of PowerShell scripts that installs dev tools, applies opinionated Windows settings, and sets up WSL + Ubuntu through the required reboot. Nothing to clone, nothing to install first. Idempotent, so it's safe to re-run on an existing machine.

Open any PowerShell window — elevated or not — and run:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -AllowUnsigned
```

You'll get one UAC prompt. Expect about 30 minutes on a clean machine.

> `-AllowUnsigned` runs the source copy under `src/` instead of the signed copy at the repository root.

> ⚠️ **It will restart your machine, once.** Enabling WSL needs a Windows optional feature that requires a restart. You get a 10-second warning, and a scheduled task finishes the run automatically after you sign back in. **Save your work before you start.**

<details>
<summary><strong>What you get</strong></summary>

- **Dev tools:** Windows Terminal, PowerShell 7, Git, GitHub CLI, GitHub Copilot CLI, VS Code, .NET SDK 10, Python 3.14 + uv, Node.js LTS + nvm, Coreutils for Windows, Windows App CLI, Oh My Posh, and PowerToys.
- **Terminal:** PowerShell 7 as the default profile, Oh My Posh in your prompt, Cascadia Mono NF as the default font, and a GitHub Copilot profile in the dropdown.
- **Windows settings:** Dark theme, Developer Mode, Sudo, long paths, File Explorer defaults, Start/Search cleanup, Do Not Disturb, widgets off, and Edge policies.
- **WSL:** WSL platform + Ubuntu, including the restart and the automatic resume afterwards.

</details>

Full details — every setting it changes, how to undo them, and troubleshooting: [`windows-dev-config/README.md`](./src/windows-dev-config/README.md).

<br/>

## 🐧 WSL Comfort

*Also known as Comfort Shell. An interactive setup for a polished Windows + WSL shell environment.*

WSL Comfort stands apart. It supports both interactive and non-interactive modes, and lets you pick and choose individual components. The Windows side handles WSL, the distro, the Cascadia Code Nerd Font, and a themed Windows Terminal profile. The Linux side runs inside the distro and configures the shell itself.

```powershell
.\wsl-comfort\install.ps1
```

Interactive by default. Use `-NonInteractive` for unattended runs; the bootstrap also takes `--minimal` for a smaller setup. The Linux half is standalone, so you can copy `comfort-shell-bootstrap.sh` onto any Ubuntu host and run it directly.

<details>
<summary><strong>What you can pick</strong></summary>

- Your choice of shell: **zsh** or **bash**.
- Optional **Starship** prompt.
- Optional modern CLI tools: `fzf`, `rg`, `fd`, `bat`, `eza`, `zoxide`, `jq`.
- Optional clipboard and `open` shims (`pbcopy`, `pbpaste`, `open`).
- Optional **Homebrew**.
- Optional Git defaults.
- A themed **Windows Terminal** profile using Cascadia Code Nerd Font.

</details>

Full details: [`wsl-comfort/readme.md`](./wsl-comfort/readme.md).

<br/>

## 🧪 Focused workloads

Just want one toolchain? Pick a row. Language workloads generally use
`configuration.winget`; AI workloads use resumable PowerShell entry points that
directly check, install or upgrade, refresh PATH, verify a real workload, and
write a machine-readable report.

| Workload   | Installs                                                                | Run                                                                                                                            |
| ---------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| TypeScript | Node.js LTS + global `typescript`                                       | `winget configure -f .\Workloads\typescript\configuration.winget --accept-configuration-agreements --disable-interactivity` |
| PHP        | PHP 8.5                                                                 | `winget configure -f .\Workloads\php\configuration.winget --accept-configuration-agreements --disable-interactivity`        |
| .NET       | .NET SDK 10                                                             | `winget configure -f .\Workloads\dotnet\configuration.winget --accept-configuration-agreements --disable-interactivity`     |
| Go         | Go (rolling)                                                            | `winget configure -f .\Workloads\go\configuration.winget --accept-configuration-agreements --disable-interactivity`         |
| Java       | Microsoft Build of OpenJDK 25 LTS                                       | `winget configure -f .\Workloads\java\configuration.winget --accept-configuration-agreements --disable-interactivity`       |
| Rust       | Rust stable via rustup                                                  | `winget configure -f .\Workloads\rust\configuration.winget --accept-configuration-agreements --disable-interactivity`       |
| Python     | Python 3.14 + uv                                                       | `winget configure -f .\Workloads\python\configuration.winget --accept-configuration-agreements --disable-interactivity`     |
| SQL        | Lightweight SQL Developer: SQL Server + sqlcmd + VS Code extension     | `winget configure -f .\Workloads\sql\configuration.winget --accept-configuration-agreements --disable-interactivity`        |
| PowerShell | PowerShell 7 + VS Code PowerShell extensions + PSScriptAnalyzer settings | `winget configure -f .\Workloads\powershell\configuration.winget --accept-configuration-agreements --disable-interactivity` |
| WinForms   | .NET SDK 10 + Windows Forms desktop workload                            | `winget configure -f .\Workloads\winforms\configuration.winget --accept-configuration-agreements --disable-interactivity`   |
| WinUI 3    | .NET SDK 10 + Visual Studio Community + Windows App SDK / WinUI 3 + WinAppCLI | `winget configure -f .\Workloads\winui\configuration.winget --accept-configuration-agreements --disable-interactivity` |
| NVIDIA CUDA | CUDA Toolkit + MSVC; compiles and executes a minimal GPU kernel | `.\Workloads\cuda\install.ps1` |
| AMD ROCm / HIP | ROCm Core SDK 10.0 for supported AMD GPUs; compiles and executes a HIP kernel | `.\Workloads\rocm\install.ps1` |
| Intel AI | OpenVINO device inference; optional oneAPI/SYCL GPU toolkit and kernel | `.\Workloads\intel-ai\install.ps1` |
| Foundry Local | Architecture-native WinML package + Qwen3-0.6B model inference | `.\Workloads\foundry\install.ps1` |
| PyTorch | CPython 3.13 + contained CPU/CUDA/ROCm/XPU environment; vendor-appropriate Triton where supported | `.\Workloads\pytorch\install.ps1` |
| llama.cpp | Hardware-selected official rolling CUDA/ROCm/SYCL/OpenVINO/Vulkan/OpenCL/CPU runtime + pinned GGUF inference | `.\Workloads\llama.cpp\install.ps1` |
| Ollama | WinGet x64 or verified current ARM64 release + official qwen3:0.6b inference | `.\Workloads\ollama\install.ps1` |

Want the PATH refresh in your current shell? Use the matching shim instead of calling `winget configure` directly:

```powershell
.\Workloads\python\install.ps1
```

> **Heads up:** WinForms and WinUI 3 pull down several gigabytes of Visual Studio components. Fine on a real workstation, painful on a small VM.

### Windows AI workload support

The AI flows are independent and install only the selected hardware stack.
CPU architecture and GPU vendor are separate axes: Windows ARM64 can have an
NVIDIA GPU (RTX Spark), while AMD and Intel native Windows toolkits currently
publish x64 artifacts only. There is no generic "ARM GPU" toolkit. Foundry
Local/Windows ML is the cross-vendor layer for DirectML and dynamically acquired
NVIDIA, AMD, Intel, and Qualcomm execution providers.

| Workload | Windows x64 | Windows ARM64 | Prerequisites and selected path |
| --- | --- | --- | --- |
| CUDA | WinGet CUDA 13 stable; GPU readiness requires driver 580+ and CC7.5+ | NVIDIA CUDA 13.4 Developer Preview | NVIDIA GPU + qualified driver by default. Installs MSVC, compiles with `nvcc -arch=native`, and executes a kernel. `-ToolkitOnly` permits compiler-only setup. |
| AMD ROCm / HIP | ROCm Core SDK 10.0 on supported Radeon/Ryzen AI GPUs | Not published | Uses AMD's stable Windows x64 feed and executes a compiled HIP kernel. Native Windows Triton is unsupported. |
| Intel AI | OpenVINO CPU/GPU/NPU; optional oneAPI/SYCL | Not published | OpenVINO performs generated-model inference on the requested device. `-Profile Full` also executes a SYCL GPU kernel. |
| Foundry Local | Supported | Supported | Windows 11 24H2/build 26100+. Uses WinML and does **not** require CUDA. Downloads `qwen3-0.6b` and runs a marker completion. |
| PyTorch CPU | Stable official CPU wheel | Stable official CPU wheel | Contained CPU runtime and tensor acceptance. |
| PyTorch CUDA | Stable official CUDA wheel chosen from driver/device capability | Pinned NVIDIA CUDA 13.4 Developer Preview wheel on RTX Spark | Self-contained wheel runtime; standalone `cuda` is not required for ordinary tensor use. Triton JIT acquires its compiler/toolchain automatically. |
| PyTorch ROCm | AMD stable Windows x64 feed with exact `device-<gfx>` runtime tuple | Unsupported/unpublished | Self-contained AMD runtime tuple inside the PyTorch venv; does not require the standalone `rocm` SDK flow. |
| PyTorch XPU | Official PyTorch XPU index with `torch`, `torchvision`, and `triton-xpu` | Unsupported/unpublished | Self-contained Intel XPU runtime tuple; does not install full oneAPI. |
| Triton Windows CUDA | Community `triton-windows` on qualified NVIDIA CUDA stacks | NVIDIA CUDA 13.4 preview stack | Executes a real vector-add GPU kernel. |
| Triton XPU / `torch.compile` | Official `triton-xpu` through the PyTorch XPU index | Unsupported/unpublished | Executes a cold `torch.compile` workload on the Intel GPU. |
| llama.cpp CUDA x64 | Official rolling CUDA 13.3 or 12.4 app + paired cudart assets | Unsupported | Auto selects the newest compatible CUDA runtime from driver and compute capability, then proves NVIDIA device offload and GPU layers. |
| llama.cpp CUDA ARM64 | Unsupported | Qualified CUDA 13.4 Developer Preview app + paired cudart assets | Retains the N1X path and requires RTX Spark-class hardware, driver 616+, backend/device evidence, GPU layers, and real inference. |
| llama.cpp ROCm x64 | Official rolling ROCm 10.0 asset | Unsupported | Requires an AMD GPU in the Windows ROCm matrix and proves ROCm/AMD offload. |
| llama.cpp SYCL / OpenVINO x64 | Official rolling SYCL and OpenVINO 2026.3.1 assets | Unsupported | Auto prefers SYCL for a supported Intel GPU because it directly proves Intel GPU execution. OpenVINO is explicit/general x64 inference; no NPU claim is made. |
| llama.cpp OpenCL Adreno ARM64 | Unsupported | Official rolling Qualcomm Adreno OpenCL asset | Requires a detected Qualcomm/Adreno GPU plus the Windows OpenCL loader and proves OpenCL/Adreno offload. |
| llama.cpp Vulkan x64 fallback | Official rolling Vulkan asset | Unsupported | Used by Auto only after no supported vendor-native backend is available and a Vulkan loader/device exists. Reports Vulkan explicitly. |
| llama.cpp CPU fallback | Official rolling CPU asset | Official rolling CPU asset | Used when no qualified accelerator exists or explicitly requested; benchmark must show no GPU layers. |
| Ollama | WinGet desktop package | Verified current official ARM64 ZIP | Starts or reuses `ollama serve`, pulls official `qwen3:0.6b`, verifies its model blob, and performs structured inference. |

Run a flow from PowerShell:

```powershell
.\Workloads\cuda\install.ps1
.\Workloads\rocm\install.ps1
.\Workloads\intel-ai\install.ps1
.\Workloads\foundry\install.ps1
.\Workloads\pytorch\install.ps1
.\Workloads\llama.cpp\install.ps1
.\Workloads\ollama\install.ps1
```

PyTorch accepts explicit backend and Triton policy switches:

```powershell
.\Workloads\pytorch\install.ps1 -Backend CPU
.\Workloads\pytorch\install.ps1 -Backend CUDA -RequireTriton
.\Workloads\pytorch\install.ps1 -Backend ROCm
.\Workloads\pytorch\install.ps1 -Backend XPU -RequireTriton
.\Workloads\llama.cpp\install.ps1 -Backend CUDA
.\Workloads\llama.cpp\install.ps1 -Backend ROCm
.\Workloads\llama.cpp\install.ps1 -Backend SYCL
.\Workloads\llama.cpp\install.ps1 -Backend OpenVINO
```

`-Backend Auto` uses the deterministic priority **supported NVIDIA CUDA →
supported AMD ROCm → supported Intel XPU → CPU**. Explicit `ROCm` or `XPU`
can select a supported secondary adapter on mixed-GPU systems.

### Vendor setup layers

| Vendor | Native developer flow | PyTorch flow |
| --- | --- | --- |
| NVIDIA | `cuda` installs the CUDA compiler/toolkit and proves a native kernel. | `pytorch -Backend CUDA` installs its own wheel runtime. Standalone CUDA is not universally required; compatible Triton JIT/toolchain dependencies are acquired automatically. |
| AMD | `rocm` installs the ROCm Core SDK/HIP compiler and proves a native HIP kernel. | `pytorch -Backend ROCm` installs the official AMD device-specific runtime package tuple inside its own venv; the separate `rocm` flow is not a prerequisite for tensor inference. |
| Intel | `intel-ai -Profile OpenVINO` is CPU/GPU/NPU inference; `-Profile SYCL` or `Full` installs full oneAPI for native SYCL development. | `pytorch -Backend XPU` installs the official XPU wheel tuple and `triton-xpu` inside its own venv; it does not install full oneAPI. |

Every AI entry point accepts `-PlanOnly` and `-ReportPath`. Plan mode performs
hardware/support resolution without installing software. Applied runs write JSON
to `%LOCALAPPDATA%\DevConfig\reports\<flow>-latest.json`; the reusable hardware
inventory command is:

```powershell
.\src\tools\collect-ai-hardware.ps1
.\src\tools\get-ai-capabilities.ps1 -OutputPath "$env:TEMP\ai-capabilities.json"
```

Default acceptance proves each workload is usable, not merely installed:
CUDA executes a compiled GPU kernel; PyTorch performs a tensor operation on the
selected backend and, when supported, Triton runs a GPU kernel; and each local
model runtime downloads a small Apache-2.0 Qwen model and performs deterministic
text inference.

llama.cpp `-Backend Auto` prefers **supported NVIDIA CUDA → supported AMD ROCm
→ supported Intel SYCL → Qualcomm Adreno OpenCL → x64 Vulkan → CPU**. Explicit
`OpenVINO` is available on x64 for its official general inference backend. The
resolver takes every archive for a selection from one `bNNNNN` release, requires
GitHub's SHA-256 digest for each asset, caches the verified archives under
`%LOCALAPPDATA%\DevConfig\llama.cpp\asset-cache`, and atomically replaces the
runtime. Qualcomm ARM64 is pinned to qualified release `b10917` because managed
Defender ransomware protection blocks the unsigned `b10919` Adreno executable.
`llama-bench -o json` must identify the selected backend/device and
diagnostics must report an actual nonzero `offloaded X/Y layers` result for
every accelerator path before the flow is ready; requested `-ngl` is not treated
as proof. Physical hardware comes from the official `gpu_info` field; `devices`
is retained only as the requested selector and must agree with explicit
`-Device`.

| Flow | Default model download | Cache |
| --- | ---: | --- |
| Foundry Local | `qwen3-0.6b`, about 593 MB | Reported by `foundry cache location` |
| llama.cpp | `Qwen3-0.6B-Q4_K_M.gguf`, 396,704,416 bytes | `%LOCALAPPDATA%\DevConfig\llama.cpp\models` |
| Ollama | `qwen3:0.6b`, about 522 MB | `%USERPROFILE%\.ollama\models` or `OLLAMA_MODELS` |

Use `-SkipModelSmoke` with Foundry Local, llama.cpp, or Ollama to opt out
of the model download and inference. Use CUDA's `-SkipWorkloadSmoke` to opt out
of kernel compilation/execution. Opted-out runs verify installation only and do
not report full workload readiness.

For physical partner validation, run the assigned llama.cpp backend from an
elevated PowerShell. Run the plan first, then the full flow twice without skip
switches; retain every report and console log.

```powershell
$ReportRoot = Join-Path $env:TEMP "devconfig-ai-$env:COMPUTERNAME"
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null

.\src\Workloads\llama.cpp\install.ps1 -Backend CUDA -PlanOnly -ReportPath "$ReportRoot\llama-cuda-plan.json"
.\src\Workloads\llama.cpp\install.ps1 -Backend ROCm -PlanOnly -ReportPath "$ReportRoot\llama-rocm-plan.json"
.\src\Workloads\llama.cpp\install.ps1 -Backend SYCL -PlanOnly -ReportPath "$ReportRoot\llama-sycl-plan.json"
.\src\Workloads\llama.cpp\install.ps1 -Backend OpenCL -PlanOnly -ReportPath "$ReportRoot\llama-adreno-plan.json"
```

Use the same command without `-PlanOnly` for the full and idempotence runs,
writing distinct `*-final.json` and `*-rerun-final.json` reports. A pass requires
`result.ready=true`, no blockers, matching `backends` and `gpu_info`, actual
offloaded layers, and the pinned model marker.

On ARM64, CUDA downloads NVIDIA's checksum- and Authenticode-verified 13.4
Developer Preview installer (about 3.8 GB) under the NVIDIA CUDA EULA. The
native RTX Spark PyTorch CUDA wheel is also a pinned developer preview (about
1.85 GB). The flows clearly label both previews and never silently claim an
ARM64 NVIDIA system is GPU-ready after falling back to CPU.

PyTorch caches that verified ARM64 wheel under
`%LOCALAPPDATA%\DevConfig\pytorch\wheel-cache`. A matching rerun validates the
recorded plan and exact installed torch, NumPy, and Triton versions, skips all
package downloads/installation, and still reruns the CUDA tensor and Triton
kernel acceptance tests.

**Hardware validation status:** Windows ARM64 on NVIDIA RTX Spark N1X is
validated end-to-end for CUDA, PyTorch CUDA, Triton, Foundry Local, llama.cpp,
and Ollama. The final Ollama rerun used a resolver-owned loopback endpoint,
runtime 0.34.0, the verified `qwen3:0.6b` digest, real inference, and `/api/ps`
reporting 100% GPU. AMD ROCm/HIP, Intel OpenVINO/oneAPI/XPU, NVIDIA x64
llama.cpp CUDA, and Qualcomm ARM64 llama.cpp OpenCL are hardware-gated and
ready for partner execution. Their current gap is physical partner hardware
coverage, not static planning, asset discovery, or unit coverage.

### Known vendor gaps and boundaries

| Vendor | GPU coverage | NPU coverage | Windows CPU architecture | Maturity / live status | Known boundaries |
| --- | --- | --- | --- | --- | --- |
| NVIDIA | `cuda`, PyTorch CUDA/Triton, llama.cpp CUDA | None in these vendor SDK flows; Foundry/WinML provider behavior is separate | x64 designed/partner pending; ARM64 N1X validated | x64 stable channels need live acceptance; ARM64 CUDA/PyTorch are developer previews | Foundry on N1X currently uses `CPUExecutionProvider`, not CUDA. Installers qualify but do not replace GPU drivers. |
| AMD | Native ROCm/HIP, PyTorch ROCm, llama.cpp ROCm on AMD's exact Windows GPU/gfx matrix | Not implemented; ROCm is GPU/HIP, not Ryzen AI NPU | x64 only | Resolver/static acceptance complete; hardware pending | Native Windows AMD Triton is unavailable. Foundry/WinML AMD EP and Ollama AMD acceleration remain unvalidated and are not claimed. |
| Intel | OpenVINO GPU, oneAPI/SYCL, PyTorch XPU/`triton-xpu`, llama.cpp SYCL/OpenVINO | OpenVINO NPU only when the requested device actually executes; no PyTorch XPU or llama SYCL NPU claim | x64 only | Resolver/static acceptance complete; hardware pending | Full oneAPI is only for native SYCL. XPU and SYCL target Intel GPUs, not NPUs. |
| Qualcomm/Adreno | llama.cpp OpenCL ARM64; Foundry/WinML is the vendor-neutral path | Only through a validated runtime/provider such as WinML/Foundry; no standalone toolkit here | ARM64 | Resolver/static acceptance complete; hardware pending | No native PyTorch accelerator backend. Ollama ARM64 is reported as CPU/NVIDIA capability unless actual Adreno evidence becomes available. |
| Other / fallback | Vulkan x64 compatibility fallback; CPU x64/ARM64 | None | x64/ARM64 as listed | Fallback paths | Vulkan/CPU are never labeled vendor-native. Mali and other stacks are unimplemented/unpublished without official Windows artifacts. |

Auto selects a vendor/backend deterministically, and explicit backends can target
a supported secondary vendor. Same-vendor targeting is available through
`cuda`/`rocm` and explicit-backend PyTorch `-DeviceIndex`, llama.cpp `-Device`, OpenVINO
`-OpenVinoDeviceId`, and SYCL `-SyclDeviceSelector`. Foundry and Ollama manage
their own device selection; those flows report the actual provider/allocation
rather than claiming control they do not expose. Reports retain the selected
device and installed driver as preconditions. These flows do not update GPU
drivers; unsupported versions fail with remediation.

The executable supported-cell source of truth is
[`CapabilityMatrix`](./src/Workloads/_common/ai-catalog.psd1). Repository tests
resolve every implemented/source-managed cell and validate its acquisition
metadata, probe, report contract, and partner command; only cataloged
`upstream-unavailable` cells may remain unimplemented.

### Preview and rolling acquisition promotion

Acquisition metadata is centralized in
[`Workloads/_common/ai-catalog.psd1`](./src/Workloads/_common/ai-catalog.psd1).
Changing from a preview/rolling artifact to a normal channel is a resolver-data
change after the stated detection rule and real hardware acceptance pass.

| Component | Vendor / architecture | Current channel and identity | Integrity | Why normal channel is insufficient | Expected stable channel | Promotion trigger |
| --- | --- | --- | --- | --- | --- | --- |
| CUDA ARM64 | NVIDIA / ARM64 | Developer Preview `cuda_13.4.0_windows_arm64.exe` | Pinned SHA-256 + NVIDIA Authenticode | `Nvidia.CUDA` has no ARM64 payload | `Nvidia.CUDA` ARM64, unconfirmed | ARM64 WinGet manifest appears and N1X kernel passes |
| PyTorch CUDA x64 | NVIDIA / x64 | Stable `torch==2.14.0+cu126` or `+cu130` from official PyTorch index | Official index hashes + wheel RECORD | None | Official PyTorch CUDA index | New tuple passes tensor and Triton kernel |
| PyTorch CUDA ARM64 | NVIDIA / ARM64 | Nightly `torch-2.15.0.dev20260904+cu134-cp313-win_arm64.whl` | Pinned SHA-256 | Stable PyTorch indexes have no Windows ARM64 CUDA wheel | Official PyTorch CUDA Windows ARM64 feed, unconfirmed | Stable wheel appears and tensor/Triton tests pass |
| PyTorch ROCm x64 | AMD / x64 | Stable `torch[device-<gfx>]==2.13.0+rocm10.0.0`, matching torchvision and torchaudio from AMD feed | AMD HTTPS feed + wheel RECORD | Default PyPI has no AMD ROCm Windows build | AMD stable ROCm feed | New exact tuple lists GPU and tensor acceptance passes |
| PyTorch XPU x64 | Intel / x64 | Stable `torch==2.14.0+xpu`, `torchvision==0.29.0+xpu` from official XPU index | Official index hashes + wheel RECORD | Default PyPI has no Intel XPU build | Official PyTorch XPU index | New tuple passes XPU tensor and `torch.compile` |
| Triton Windows CUDA | NVIDIA x64/ARM64 | Community `triton-windows==3.8.0.post28` | Package-index TLS + wheel RECORD | Upstream Triton has no general stable Windows package | Official PyTorch/Triton Windows feed, unconfirmed | Official package appears and kernel passes |
| Triton XPU / `torch.compile` | Intel / x64 | Stable `triton-xpu==3.8.0` from official PyTorch XPU index | Official index hashes + wheel RECORD | Standalone Intel Triton documents Linux; Windows support is integrated with PyTorch XPU | Official PyTorch XPU index | New tuple passes cold `torch.compile` |
| llama.cpp CUDA x64 | NVIDIA / x64 | Latest complete CUDA 13.3 or 12.4 app + cudart pair from one `bNNNNN` release | GitHub asset SHA-256 digests | WinGet maps only to Vulkan | Backend-specific `ggml.llamacpp` CUDA variant, unconfirmed | Package variant appears and NVIDIA benchmark/inference pass |
| llama.cpp CUDA ARM64 | NVIDIA / ARM64 | Latest complete CUDA 13.4 app + cudart pair; developer-preview stack | GitHub asset SHA-256 digests | WinGet has no ARM64 CUDA variant | Backend-specific `ggml.llamacpp` CUDA ARM64 variant, unconfirmed | Package variant appears and N1X benchmark/inference pass |
| llama.cpp ROCm x64 | AMD / x64 | Latest ROCm 10.0 asset from a complete `bNNNNN` release | GitHub asset SHA-256 digest | WinGet maps only to Vulkan | Backend-specific `ggml.llamacpp` ROCm variant, unconfirmed | Package variant appears and AMD benchmark/inference pass |
| llama.cpp SYCL / OpenVINO x64 | Intel/general / x64 | Latest SYCL or OpenVINO 2026.3.1 asset | GitHub asset SHA-256 digest | WinGet maps only to Vulkan | Backend-specific `ggml.llamacpp` SYCL/OpenVINO variants, unconfirmed | Package variant appears and selected-device benchmark/inference pass |
| llama.cpp OpenCL Adreno ARM64 | Qualcomm / ARM64 | Latest Adreno OpenCL asset | GitHub asset SHA-256 digest | WinGet has no ARM64 Adreno variant | Backend-specific `ggml.llamacpp` OpenCL ARM64 variant, unconfirmed | Package variant appears and Adreno benchmark/inference pass |
| llama.cpp Vulkan x64 | Cross-vendor / x64 | Latest official rolling Vulkan asset | GitHub asset SHA-256 digest | Current WinGet package cannot coexist as explicit backend variants | `ggml.llamacpp` Vulkan with reliable backend identity | Package backend/version evidence and Vulkan inference pass |
| llama.cpp CPU x64/ARM64 | CPU / x64, ARM64 | Latest official rolling CPU asset | GitHub asset SHA-256 digest | WinGet lacks ARM64 and backend-selectable CPU variants | Backend-specific `ggml.llamacpp` CPU variants, unconfirmed | Package variants appear and CPU inference passes |
| Foundry Local | Cross-vendor / x64, ARM64 | Preview `Microsoft.FoundryLocal` | WinGet MSIX hash/signature | Product is still preview | Same package ID at GA | Microsoft marks GA and inference/provider report passes |
| Ollama ARM64 | CPU/NVIDIA / ARM64 | Latest stable official `ollama-windows-arm64.zip` | GitHub asset SHA-256 | Desktop WinGet ID is x64; portable package can lag | Current ARM64 WinGet payload, package ID unconfirmed | WinGet catches current release and API/GPU evidence passes |

### Partner validation commands

Use the exact PR head that was statically qualified:

```powershell
gh pr checkout 98 --repo microsoft/WindowsDeveloperConfig
$ExpectedHead = gh pr view 98 --repo microsoft/WindowsDeveloperConfig `
  --json headRefOid --jq .headRefOid
if ((git rev-parse HEAD).Trim() -ne $ExpectedHead) {
  throw "PR #98 checkout does not match published head $ExpectedHead."
}
```

The workload implementation was qualified at `ec7fc5e`; later PR commits may
update documentation only. Always run from the live PR head selected above.

If GitHub CLI checkout is unavailable:

```powershell
git fetch https://github.com/Kixantrix/WindowsDeveloperConfig.git `
  mihippel-microsoft-windows-ai-setup-workloads:pr-98
git switch pr-98
```

Open **elevated PowerShell** in the repository root, then use this harness. It
always inventories first, runs a non-mutating plan, stops on blockers, applies
the same arguments, and requires `result.ready=true`.

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

Run the assigned device group:

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

For example, the AMD and Intel PyTorch commands above write
`$ReportRoot\pytorch-rocm-report.json` and
`$ReportRoot\pytorch-xpu-report.json`, respectively.

Foundry acceleration is source-managed: its Qualcomm run succeeds with any
truthfully reported provider, including CPU fallback. For same-vendor secondary
adapters, use `-DeviceIndex`, llama.cpp `-Device`, OpenVINO
`-OpenVinoDeviceId`, or oneAPI `-SyclDeviceSelector` as documented above.

Return the entire `$ReportRoot` directory and state whether any installer
requested or performed a reboot. Success is **not** the presence of
`INSTALL_OK`; the final JSON must have `result.ready=true`, no blockers, and
acceptance evidence for the intended backend/device.

| Evidence | Required fields or proof |
| --- | --- |
| Host inventory | `host.architecture`, GPU vendor/model/driver in `host.gpus`, and relevant `host.npus` |
| Acquisition | Each `acquisitions[]` action, source/package or artifact identity, version/requirement, integrity metadata, cache/install path |
| Selection | Requested and selected backend/device/profile; explicit adapter selector when used |
| CUDA / HIP | Compiler/runtime version, actual device, compute capability or gfx target, compiled/executed kernel marker |
| PyTorch / Triton | Exact package tuple, runtime (`torch.version.cuda` or `torch.version.hip`), actual device, tensor marker, Triton vector-add or `torch.compile` evidence |
| Intel AI | OpenVINO requested/actual CPU/GPU/NPU device and provider; SYCL actual GPU and kernel marker |
| llama.cpp | Release tag/assets/digests, `backends`, `gpu_info`, actual `offloaded X/Y layers`, model hash and inference marker |
| Foundry | Selected source-managed device/EP, inference marker, `fallbackUsed`; CPU fallback is valid when reported |
| Ollama | Model digest, inference marker, actual backend/process evidence, VRAM bytes and `gpuFraction` when accelerated |
| Outcome | `result.ready=true`, plus all `warnings` and `blockers`; plan and final console logs |

Partner hardware remains pending for NVIDIA x64, AMD x64, Intel x64 GPU/NPU,
and Qualcomm/Adreno ARM64. Native Windows ARM64 ROCm/XPU and native Windows AMD
Triton remain explicitly upstream-unavailable.

<br/>

## 🎨 Command Palette extension (coming soon)

A [PowerToys Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview) extension lives under [`src/future/cmdpal/`](./src/future/cmdpal/). It reads the same flow list as the rest of the repo and launches DSC-backed or PowerShell-native flows from one list.

See [`src/future/cmdpal/README.md`](./src/future/cmdpal/README.md) for build and install instructions.

<br/>

## 🩺 Troubleshooting

<details>
<summary><strong>"Unrecognized command: configure"</strong></summary>

Run `winget configure --enable`. If `winget configure` is still not recognized after that, [`Workloads/_common/assert-winget-configure.ps1`](./Workloads/_common/assert-winget-configure.ps1) tells you whether App Installer is too old, policy has disabled configuration, or something else needs fixing.

</details>

<details>
<summary><strong><code>winget configure</code> fails with "internal error" / error code <code>-2146233079</code></strong></summary>

This usually means the Microsoft Visual C++ Redistributable is missing — `winget configure` depends on it when invoked from a non-elevated environment. Install it once with the command for your architecture, then re-run:

```powershell
# x64:
winget install Microsoft.VCRedist.2015+.x64

# ARM64:
winget install Microsoft.VCRedist.2015+.arm64
```

See [aka.ms/vcredist](https://aka.ms/vcredist) for the standalone installer. The repo's [`Workloads/_common/enable-winget-configure.ps1`](./Workloads/_common/enable-winget-configure.ps1) script also installs it automatically as part of enabling `winget configure`.

</details>

<details>
<summary><strong>A workload says it succeeded but <code>python</code> / <code>node</code> / the tool isn't on PATH</strong></summary>

Open a new terminal, or run the matching `install.ps1` shim to refresh PATH in the current session.

</details>

<details>
<summary><strong>Windows Dev Config rebooted the machine and looks stuck</strong></summary>

It registered a scheduled task named `WindowsDevConfigResume`, so the run picks itself back up about 30 seconds after you sign back in. A window opens on its own and finishes the WSL setup. If nothing appears after a couple of minutes, run the one-liner again — it's safe to re-run and skips everything already done. More detail in [`windows-dev-config/README.md`](./src/windows-dev-config/README.md#troubleshooting).

</details>

<details>
<summary><strong>Comfort Shell bootstrap fails because WSL is missing</strong></summary>

Run `.\wsl-comfort\install.ps1` on the Windows side instead. It installs WSL first.

</details>

<details>
<summary><strong>WSL install fails with <code>wsl --install ... failed with exit code -1</code></strong></summary>

WSL needs hardware virtualization available to the OS. Two common root causes:

- **On bare metal:** virtualization (VT-x / AMD-V) is disabled in BIOS/UEFI. Reboot into firmware settings, enable it, save, and reboot back into Windows. The exact label varies by vendor — check your motherboard or laptop manufacturer's documentation if you can't find it.
- **Inside a VM:** the host hasn't exposed nested virtualization to the guest. For a Hyper-V host, run this from an elevated PowerShell session **on the host** (with the guest VM powered off):

  ```powershell
  Set-VMProcessor -VMName <VM_NAME> -ExposeVirtualizationExtensions $true
  ```

  Other hypervisors have their own equivalent settings — check your hypervisor's documentation.

</details>

<br/>

## 🐛 Reporting issues

Hit a bug, a stale doc, or a setup that fails on your machine? Open an issue at [github.com/microsoft/WindowsDeveloperConfig/issues](https://github.com/microsoft/WindowsDeveloperConfig/issues). Include your Windows build (`winver`), the exact command you ran, and the failing output. This helps us triage faster.

<br/>

## ❤️ Contributing

Contributions of all kinds are welcome: bug reports, doc fixes, new workloads, voice-and-tone tweaks. Start with [`CONTRIBUTING.md`](./CONTRIBUTING.md), then read [`src/docs/development.md`](./src/docs/development.md) for the CI matrix, the "how to add a language" walkthrough, and how the sign pipeline works.

> **Note on the repo layout:** the [`src/`](./src/) tree is the source of truth. The top-level `windows-dev-config/`, `Workloads/`, and `wsl-comfort/` folders are Authenticode-signed release copies regenerated by the sign pipeline, so please don't edit them directly. Full details in [`src/docs/development.md`](./src/docs/development.md#repo-layout-signed-vs-source).

The single source of truth for every flow (paths, build/run commands, ids, language metadata) is [`src/manifest.yml`](./src/manifest.yml). The Command Palette extension, the CI harness, and the per-flow shims all read from it, so keep it in sync when you add or rename a flow.
