# WindowsDevSetupScripts — Developer Guide

> 👋 **Just want to run something?** See the
> [top-level README](../../README.md). This file is the contributor /
> CI / "how the sausage gets made" guide.

Opinionated, CI-validated configurations for bootstrapping developer
toolchains and Windows-desktop personalities.

Most language and desktop flows are built around a [winget DSC configuration
file](https://learn.microsoft.com/windows/package-manager/configuration/)
(`configuration.winget`) — a declarative, idempotent description of the
machine state required for that flow. Where winget alone is not enough
(e.g. `npm install --global typescript` or a registry tweak) the
configuration calls a DSC `Script` / `RunCommandOnSet` / `Registry`
resource, so everything the flow needs lives in one YAML file. A small
`install.ps1` shim next to it applies the config with `winget configure`
and handles session-level glue (PATH refresh, CI sentinel).

The AI workloads are PowerShell-native. They follow Windows Dev Config's
resumable check → apply → verify contracts and reuse its WinGet, retry, process,
and PATH helpers through `Workloads/_common/direct-setup.ps1`. They need runtime
hardware selection, contained Python environments, verified release assets, and
real device/model acceptance that is awkward and misleading inside static DSC.
The shared package state machine distinguishes absent, upgrade-available, and
current packages: it installs only absent IDs, uses exact `winget upgrade` for
outdated packages, and skips current packages. If the WinGet module operation
fails but `winget.exe` is usable, it retries the same exact operation through
the CLI and verifies the settled state.

Windows Dev Config and Comfort Shell are also PowerShell-native because they
need elevation, reboot/resume, or interactive orchestration. All
PowerShell-native flows keep the same idempotency contract: every step checks
current state, acts only when needed, and verifies the result.

Every automated flow is **exercised on a real GitHub-hosted runner** on every
push, pull request, and nightly: the flow is applied, then a canonical "hello
world" is built and executed, and its stdout is diffed against a checked-in
expected output. If a flow's hello world prints the right thing, we know the
configuration actually produced a working toolchain.

## Supported flows

Each flow's `configuration.winget` or PowerShell-native entry script is the
source of truth for what gets installed;
the table below summarizes it for quick scanning. Flows marked **manual**
are excluded from the automated CI matrix (they need an interactive
desktop session or pull multi-GB workloads we don't want to chew minutes
on), but are still verified end-to-end on demand and surfaced in the
Command Palette extension.

| Flow              | CI status     | Installs                                                                                |
| ----------------- | ------------- | --------------------------------------------------------------------------------------- |
| TypeScript        | ✅ automated   | `OpenJS.NodeJS.LTS` + `npm install -g typescript`                                       |
| PHP               | ✅ automated   | `PHP.PHP.8.5`                                                                           |
| .NET              | ✅ automated   | `Microsoft.DotNet.SDK.10`                                                               |
| Go                | ✅ automated   | `GoLang.Go` (rolling — winget publishes Go unversioned)                                 |
| Java              | ✅ automated   | `Microsoft.OpenJDK.25`                                                                  |
| Rust              | ✅ automated   | `Rustlang.Rustup` (then `rustup default stable`)                                        |
| Python            | ✅ automated   | `Python.Python.3.14`, `astral-sh.uv`                                                    |
| SQL Developer     | 🙋 manual     | Lightweight SQL Developer: SQL Server + sqlcmd + VS Code extension; no VS/SSDT           |
| PowerShell        | ✅ automated   | `Microsoft.PowerShell`, `Microsoft.VisualStudioCode`, VS Code PowerShell/Pester extensions + PSScriptAnalyzer settings |
| WinForms          | 🙋 manual     | `Microsoft.DotNet.SDK.10` + the .NET desktop workload (multi-GB; manual to spare CI minutes) |
| WinUI 3           | 🙋 manual     | `Microsoft.DotNet.SDK.10`, `Microsoft.VisualStudio.Community`, `Microsoft.WinAppCLI` + WinUI/Universal/ManagedDesktop VS workloads |
| Windows Dev Config | 🙋 manual     | A full distraction-free workstation, in PowerShell: 15 apps + 25 registry values + fonts + Windows Terminal + WSL + Ubuntu (see [`windows-dev-config/README.md`](../windows-dev-config/README.md)) |
| NVIDIA CUDA       | 🙋 manual     | `Nvidia.CUDA` x64 or checksum/signature-pinned 13.4 ARM64 preview + MSVC + GPU kernel |
| AMD ROCm / HIP    | 🙋 manual     | ROCm Core SDK 10.0 on supported Windows x64 AMD GPUs + compiled HIP kernel |
| Intel AI          | 🙋 manual     | OpenVINO device inference; optional oneAPI/SYCL toolkit and GPU kernel |
| Foundry Local     | 🙋 manual     | `Microsoft.FoundryLocal` architecture-native WinML package + Qwen3 inference; no CUDA dependency |
| PyTorch           | 🙋 manual     | `Python.Python.3.13` + private CPU/CUDA/ROCm/XPU environment + supported Triton provider |
| llama.cpp         | 🙋 manual     | SHA-256-verified official rolling CUDA/ROCm/SYCL/OpenVINO/Vulkan/OpenCL/CPU assets + pinned GGUF |
| Ollama            | 🙋 manual     | `Ollama.Ollama` x64 desktop or current official ARM64 portable release + official model inference |
| Comfort Shell     | 🙋 manual     | WSL distro + zsh/bash + starship + modern CLI bundle + Cascadia Code Nerd Font + themed Windows Terminal profile (see [`wsl-comfort/readme.md`](../wsl-comfort/readme.md)) |

See [`manifest.yml`](../manifest.yml) for the canonical declarative
list (paths, build/run commands, onboarding URLs).

## Command Palette extension

A [PowerToys Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview)
extension lives under [`future/cmdpal/`](../future/cmdpal/). It reads the same
`manifest.yml` as CI and launches DSC-backed or PowerShell-native flows from one
list.

The UX metadata each flow needs (`name`, `description`, `category`, `tags`,
`icon`, `onboardingUrl`) is colocated with the CI fields in `manifest.yml` so
there is one source of truth. See [`future/cmdpal/README.md`](../future/cmdpal/README.md)
for build + configuration details.

## Repository layout

```
Workloads/
  _common/         # shared DSC glue plus direct AI acquisition, resolver catalog, and reporting helpers
  typescript/      # configuration.winget (core) + install.ps1 (thin shim)
  php/             # configuration.winget (core) + install.ps1 (thin shim)
  python/          # configuration.winget (core) + install.ps1 (thin shim)
  dotnet/          # configuration.winget (core) + install.ps1 (thin shim)
  go/              # configuration.winget (core) + install.ps1 (thin shim)
  java/            # configuration.winget (core) + install.ps1 (thin shim)
  rust/            # configuration.winget (core) + install.ps1 (thin shim)
  winforms/        # configuration.winget (core) + install.ps1 (thin shim)
  winui/           # configuration.winget (core) + install.ps1 (thin shim)
  cuda/            # x64/ARM64 CUDA + MSVC + compiled GPU-kernel readiness
  rocm/            # Windows x64 AMD ROCm Core SDK + compiled HIP kernel
  intel-ai/        # Windows x64 OpenVINO and optional oneAPI/SYCL
  foundry/          # x64/ARM64 Foundry Local + catalog-model inference
  pytorch/          # x64/ARM64 Python + contained backend-selected environment
  llama.cpp/       # hardware-selected official rolling backend + pinned GGUF inference
  ollama/          # architecture-specific direct acquisition + library-model inference
windows-dev-config/    # Windows Dev Config — bootstrap.ps1 (remote entry) + dev-config.ps1 (orchestrator) + steps/*.ps1 + README.md
wsl-comfort/           # Comfort Shell — install.ps1 (Windows side) + comfort-shell-bootstrap.sh (Linux side, self-contained) + readme.md
tests/
  _harness/          # build-run-diff harness used by CI:
                     #   run-flow.ps1   - all flows (build + run + diff stdout)
                     #   run-server.ps1 - helper for future server scenarios
                     #                    (kept idle; no flow currently uses it)
  typescript/        # hello.ts + expected.txt
  php/               # hello.php + expected.txt
  python/            # hello.py + expected.txt
  dotnet/            # hello.csproj + Program.cs + expected.txt
  go/                # hello.go + expected.txt
  java/              # Hello.java + expected.txt
  rust/              # Cargo.toml + src/main.rs + expected.txt
  winforms/          # hello.csproj + Program.cs + expected.txt
  winui/             # hello.csproj + Program.cs + expected.txt
  calm-os/           # probe.ps1 + expected.txt (manual-only flow)
  comfort-shell/     # hello.sh + expected.txt (manual-only flow)
manifest.yml         # declarative list of flows consumed by CI **and** by the extension
future/
  cmdpal/            # PowerToys Command Palette extension (reads manifest.yml)
.github/workflows/
  ci.yml             # discover -> per-OS matrix -> summary
```

## Repo layout: signed vs source

This repo carries **two parallel copies** of every flow:

| Path                          | What it is                                                        | Edit it? | Run it?  |
| ----------------------------- | ----------------------------------------------------------------- | -------- | -------- |
| `windows-dev-config/`         | **Signed release copy** (Authenticode).                           | No       | **Yes**  |
| `Workloads/`                  | **Signed release copy** of every single-language workload.        | No       | **Yes**  |
| `wsl-comfort/`                | **Signed release copy**.                                          | No       | **Yes**  |
| `src/windows-dev-config/`     | Source. CI runs from here.                                        | **Yes**  | Yes      |
| `src/Workloads/`              | Source. CI runs from here.                                        | **Yes**  | Yes      |
| `src/wsl-comfort/`            | Source. CI runs from here.                                        | **Yes**  | Yes      |
| `src/manifest.yml`            | Single source-of-truth for every flow (paths, build/run, ids).    | **Yes**  | n/a      |
| `src/future/cmdpal/`          | Command Palette extension. C# project. Reads `src/manifest.yml`.  | **Yes**  | n/a      |
| `src/docs/development.md`     | Contributor docs (CI, validation, how to add a language).         | **Yes**  | n/a      |
| `src/tests/`                  | Hello-world programs + expected stdout used by the CI harness.    | **Yes**  | CI only  |

**End users**: the commands in the top-level [README](../../README.md) point at the **top-level signed copies** wherever those copies exist, so on a Windows box you don't need to know `src/` exists. The one exception is Windows Dev Config: its `bootstrap.ps1` is new and hasn't been through a sign cycle yet, so the README's one-liner points at `src/windows-dev-config/bootstrap.ps1`. That's deliberate — the bootstrap requires the *signed* payload from the repository root by default, verifies every payload `.ps1` has a valid Microsoft Corporation Authenticode signature, and stops before installation if any check fails. Contributors can explicitly select `src/windows-dev-config/` and bypass signature validation with `-AllowUnsigned` while testing a ref before its signed copy exists. Repoint the README at the top-level copy once it lands.

**Contributors**: edit `src/`. The top-level paths are **regenerated** by [`.pipelines/OneBranch.SignAndPackage.yml`](../../.pipelines/OneBranch.SignAndPackage.yml), which Authenticode-signs every `src/**/*.ps1` and ships them (plus the `.winget` configs and the manifest) as the release artifact. The signed copies were merged into `main` from the `signed` branch in [PR #6](https://github.com/microsoft/WindowsDeveloperConfig/pull/6). A change to a `src/` script becomes a new signed top-level copy on the next sign cycle, not at PR merge, so the two can briefly disagree on a script's body until that cycle runs.

**Deleting a file is the one case where you must touch both trees.** The sign pipeline only adds and overwrites — it never deletes. A file removed from `src/` therefore stays at the top level forever, still published and still runnable, until someone removes it by hand. So when you delete or rename a flow artifact, `git rm` it from **both** `src/…` and the matching top-level path in the same PR. (The drift guard won't catch this for you: a file that exists in neither tree produces no report entry at all.)

**CI**: GitHub Actions ([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)) runs the **unsigned `src/` copies** (e.g. `./src/Workloads/_common/preflight.ps1`). This is intentional: CI exercises what contributors edit; signing is a release-time concern, not a build-time one.

**Don't**:

- Don't edit a top-level signed copy directly. The next sign cycle will overwrite it, and the cycle signs `src/`, not the top level.
- Don't expect the two trees to be byte-identical. The signed copies carry an Authenticode signature block (`# SIG # Begin signature block` … `# SIG # End signature block`); the bodies above that marker should match what's in `src/`. They will diverge for the window between a `src/` change landing on `main` and the next sign cycle catching up.
- Don't delete from `src/` only. See above — removals are the one change the pipeline can't propagate.
- Don't add a third copy of anything. Both copies exist for one reason only (to ship signed PS1s without losing the unsigned source), and any new flow or shared script lives only in `src/` until the sign pipeline mirrors it.

### Signed-copy drift guard

A PR check named **`Signed copy guard`** ([`.github/workflows/signed-copy-guard.yml`](../../.github/workflows/signed-copy-guard.yml)) runs **only when a PR touches files under `Workloads/`, `windows-dev-config/`, or `wsl-comfort/`** (i.e. one of the three top-level signed-copy roots). For every PR-touched file in those roots, it fails the job if the file no longer matches its `src/` counterpart — modulo the Authenticode signature block on `.ps1` files (the body above `# SIG # Begin signature block` must match; everything else, including `.winget` / `.sh` / `.md` / images / any new extension, must be strictly byte-equal). PRs that edit only `src/` skip this check entirely; the sign pipeline will mirror those changes to the top level on the next sign cycle.

The drift definition is implemented by the shared comparator [`src/tools/check-signed-drift.ps1`](../tools/check-signed-drift.ps1), which is the single source of truth for "what counts as drift". It is a pure reporter — it always exits 0 and emits a JSON report; the workflow decides pass/fail. A follow-up PR will add a non-blocking "Drift status" visibility check that reuses the same script.

Maintainers: once this guard has landed, add **`Signed copy guard`** to the required status checks in `main`'s branch protection so PRs cannot bypass it. The guard does **not** replace the sign pipeline; it only prevents human edits to the top-level copies between sign cycles.

## Prerequisites (Windows)

DSC-backed language/desktop flows install through `winget configure`. The
PowerShell-native AI and workstation flows do not require the configure
subcommand; they use WinGet's package API/CLI directly when a package is
available and verified vendor artifacts otherwise.

- **App Installer (winget)** must be current. Update from the Microsoft
  Store, or grab the latest MSIX from
  [microsoft/winget-cli releases](https://github.com/microsoft/winget-cli/releases/latest).
- **Configuration feature** must be enabled. On recent winget this is GA
  and on by default; on older builds you may need to run `winget settings`
  and set `experimentalFeatures.configuration = true`.
- **Group Policy / MDM** must allow it. If the registry value
  `HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller\
  EnableWindowsPackageManagerConfiguration` is `0`, configure is blocked
  machine-wide and needs a policy change before anything here will work.

Quick smoke test:

```powershell
winget configure --help | Select-Object -First 3
```

If the help text prints, you're good. If it errors or prints
"Unrecognized command", fix the above before running any flow. Each
`install.ps1` shim runs
[`Workloads/_common/assert-winget-configure.ps1`](../Workloads/_common/assert-winget-configure.ps1)
first and will emit an actionable message describing exactly which of the
three conditions above needs attention.

## Running a flow locally (Windows)

Apply the DSC configuration directly with winget:

```powershell
winget configure --file ./Workloads/typescript/configuration.winget `
    --accept-configuration-agreements `
    --disable-interactivity
```

…or run the shim, which does the same plus rehydrates PATH in your current
session and prints a CI-friendly sentinel:

```powershell
./Workloads/typescript/install.ps1
./tests/_harness/run-flow.ps1 -Id typescript `
    -Build 'tsc tests/typescript/hello.ts' `
    -Run   'node tests/typescript/hello.js' `
    -Expected tests/typescript/expected.txt
```

AI flows are always launched through their PowerShell entry point:

```powershell
.\Workloads\cuda\install.ps1
.\Workloads\rocm\install.ps1
.\Workloads\intel-ai\install.ps1
.\Workloads\pytorch\install.ps1
```

Use `-PlanOnly` to resolve hardware, architecture, channel, and planned
acquisitions without changing the machine. Each run emits an `AI_REPORT:` path.

## Testing and verifying locally

CI runs each flow on a fresh `windows-latest` runner, so the highest-fidelity
signal is always a green CI run on your branch. The checks below let you catch
problems before pushing.

> A clean Windows VM (e.g. a throwaway Hyper-V / Dev Box / Windows Sandbox
> image) is strongly recommended for any step that actually installs
> toolchains. Applying a DSC config on your daily-driver machine will happily
> install Node, PHP, etc. system-wide — and since these flows are idempotent,
> that is generally harmless but not always what you want.

### 1. Static checks (any OS, fast)

These don't touch your machine state and are a good pre-commit pass:

```bash
# DSC YAML parses and has the expected shape.
python3 -c "import yaml; yaml.safe_load(open('Workloads/typescript/configuration.winget'))"
python3 -c "import yaml; yaml.safe_load(open('Workloads/php/configuration.winget'))"

# manifest.yml parses (this is what CI's `discover` job consumes).
python3 -c "import yaml; print(yaml.safe_load(open('manifest.yml')))"
```

```powershell
# PowerShell parse check for every .ps1 in the repo (no execution).
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName, [ref]$null, [ref]$errs)
    if ($errs) { Write-Error "$($_.FullName): $errs" } else { "OK: $($_.Name)" }
}
```

If you have [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
installed, also run:

```powershell
Invoke-ScriptAnalyzer -Recurse -Path ./Workloads, ./tests/_harness
```

The hardware-dependent AI workloads also provide pure decision tests that do
not require a GPU or install software:

```powershell
foreach ($id in 'ai-common','cuda','rocm','intel-ai','foundry','pytorch','llama.cpp','ollama') {
    & ".\tests\$id\unit.ps1"
}
```

These cover architecture selection, backend and dependency decisions,
idempotent plan construction, missing tool/hardware errors, and generated pip
arguments. Their runtime probes remain `manual_test` because hosted CI cannot
exercise the required GPUs, local servers, or multi-gigabyte installers.

### AI workload support and manual verification

Run from the `src` directory:

```powershell
.\Workloads\cuda\install.ps1
.\Workloads\rocm\install.ps1
.\Workloads\intel-ai\install.ps1
.\Workloads\foundry\install.ps1
.\Workloads\pytorch\install.ps1
.\Workloads\llama.cpp\install.ps1
.\Workloads\ollama\install.ps1
```

| Flow | x64 behavior | ARM64 behavior | Readiness signal |
| --- | --- | --- | --- |
| CUDA | Current stable CUDA 13 `Nvidia.CUDA` + MSVC; driver 580+/CC7.5+ for GPU readiness | Checksum- and Authenticode-verified NVIDIA CUDA 13.4 Developer Preview + ARM64 MSVC | Compile and execute `smoke.cu`; `-SkipWorkloadSmoke` opts out |
| ROCm / HIP | AMD stable ROCm 10.0 feed on supported Radeon/Ryzen AI GPUs | Unsupported | Compile and execute `hip-smoke.cpp`; exact GPU maps to a published `gfx` target |
| Intel AI | OpenVINO CPU/GPU/NPU; optional oneAPI/SYCL GPU tooling | Unsupported | Generated OpenVINO model executes on requested device; Full profile also runs a SYCL kernel |
| Foundry | WinGet x64 WinML package | WinGet ARM64 WinML package | Download `qwen3-0.6b` (~593 MB) and generate a marker; CUDA is never assumed |
| PyTorch CUDA | Stable NVIDIA CUDA wheel selected by driver/device | Pinned NVIDIA CUDA 13.4 preview wheel for CPython 3.13/RTX Spark | Self-contained wheel runtime, device tensor, and supported Triton CUDA kernel |
| PyTorch ROCm | AMD stable feed with exact device `gfx` package | Unsupported | Self-contained AMD runtime tuple, HIP runtime assertion, AMD device tensor; no native Windows Triton |
| PyTorch XPU | Official PyTorch XPU index | Unsupported | Self-contained XPU tuple, Intel device tensor, and `triton-xpu`/`torch.compile` |
| llama.cpp CUDA | Paired CUDA 13.3/12.4 app+cudart assets selected by driver/capability | Paired CUDA 13.4 Developer Preview app+cudart on qualified N1X | `llama-bench` proves CUDA device/GPU layers; pinned GGUF inference generates a constrained marker |
| llama.cpp ROCm | Official ROCm 10.0 asset on a supported AMD GPU | Unsupported | Benchmark must identify ROCm/AMD and GPU layers before inference is ready |
| llama.cpp SYCL / OpenVINO | Official SYCL or explicit OpenVINO 2026.3.1 asset | Unsupported | Intel Auto prefers SYCL for direct GPU evidence; OpenVINO is explicit and does not imply NPU support |
| llama.cpp OpenCL Adreno | Unsupported | Official Qualcomm Adreno OpenCL asset | Requires the Windows OpenCL loader; benchmark must identify OpenCL/Adreno and GPU layers |
| llama.cpp Vulkan / CPU fallback | Official rolling backend-specific assets | CPU asset | Vulkan is x64 Auto fallback only; CPU reports zero GPU layers |
| Ollama | Current WinGet desktop package | Current verified official ARM64 release ZIP | Official `qwen3:0.6b` (~522 MB) blob hash verification + structured inference |

PyTorch's environment is
`$env:LOCALAPPDATA\DevConfig\pytorch\.venv`. Auto selection is supported
NVIDIA CUDA → supported AMD ROCm → supported Intel XPU → CPU. Explicit
selection can target a supported secondary adapter. `ROCm` installs AMD's
device-specific torch/torchvision/torchaudio tuple inside the venv; it does not
require the standalone ROCm Core SDK. `XPU` installs the official XPU tuple and
`triton-xpu`; it does not install full oneAPI. CUDA wheels carry their runtime;
the standalone CUDA toolkit is acquired only when the selected Triton/JIT path
needs native toolchain components. Use `-RequireTriton` when supported Triton
execution is mandatory or `-SkipTriton` to disable it.

Vendor layer mapping:

| Vendor | Native layer | PyTorch layer |
| --- | --- | --- |
| NVIDIA | `cuda`: nvcc/toolkit + compiled native kernel | CUDA wheel runtime; automatic compiler/toolkit acquisition only for supported Triton JIT |
| AMD | `rocm`: Core SDK/hipcc + compiled HIP kernel | AMD device-specific runtime tuple in PyTorch venv; no dependency on `rocm` for tensor inference |
| Intel | `intel-ai`: OpenVINO runtime; optional full oneAPI/SYCL | Official XPU wheel + `triton-xpu` in PyTorch venv; no full oneAPI dependency |

The Windows ARM64 CUDA path is a pinned NVIDIA/PyTorch developer-preview stack:
CUDA 13.4 and `torch-2.15.0.dev20260904+cu134` for CPython 3.13. The direct
wheel URL includes NVIDIA's SHA-256 fragment, while ordinary dependencies
(including NumPy) resolve through the user's configured default Python index.
The flow never uses `--extra-index-url`, which would mix untrusted candidates.
The 1.85 GB wheel is downloaded once into
`%LOCALAPPDATA%\DevConfig\pytorch\wheel-cache`, hash-verified, and installed
from that local cache. Reruns compare the desired state with exact installed
torch, NumPy, and Triton versions; matching environments skip package work but
still execute the tensor and Triton kernel probes.

Foundry, llama.cpp, and Ollama accept `-SkipModelSmoke`; CUDA accepts
`-SkipWorkloadSmoke`. These opt-outs avoid the default model/kernel acceptance
tests, but the resulting run is installation-only and does not claim full
workload readiness. Model licenses are Apache-2.0. Foundry reports its mutable
cache via `foundry cache location`; llama.cpp pins an immutable Qwen revision,
size, and SHA-256 under `%LOCALAPPDATA%\DevConfig\llama.cpp\models`; Ollama
verifies the pinned content-addressed model blob under
`%USERPROFILE%\.ollama\models` (or `OLLAMA_MODELS`).

Every AI flow accepts `-PlanOnly` and `-ReportPath`. Plan mode is safe on
unsupported machines: it writes blockers and planned acquisitions without
changing the system. Reports conform to
[`docs/ai-workload-report.schema.json`](./ai-workload-report.schema.json).
Collect just the portable host inventory with:

```powershell
.\src\tools\collect-ai-hardware.ps1
.\src\tools\get-ai-capabilities.ps1 -OutputPath "$env:TEMP\ai-capabilities.json"
```

Current real-hardware coverage:

| Host | Validated workloads |
| --- | --- |
| Windows 11 ARM64 build 28120, NVIDIA RTX Spark N1X, driver 616.62 | CUDA 13.4 kernel; PyTorch cu134 tensor; Triton vector-add; Foundry qwen3-0.6b inference; llama.cpp CUDA inference; Ollama 0.34.0 on a resolver-owned loopback endpoint with verified qwen3:0.6b inference and `/api/ps` at 100% GPU |
| Supported Windows x64 NVIDIA GPU | Partner run pending: llama.cpp CUDA 13.3/12.4 benchmark and inference |
| Supported Windows x64 AMD GPU | Partner run pending: ROCm/HIP kernel, PyTorch ROCm tensor, and llama.cpp ROCm benchmark/inference |
| Supported Windows x64 Intel GPU/NPU | Partner run pending: OpenVINO selected-device inference, optional SYCL kernel, PyTorch XPU/torch.compile, and llama.cpp SYCL/OpenVINO benchmark/inference |
| Supported Windows ARM64 Qualcomm/Adreno GPU | Partner run pending: llama.cpp OpenCL/Adreno benchmark and inference |

Known vendor gaps and boundaries:

| Vendor | GPU workloads | NPU workloads | Windows CPU architecture | Maturity / validation | Boundary |
| --- | --- | --- | --- | --- | --- |
| NVIDIA | CUDA native kernel, PyTorch CUDA/Triton, llama.cpp CUDA | No vendor-specific NPU flow; Foundry/WinML is separate | x64 partner pending; ARM64 N1X live validated | x64 stable; ARM64 CUDA/PyTorch developer preview | Foundry N1X acceptance is truthful CPU fallback because CUDA EP registration was unavailable |
| AMD | ROCm/HIP, PyTorch ROCm, llama.cpp ROCm on published gfx matrix | None; ROCm does not cover Ryzen AI NPU | x64 only | Static/resolver complete, partner pending | No native Windows AMD Triton; no Ollama AMD or Foundry AMD EP claim without backend evidence |
| Intel | OpenVINO GPU, oneAPI/SYCL, PyTorch XPU/compile, llama.cpp SYCL/OpenVINO | OpenVINO NPU only after actual selected-device inference | x64 only | Static/resolver complete, partner pending | PyTorch XPU and llama SYCL are GPU paths, not NPU paths |
| Qualcomm | llama.cpp Adreno OpenCL; Foundry/WinML vendor-neutral provider path | WinML/Foundry only when provider evidence proves it | ARM64 | Static/resolver complete, partner pending | No native PyTorch backend; Ollama ARM64 is CPU/NVIDIA capability unless Adreno evidence exists |
| Other/fallback | Vulkan x64 and CPU x64/ARM64 | None | As listed | Compatibility only | Never label Vulkan/CPU as vendor-native; Mali/other Windows stacks are unimplemented without official artifacts |

GPU drivers are preconditions. The flows report installed driver versions and
give remediation for unsupported versions, but do not replace GPU drivers.
Explicit backend selection can choose a supported secondary vendor on a mixed
system. Same-vendor targeting uses `-DeviceIndex` for CUDA/ROCm and explicit PyTorch backends,
`-Device` for llama.cpp runtime identifiers, `-OpenVinoDeviceId` for OpenVINO,
and `-SyclDeviceSelector` for oneAPI. Foundry and Ollama are source-managed:
they report the actual provider/allocation and do not imply a selector.

Code path readiness before hardware testing:

| Supported combination | Resolver | Acquisition | Workload probe | Report contract | Static/unit | Live hardware |
| --- | --- | --- | --- | --- | --- | --- |
| CUDA / NVIDIA x64 | Yes | Stable WinGet + MSVC | Native CUDA kernel | Driver/device/compiler/kernel | Pass | Partner pending |
| CUDA / NVIDIA ARM64 N1X | Yes | Pinned preview + MSVC ARM64 | Native CUDA kernel | Hash/signature/driver/device/kernel | Pass | **Passed** |
| ROCm/HIP / AMD x64 gfx matrix | Yes | AMD stable tuple | Native HIP kernel | Runtime/gfx/actual device/kernel | Pass | Partner pending |
| Intel OpenVINO CPU x64 | Yes | Official Python tuple | Generated-model CPU inference | Requested/actual device | Pass | Partner pending |
| Intel OpenVINO GPU x64 | Yes | Official Python tuple | Generated-model GPU inference | Requested/actual GPU | Pass | Partner pending |
| Intel OpenVINO NPU x64 | Yes | Official Python tuple | Generated-model NPU inference | Requested/actual NPU | Pass | Partner pending |
| Intel oneAPI/SYCL GPU x64 | Yes | Stable WinGet | Native SYCL kernel | Selector/device/compiler/kernel | Pass | Partner pending |
| Intel Full GPU x64 | Yes | OpenVINO + oneAPI | GPU inference + SYCL kernel | Both acceptance records | Pass | Partner pending |
| PyTorch CPU x64 | Yes | Official CPU wheel | Tensor + NumPy bridge | Tuple/device/operation | Pass | Partner pending |
| PyTorch CPU ARM64 | Yes | Official CPU wheel | Tensor + NumPy bridge | Native tuple/device/operation | Pass | Partner pending |
| PyTorch CUDA x64 | Yes | Official CUDA wheel | NVIDIA tensor | Runtime/device/tuple/operation | Pass | Partner pending |
| PyTorch CUDA ARM64 N1X | Yes | Pinned nightly wheel | NVIDIA tensor | Hash/runtime/device/operation | Pass | **Passed** |
| PyTorch ROCm AMD x64 | Yes | Exact AMD gfx tuple | HIP-compatible AMD tensor | HIP runtime/gfx/device/tuple | Pass | Partner pending |
| PyTorch XPU Intel x64 | Yes | Official XPU tuple | Intel XPU tensor | XPU device/tuple/operation | Pass | Partner pending |
| Triton CUDA x64 | Yes | Community Windows wheel + JIT toolchain | Vector-add kernel | Distribution/device/kernel | Pass | Partner pending |
| Triton CUDA ARM64 N1X | Yes | Community wheel + preview JIT stack | Vector-add kernel | Distribution/device/kernel | Pass | **Passed** |
| Triton XPU x64 | Yes | Official `triton-xpu` | Cold `torch.compile` | Intel device/compile evidence | Pass | Partner pending |
| llama CPU x64 | Yes | Official rolling CPU asset | Benchmark + GGUF inference | Tag/digest/zero offload/inference | Pass | Partner pending |
| llama CPU ARM64 | Yes | Official rolling CPU asset | Benchmark + GGUF inference | Tag/digest/zero offload/inference | Pass | Partner pending |
| llama CUDA x64 | Yes | Complete rolling app+cudart pair | Benchmark + GGUF inference | Tag/digests/backend/device/actual offload | Pass | Partner pending |
| llama CUDA ARM64 N1X | Yes | Complete rolling app+cudart pair | Benchmark + GGUF inference | Tag/digests/backend/device/actual offload | Pass | **Passed** |
| llama ROCm AMD x64 | Yes | Official rolling ROCm asset | Benchmark + GGUF inference | Tag/digest/backend/device/actual offload | Pass | Partner pending |
| llama SYCL Intel x64 | Yes | Official rolling SYCL asset | Benchmark + GGUF inference | Tag/digest/backend/device/actual offload | Pass | Partner pending |
| llama OpenVINO x64 | Yes | Official rolling OpenVINO asset | Benchmark + GGUF inference | Tag/digest/backend/device/actual offload | Pass | Partner pending |
| llama Vulkan x64 fallback | Yes | Official rolling Vulkan asset | Benchmark + GGUF inference | Explicit fallback/backend/device/offload | Pass | Partner pending |
| llama Adreno OpenCL ARM64 | Yes | Official rolling OpenCL asset | Benchmark + GGUF inference | Tag/digest/OpenCL/Adreno/actual offload | Pass | Partner pending |
| Foundry x64 | Yes | Architecture-native WinGet | Real catalog-model inference | Source-managed actual EP/device/fallback | Pass | Partner pending |
| Foundry ARM64 | Yes | Architecture-native WinGet | Real catalog-model inference | Source-managed actual EP/device/fallback | Pass | **Passed on N1X CPU EP** |
| Ollama x64 | Yes | Stable WinGet | Verified model + inference | Source-managed CPU/GPU allocation/backend | Pass | Partner pending |
| Ollama ARM64 | Yes | Official stable ZIP | Verified model + inference | Source-managed CPU/GPU allocation/backend | Pass | **Passed on N1X NVIDIA GPU** |

The executable source of truth is
`Workloads/_common/ai-catalog.psd1::CapabilityMatrix`. The shared unit suite
invokes every supported/source-managed resolver fixture and verifies its
acquisition identities, probe path, report evidence contract, and partner
command. Every `upstream-unavailable` cell must throw its cataloged blocker.

llama.cpp Auto resolution is supported NVIDIA CUDA → supported AMD ROCm →
supported Intel SYCL → Qualcomm Adreno OpenCL → x64 Vulkan → CPU. Intel SYCL
is preferred because the artifact directly exercises the Intel GPU and produces
device/offload evidence. OpenVINO remains an explicit x64 alternative for its
general inference backend; readiness requires the benchmark to identify the
OpenVINO backend and offloaded layers, and the flow does not claim NPU support.
All selected archives come from one rolling release, including both app and
cudart archives for CUDA. SHA-256 digests are required, verified archives are
cached under `%LOCALAPPDATA%\DevConfig\llama.cpp\asset-cache`, and the runtime
is replaced atomically. Acceptance reads the official `backends` JSON field and
requires actual `offloaded X/Y layers` diagnostics; the requested `-ngl` value
is never used as proof of acceleration. `gpu_info` supplies the physical device;
the structured `devices` value is the requested selector and must match an
explicit `-Device`.

### Universal partner hardware workflow

```powershell
gh pr checkout 98 --repo microsoft/WindowsDeveloperConfig
$ExpectedHead = gh pr view 98 --repo microsoft/WindowsDeveloperConfig `
  --json headRefOid --jq .headRefOid
if ((git rev-parse HEAD).Trim() -ne $ExpectedHead) {
  throw "PR #98 checkout does not match published head $ExpectedHead."
}
```

Then open elevated PowerShell in the repository root. Inventory the host and
use the plan/apply harness from the README's **Partner validation commands**
section. Each assigned flow must first write `<name>-plan.json`, stop on any
blocker, then write `<name>-final.json` and satisfy `result.ready=true`.

Assigned flow coverage:

| Partner device | Required flows |
| --- | --- |
| NVIDIA x64 | `cuda`; PyTorch `-Backend CUDA -RequireTriton`; llama.cpp `-Backend CUDA` |
| AMD x64 | PyTorch `-Backend ROCm`; native `rocm`; llama.cpp `-Backend ROCm` |
| Intel x64 GPU | PyTorch `-Backend XPU -RequireTriton`; `intel-ai -Device GPU -Profile OpenVINO`; `intel-ai -Device GPU -Profile Full`; llama.cpp `SYCL` and explicit `OpenVINO` |
| Intel x64 NPU | `intel-ai -Device NPU -Profile OpenVINO` only; XPU and SYCL are GPU paths |
| Qualcomm ARM64 | llama.cpp `-Backend OpenCL`; Foundry to record its source-managed actual EP/fallback |

Return `hardware.json`, every plan and final report, every plan and final
console log, and reboot requested/performed status. Review:

- host architecture, GPU/NPU model/vendor/driver;
- acquisition action/version/source/artifact/integrity/cache/install path;
- requested and selected backend/device/profile;
- acceptance marker and intended physical device;
- CUDA/ROCm runtime and kernel, PyTorch runtime/tensor/Triton, llama.cpp
  `backends`/`gpu_info`/actual offloaded layers, Foundry EP/fallback, or Ollama
  VRAM/allocation evidence as applicable;
- every warning and blocker.

`INSTALL_OK` alone is insufficient. A successful handoff requires
`result.ready=true` and acceptance evidence identifying the intended
device/backend. Foundry is source-managed and may truthfully report CPU fallback.

The workload implementation was qualified at `ec7fc5e`; subsequent commits may
contain only this partner documentation. The live PR head check above is the
authoritative checkout guard.

### Preview/rolling promotion metadata

`Workloads/_common/ai-catalog.psd1` is the single source of truth for maturity,
source identity, version policy, integrity validation, cache/install paths,
normal-channel gaps, expected stable channels, migration triggers, and cleanup.
The table below summarizes the non-normal channels. “Unconfirmed” means the
vendor has not announced a final package identity.

| Component | Vendor / architecture | Current identity | Resolver rule | Stable target | Evidence required to promote |
| --- | --- | --- | --- | --- | --- |
| CUDA ARM64 | NVIDIA / ARM64 | 13.4 Developer Preview EXE, pinned SHA-256 | Exact preview while `Nvidia.CUDA` lacks ARM64 | `Nvidia.CUDA` ARM64, unconfirmed | ARM64 manifest + compiled N1X kernel |
| PyTorch CUDA x64 | NVIDIA / x64 | stable 2.14 `cu126`/`cu130` wheel | Driver branch + compute capability select exact stable wheel | official PyTorch CUDA indexes | tensor + Triton vector-add |
| PyTorch CUDA ARM64 | NVIDIA / ARM64 | pinned 2.15 cu134 nightly wheel | Exact wheel/hash and CPython 3.13/N1X checks | official stable PyTorch ARM64 CUDA feed, unconfirmed | stable wheel + tensor/Triton acceptance |
| PyTorch ROCm | AMD / x64 | stable 2.13 ROCm 10 device-specific tuple | Exact supported GPU → `gfx` extra | AMD stable ROCm feed | AMD tensor + non-null HIP runtime |
| PyTorch XPU | Intel / x64 | stable 2.14 XPU tuple | Validated Intel GPU family | official PyTorch XPU index | XPU tensor + cold `torch.compile` |
| Triton Windows CUDA | NVIDIA / x64, ARM64 | `triton-windows==3.8.0.post28` | exact PyTorch-compatible community build | official Windows Triton package, unconfirmed | official package + vector-add kernel |
| Triton XPU | Intel / x64 | `triton-xpu==3.8.0` | exact PyTorch XPU-compatible tuple | official PyTorch XPU index | cold `torch.compile` on XPU |
| llama.cpp CUDA x64 | NVIDIA / x64 | newest complete CUDA 13.3/12.4 app+cudart set | Driver/capability-qualified exact pair from one release | backend-specific WinGet variant, unconfirmed | NVIDIA device + GPU layers + inference |
| llama.cpp CUDA ARM64 | NVIDIA / ARM64 | newest complete CUDA 13.4 app+cudart set | Qualified N1X Developer Preview pair | backend-specific WinGet variant, unconfirmed | N1X device + GPU layers + inference |
| llama.cpp ROCm x64 | AMD / x64 | newest ROCm 10.0 asset | Supported GPU/gfx target | backend-specific WinGet variant, unconfirmed | ROCm/AMD device + GPU layers + inference |
| llama.cpp SYCL / OpenVINO x64 | Intel/general / x64 | newest SYCL or OpenVINO 2026.3.1 asset | SYCL Auto for supported Intel GPU; OpenVINO explicit | backend-specific WinGet variants, unconfirmed | selected backend/device + GPU layers + inference |
| llama.cpp OpenCL Adreno ARM64 | Qualcomm / ARM64 | newest Adreno OpenCL asset | Detected Qualcomm/Adreno adapter | backend-specific WinGet variant, unconfirmed | OpenCL/Adreno + GPU layers + inference |
| llama.cpp Vulkan / CPU | Cross-vendor / x64, CPU / x64+ARM64 | newest backend-specific rolling asset | Vulkan only with loader/device; otherwise CPU | backend-specific WinGet variants, unconfirmed | exact backend and offload/fallback evidence |
| Foundry Local | cross-vendor / x64, ARM64 | `Microsoft.FoundryLocal` preview | latest applicable package | same ID at GA | Microsoft GA designation + provider/inference report |
| Ollama ARM64 | CPU/NVIDIA / ARM64 | latest stable official ARM64 ZIP | non-prerelease release asset with GitHub digest | current ARM64 WinGet package, ID unconfirmed | package catches release + API/GPU evidence |

AMD ROCm 10.0 and Intel OpenVINO/oneAPI use stable vendor channels. AMD's
normal channel is its stable ROCm feed (there is no confirmed WinGet ID);
Intel's normal channels are official PyPI packages and `Intel.OneAPI.Toolkit`.
Neither vendor publishes a native Windows ARM64 stack today.

| Component | Vendor / CPU arch | Maturity | Current source + identity | Resolver / version policy | Integrity | Cache → installed path | Why normal channel is insufficient | Expected final channel | Promotion evidence | Cleanup / upgrade |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CUDA x64 | NVIDIA / x64 | Stable | WinGet `Nvidia.CUDA` | Latest applicable stable | WinGet manifest hash + signature | WinGet → `%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v*` | N/A | `Nvidia.CUDA` | New package still compiles/runs kernel | WinGet upgrade / NVIDIA uninstall |
| CUDA ARM64 | NVIDIA / ARM64 | Developer preview | NVIDIA `cuda_13.4.0_windows_arm64.exe` | Exact 13.4.0 while WinGet lacks ARM64 | Pinned SHA-256 + NVIDIA signature | `%ProgramData%\WindowsDeveloperConfig\cache` → CUDA v13.4 | No ARM64 WinGet payload | `Nvidia.CUDA` ARM64, unconfirmed | ARM64 manifest and N1X kernel | Side-by-side qualify, then vendor uninstall old |
| PyTorch CUDA ARM64 | NVIDIA / ARM64 | Nightly preview | NVIDIA `torch-2.15.0.dev20260904+cu134-cp313-win_arm64.whl` | Exact qualified wheel | Pinned SHA-256 | local wheel cache → contained venv | Stable index lacks win_arm64 CUDA | Official PyTorch CUDA ARM64 feed, unconfirmed | Stable tensor + Triton kernel | Replace venv; prune old cache |
| PyTorch CUDA x64 | NVIDIA / x64 | Stable | official `cu126`/`cu130` index, torch 2.14 | Driver/capability-selected exact wheel | official index hashes/RECORD | pip cache → contained venv | N/A | official PyTorch CUDA index | tensor + Triton kernel | Replace venv |
| PyTorch ROCm | AMD / x64 | Stable | AMD feed: torch 2.13 ROCm 10 + device `gfx` extra, torchvision, torchaudio | Exact GPU-specific runtime tuple | AMD HTTPS + wheel RECORD | pip cache → contained venv | Default PyPI lacks AMD Windows build | AMD stable ROCm feed | HIP non-null + AMD tensor | Replace venv |
| PyTorch XPU | Intel / x64 | Stable | official XPU index: torch 2.14, torchvision 0.29 | Exact XPU tuple | official index hashes/RECORD | pip cache → contained venv | Default PyPI lacks Intel XPU build | official XPU index | Intel tensor + `torch.compile` | Replace venv |
| Triton Windows CUDA | NVIDIA / x64, ARM64 | Community | PyPI `triton-windows==3.8.0.post28` | Exact PyTorch-compatible tuple | TLS + wheel RECORD | pip cache → PyTorch venv | No general upstream Windows package | Official Windows Triton package, unconfirmed | Official package + vector-add | Replace venv |
| Triton XPU / `torch.compile` | Intel / x64 | Stable integrated | XPU index `triton-xpu==3.8.0` | Exact PyTorch XPU tuple | official index hashes/RECORD | pip cache → PyTorch venv | Standalone project documents Linux; Windows path is PyTorch integration | official XPU index | cold compile on actual Intel GPU | Replace venv |
| llama.cpp CUDA x64 | NVIDIA / x64 | Rolling | newest complete CUDA 13.3 or 12.4 app+cudart pair | Driver/capability-qualified exact pair from one release | GitHub asset SHA-256 digests | asset cache → runtime directory | WinGet maps only to Vulkan | backend-specific `ggml.llamacpp`, unconfirmed | NVIDIA device/GPU layers + inference | Reuse verified cache; atomic runtime replacement |
| llama.cpp CUDA ARM64 | NVIDIA / ARM64 | Rolling developer preview | newest complete CUDA 13.4 app+cudart pair | RTX Spark + driver 616+ exact pair | GitHub asset SHA-256 digests | asset cache → runtime directory | No ARM64 CUDA WinGet variant | backend-specific `ggml.llamacpp`, unconfirmed | N1X device/GPU layers + inference | Reuse verified cache; atomic runtime replacement |
| llama.cpp ROCm x64 | AMD / x64 | Rolling | newest ROCm 10.0 asset | Exact supported AMD GPU/gfx resolver | GitHub asset SHA-256 digest | asset cache → runtime directory | WinGet maps only to Vulkan | backend-specific `ggml.llamacpp`, unconfirmed | ROCm/AMD device/GPU layers + inference | Reuse verified cache; atomic runtime replacement |
| llama.cpp SYCL / OpenVINO x64 | Intel/general / x64 | Rolling | newest SYCL or OpenVINO 2026.3.1 asset | Supported Intel GPU selects SYCL; OpenVINO explicit | GitHub asset SHA-256 digest | asset cache → runtime directory | WinGet maps only to Vulkan | backend-specific `ggml.llamacpp`, unconfirmed | selected backend/device/GPU layers + inference | Reuse verified cache; atomic runtime replacement |
| llama.cpp OpenCL Adreno ARM64 | Qualcomm / ARM64 | Rolling | newest Adreno OpenCL asset | Exact detected Qualcomm/Adreno ARM64 path | GitHub asset SHA-256 digest | asset cache → runtime directory | No ARM64 Adreno WinGet variant | backend-specific `ggml.llamacpp`, unconfirmed | OpenCL/Adreno/GPU layers + inference | Reuse verified cache; atomic runtime replacement |
| llama.cpp Vulkan x64 | Cross-vendor / x64 | Rolling fallback | newest official Vulkan asset | Auto only after vendor-native paths; requires loader/device | GitHub asset SHA-256 digest | asset cache → runtime directory | WinGet cannot express backend alternatives | reliable Vulkan package variant | Vulkan backend/GPU layers + inference | Reuse verified cache; atomic runtime replacement |
| llama.cpp CPU x64/ARM64 | CPU / x64, ARM64 | Rolling fallback | newest official CPU asset | Explicit CPU or no qualified accelerator | GitHub asset SHA-256 digest | asset cache → runtime directory | WinGet lacks backend-selectable CPU/ARM64 | backend-specific `ggml.llamacpp`, unconfirmed | CPU backend, zero GPU layers, inference | Reuse verified cache; atomic runtime replacement |
| Foundry Local | Cross-vendor / x64, ARM64 | Preview | WinGet `Microsoft.FoundryLocal` | Latest applicable preview | WinGet MSIX hash/signature | Foundry cache → per-user MSIX | Product is preview | same ID at GA | GA declaration + variant/provider inference | WinGet upgrade; Foundry cache cleanup |
| Ollama ARM64 | CPU, NVIDIA / ARM64 | Stable direct | latest official `ollama-windows-arm64.zip` | Latest non-prerelease release | GitHub asset SHA-256 | resolver cache → `%LOCALAPPDATA%\DevConfig\ollama\runtime` | WinGet desktop is x64 and portable can lag | current ARM64 WinGet ID, unconfirmed | package current + API/GPU evidence | Atomic runtime replacement |
| AMD ROCm | AMD / x64 | Stable | AMD stable feed `rocm[...] == 10.0.0` | Exact supported GPU `gfx` tuple | Official HTTPS allowlist + wheel RECORD; feed has no SHA-256 fragments | pip cache → contained venv | No confirmed WinGet ID/default PyPI package | AMD stable feed; WinGet unconfirmed | newer Windows matrix + HIP kernel | Replace contained environment |
| Intel OpenVINO / oneAPI | Intel / x64 | Stable | PyPI OpenVINO 2026.3.1 tuple; WinGet `Intel.OneAPI.Toolkit` | Exact matched tuple / qualified stable package | wheel RECORD; WinGet hash/signature | pip/WinGet cache → contained venv/oneAPI root | N/A | same official channels | selected-device inference/SYCL kernel | Replace venv; WinGet upgrade |

### 2. Validate the DSC config without applying it (Windows)

`winget configure` has a `test` verb that evaluates each resource's
`TestScript` / test logic and reports whether the system is already in the
desired state — useful for "will this config do what I think?" without
actually installing anything:

```powershell
winget configure test --file ./Workloads/typescript/configuration.winget `
    --accept-configuration-agreements `
    --disable-interactivity
```

On a fresh machine this should report that `Node` and `InstallTypeScript` are
out of the desired state; on a machine where the flow has already been applied
it should report both as in the desired state.

### 3. Apply + verify one flow end-to-end (Windows)

This is exactly what CI does and is the definitive local test:

```powershell
# a) Apply the DSC config via the shim (this is what CI invokes).
./Workloads/typescript/install.ps1
# Expected tail of output: "INSTALL_OK: typescript"

# b) Build + run the hello-world and diff its stdout against expected.txt.
./tests/_harness/run-flow.ps1 -Id typescript `
    -Build 'tsc tests/typescript/hello.ts' `
    -Run   'node tests/typescript/hello.js' `
    -Expected tests/typescript/expected.txt
# Expected tail of output: "FLOW_OK: typescript"

# c) Re-run the install to prove idempotence — it should succeed again and
#    report no packages changed.
./Workloads/typescript/install.ps1
```

Swap `typescript` for `php` (and the matching build/run args from
[`manifest.yml`](../manifest.yml)) to verify the PHP flow the same way.

### 4. Drive every flow from the manifest (Windows)

If you're changing something shared (`Workloads/_common/*.ps1`, the harness,
or the manifest schema) and want to exercise every flow the way CI will:

```powershell
$flows = (ConvertFrom-Yaml (Get-Content -Raw ./manifest.yml)).flows |
    Where-Object { $_.os -contains 'windows' -and -not $_.manual_test }

foreach ($f in $flows) {
    Write-Host "=== $($f.id) ==="
    & $f.windows.install
    ./tests/_harness/run-flow.ps1 `
        -Id       $f.id `
        -Build    ($f.windows.build ?? '') `
        -Run      $f.windows.run `
        -Expected $f.windows.expected
}
```

`ConvertFrom-Yaml` comes from the `powershell-yaml` module
(`Install-Module powershell-yaml -Scope CurrentUser`). If you don't want that
dependency, just copy the build/run strings out of `manifest.yml` by hand.

### 5. Validating CI itself

To sanity-check a change to `.github/workflows/ci.yml` or `manifest.yml`
without a full CI round-trip, run `discover`'s Python block locally — it will
reject malformed flows with the same error CI would:

```bash
python3 - <<'PY'
import yaml, json
doc = yaml.safe_load(open("manifest.yml"))
for flow in doc.get("flows", []):
    for os_name in flow.get("os", []):
        spec = flow.get(os_name) or {}
        missing = [k for k in ("install", "run", "expected") if not spec.get(k)]
        assert not missing, f"{flow['id']}/{os_name} missing {missing}"
    print("OK:", flow["id"], flow.get("os"))
PY
```

## How to add a new language

Adding a language is a **data change**, not a workflow change:

1. Add a `configuration.winget` at `Workloads/<lang>/` describing the
   winget packages and any PowerShell (via `Microsoft.DSC.Transitional/RunCommandOnSet`
   or `PSDscResources/Script` resources) needed to reach the desired state.
   This file is the core artifact — it should be readable on its own and
   applyable with `winget configure`.
2. Add a thin `install.ps1` shim next to it that delegates to
   `Workloads/_common/apply-configuration.ps1` with the flow id, config
   path, and list of commands that must be on PATH afterwards. The shim ends
   with `INSTALL_OK: <lang>`, which CI asserts on.
3. Add a hello world under `tests/<lang>/` together with an `expected.txt`
   containing its exact stdout.
4. Append an entry to `manifest.yml` describing the build command, run
   command, and expected-output path for each supported OS.

That's it — `discover` in CI picks up the new flow automatically.

## How to add a hardware-aware AI workload

1. Add a PowerShell-native `Workloads/<id>/install.ps1`; do not add a
   `configuration.winget`.
2. Reuse `_common/direct-setup.ps1` for the PR #93 WinGet/retry/process/PATH
   contracts and `_common/ai-report.ps1` for structured output.
3. Put stable, preview, nightly, and rolling acquisition metadata in
   `_common/ai-catalog.psd1`. Include the normal-channel limitation and
   evidence-based promotion trigger.
4. Add `-PlanOnly`, an actionable unsupported result, and a real hardware
   workload acceptance. CLI/version checks are diagnostics, not acceptance.
5. Add unit tests for architecture/vendor selection, exact commands, channel
   promotion, idempotence, report fields, and unsupported combinations.
