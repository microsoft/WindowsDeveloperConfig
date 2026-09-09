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

If you're not already elevated, setup requests UAC consent before starting. It requests consent again when resuming after a reboot. Expect about 30 minutes on a clean machine.

> `-AllowUnsigned` runs the source copy under `src/` instead of the signed copy at the repository root.

> ⚠️ **It will restart your machine, once.** Enabling WSL needs a Windows optional feature that requires a restart. You get a 10-second warning, and a scheduled task resumes setup after you sign back in and accept the UAC prompt. **Save your work before you start.**

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
| llama.cpp | x64 Vulkan or verified ARM64 CPU/CUDA runtime + pinned Qwen3-0.6B GGUF inference | `.\Workloads\llama.cpp\install.ps1` |
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
| CUDA | WinGet CUDA stable | NVIDIA CUDA 13.4 Developer Preview | NVIDIA GPU + current driver by default. Installs MSVC, compiles with `nvcc -arch=native`, and executes a kernel. `-ToolkitOnly` permits compiler-only setup. |
| AMD ROCm / HIP | ROCm Core SDK 10.0 on supported Radeon/Ryzen AI GPUs | Not published | Uses AMD's stable Windows x64 feed and executes a compiled HIP kernel. Native Windows Triton is unsupported. |
| Intel AI | OpenVINO CPU/GPU/NPU; optional oneAPI/SYCL | Not published | OpenVINO performs generated-model inference on the requested device. `-Profile Full` also executes a SYCL GPU kernel. |
| Foundry Local | Supported | Supported | Windows 11 24H2/build 26100+. Uses WinML and does **not** require CUDA. Downloads `qwen3-0.6b` and runs a marker completion. |
| PyTorch | CPU, NVIDIA CUDA, AMD ROCm, or Intel XPU | Stable CPU, or pinned NVIDIA CUDA 13.4 Developer Preview on RTX Spark | `-Backend Auto` deterministically selects NVIDIA → AMD → Intel → CPU. Explicit backend requests never silently fall back. |
| Triton Windows | NVIDIA CUDA (`triton-windows`) or Intel XPU (`triton-xpu`) | NVIDIA CUDA 13.4 preview stack | AMD native Windows Triton is unsupported. Supported paths execute a real compiled GPU kernel. |
| llama.cpp | WinGet Vulkan build | Verified official CPU or CUDA 13.4 rolling release | Downloads a pinned, checksum-verified Qwen3-0.6B Q4_K_M GGUF and performs constrained inference. |
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
```

Every AI entry point accepts `-PlanOnly` and `-ReportPath`. Plan mode performs
hardware/support resolution without installing software. Applied runs write JSON
to `%LOCALAPPDATA%\DevConfig\reports\<flow>-latest.json`; the reusable hardware
inventory command is:

```powershell
.\src\tools\collect-ai-hardware.ps1
```

Default acceptance proves each workload is usable, not merely installed:
CUDA executes a compiled GPU kernel; PyTorch performs a tensor operation on the
selected backend and, when supported, Triton runs a GPU kernel; and each local
model runtime downloads a small Apache-2.0 Qwen model and performs deterministic
text inference.

| Flow | Default model download | Cache |
| --- | ---: | --- |
| Foundry Local | `qwen3-0.6b`, about 593 MB | Reported by `foundry cache location` |
| llama.cpp | `Qwen3-0.6B-Q4_K_M.gguf`, 396,704,416 bytes | `%LOCALAPPDATA%\DevConfig\llama.cpp\models` |
| Ollama | `qwen3:0.6b`, about 522 MB | `%USERPROFILE%\.ollama\models` or `OLLAMA_MODELS` |

Use `-SkipModelSmoke` with Foundry Local, llama.cpp, or Ollama to opt out
of the model download and inference. Use CUDA's `-SkipWorkloadSmoke` to opt out
of kernel compilation/execution. Opted-out runs verify installation only and do
not report full workload readiness.

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
and Ollama. AMD ROCm/HIP and Intel OpenVINO/oneAPI are hardware-gated and ready
for partner execution on supported Windows x64 systems; their current gap is
physical AMD/Intel hardware coverage, not static planning or unit coverage.

### Preview and rolling acquisition promotion

Acquisition metadata is centralized in
[`Workloads/_common/ai-catalog.psd1`](./src/Workloads/_common/ai-catalog.psd1).
Changing from a preview/rolling artifact to a normal channel is a resolver-data
change after the stated detection rule and real hardware acceptance pass.

| Component | Vendor / architecture | Current channel and identity | Integrity | Why normal channel is insufficient | Expected stable channel | Promotion trigger |
| --- | --- | --- | --- | --- | --- | --- |
| CUDA ARM64 | NVIDIA / ARM64 | Developer Preview `cuda_13.4.0_windows_arm64.exe` | Pinned SHA-256 + NVIDIA Authenticode | `Nvidia.CUDA` has no ARM64 payload | `Nvidia.CUDA` ARM64, unconfirmed | ARM64 WinGet manifest appears and N1X kernel passes |
| PyTorch CUDA ARM64 | NVIDIA / ARM64 | Nightly `torch-2.15.0.dev20260904+cu134-cp313-win_arm64.whl` | Pinned SHA-256 | Stable PyTorch indexes have no Windows ARM64 CUDA wheel | Official PyTorch CUDA Windows ARM64 feed, unconfirmed | Stable wheel appears and tensor/Triton tests pass |
| Triton Windows | NVIDIA x64/ARM64 | Community `triton-windows==3.8.0.post28` | Package-index TLS + wheel RECORD | Upstream Triton has no general stable Windows package | Official PyTorch/Triton Windows feed, unconfirmed | Official package appears and kernel passes |
| llama.cpp ARM64 | NVIDIA/Qualcomm/CPU / ARM64 | Latest complete rolling `bNNNNN` asset set | GitHub asset SHA-256 | WinGet lacks ARM64 backend variants | `ggml.llamacpp` with required backend, otherwise unconfirmed | Matching WinGet variant appears and benchmark/inference pass |
| Foundry Local | Cross-vendor / x64, ARM64 | Preview `Microsoft.FoundryLocal` | WinGet MSIX hash/signature | Product is still preview | Same package ID at GA | Microsoft marks GA and inference/provider report passes |
| Ollama ARM64 | CPU/NVIDIA / ARM64 | Latest stable official `ollama-windows-arm64.zip` | GitHub asset SHA-256 | Desktop WinGet ID is x64; portable package can lag | Current ARM64 WinGet payload, package ID unconfirmed | WinGet catches current release and API/GPU evidence passes |

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
