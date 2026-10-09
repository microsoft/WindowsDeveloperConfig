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
  <a href="#-workloads">Workloads</a>
  <span> · </span>
  <a href="#-ai-tooling">AI tooling</a>
  <span> · </span>
  <a href="#-troubleshooting">Troubleshooting</a>
</h3>

---

Set up a new Windows dev box in minutes, not hours. Pick a setup, run one command, get back to building. Everything here is safe to re-run.

## 🎯 Pick your setup

| You want... | Go to |
| --- | --- |
| A full dev workstation: tools, Windows settings, WSL, and terminal. One command, one restart. | [Windows Dev Config](#%EF%B8%8F-windows-dev-config) |
| A nicer WSL shell: zsh/bash, Starship, CLI tools, and a themed terminal profile. | [WSL Comfort](#-wsl-comfort) |
| One language or toolchain. | [Workloads](#-workloads) |
| Local AI: PyTorch for your GPU, plus Ollama, llama.cpp, or Foundry Local. | [AI tooling](#-ai-tooling) |

## 🖥️ Windows Dev Config

Installs dev tools, applies opinionated Windows settings, and sets up WSL + Ubuntu — restart included. Nothing to clone, nothing to install first.

Open any PowerShell window — elevated or not — and run:

<details>
<summary><strong>What you get</strong></summary>

### Standard Experience
- **Dev tools:** Windows Terminal, PowerShell 7, Git, GitHub CLI, GitHub Copilot CLI, VS Code, .NET SDK 10, Python 3.14 + uv, Node.js LTS + nvm, Coreutils for Windows, Windows App CLI, Oh My Posh, and PowerToys.
- **Terminal:** PowerShell 7 as the default profile, Oh My Posh in your prompt, Cascadia Mono NF as the default font, and a GitHub Copilot profile in the dropdown.
- **Windows settings:** Dark theme, long paths, File Explorer defaults, Start/Search settings, and Do Not Disturb
- **WSL:** WSL platform + Ubuntu, including the restart and the automatic resume afterwards.

### Full Experience
- **Everything from standard**
- **Windows settings:** Developer Mode, Sudo, widgets off, and Edge policies, additional Start/Search/System Tray settings
- **Remote Desktop:** Enabled and firewall settings set
</details>

### Standard Experience
```powershell
irm https://aka.ms/devconfig/standard/setup.ps1 | iex
```

### Full Experience
```powershell
irm https://aka.ms/devconfig/full/setup.ps1 | iex
```

> ⚠️ **Heads up — it may restart your PC.** WSL needs virtualization turned on, so save your work first. Setup picks up where it left off after the reboot.

Every tool and setting, how to undo them, and troubleshooting: [Windows Dev Config README](./src/windows-dev-config/README.md).

<br/>

## 🐧 WSL Comfort

*Also known as Comfort Shell. A polished Windows + WSL shell setup — zsh/bash, Starship prompt, modern CLI tools, themed terminal.*

```powershell
.\wsl-comfort\install.ps1
```

Interactive by default — pick and choose components as it runs. Use `-NonInteractive` for unattended installs. The Linux half (`comfort-shell-bootstrap.sh`) is standalone, so you can also copy it onto any Ubuntu host and run it directly.

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

## 🧪 Workloads

Just want one toolchain? Each of these is a single command.

| Workload | Run |
| --- | --- |
| WinUI 3 | `irm https://aka.ms/devconfig/winui/setup.ps1 \| iex` |
| WinForms | `irm https://aka.ms/devconfig/winforms/setup.ps1 \| iex` |
| WinAppCLI | `irm https://aka.ms/devconfig/winappcli/setup.ps1 \| iex` |
| .NET | `irm https://aka.ms/devconfig/dotnet/setup.ps1 \| iex` |
| Go | `irm https://aka.ms/devconfig/go/setup.ps1 \| iex` |
| Rust | `irm https://aka.ms/devconfig/rust/setup.ps1 \| iex` |
| PHP | `irm https://aka.ms/devconfig/php/setup.ps1 \| iex` |

TypeScript, Java, Python, SQL, PowerShell, and what each one installs: [Workloads](./src/windows-dev-config/workloads.md).

<br/>

## 🤖 AI tooling

Detects your GPU, installs the matching PyTorch build (CUDA, ROCm, Intel XPU, or CPU), and proves it works. Add a local model runtime if you want one.

```powershell
irm https://aka.ms/devconfig/local-ai/setup.ps1 | iex           # PyTorch for your hardware
irm https://aka.ms/devconfig/local-ai/ollama/setup.ps1 | iex    # + Ollama
irm https://aka.ms/devconfig/local-ai/llama.cpp/setup.ps1 | iex # + llama.cpp
irm https://aka.ms/devconfig/local-ai/foundry/setup.ps1 | iex   # + Foundry Local
```

Individual pieces (CUDA, ROCm, Intel AI, PyTorch, llama.cpp, Ollama, Foundry Local), hardware support, and options: [AI tooling workloads](./src/windows-dev-config/ai-workloads.md).

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

The Visual C++ Redistributable is missing. Install it, then re-run:

```powershell
# x64:
winget install Microsoft.VCRedist.2015+.x64

# ARM64:
winget install Microsoft.VCRedist.2015+.arm64
```

[`Workloads/_common/enable-winget-configure.ps1`](./Workloads/_common/enable-winget-configure.ps1) installs it automatically as part of enabling `winget configure`.

</details>

<details>
<summary><strong>A workload says it succeeded but <code>python</code> / <code>node</code> / the tool isn't on PATH</strong></summary>

Open a new terminal, or run the matching `install.ps1` shim to refresh PATH in the current session.

</details>

<details>
<summary><strong>Windows Dev Config rebooted the machine and looks stuck</strong></summary>

A scheduled task resumes the run about 30 seconds after you sign back in and finishes the WSL setup. Nothing after a couple of minutes? Run the one-liner again — it's safe to re-run and skips everything already done. More detail in [`windows-dev-config/README.md`](./src/windows-dev-config/README.md#troubleshooting).

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
