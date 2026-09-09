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
| Windows Dev Config | 🙋 manual     | A full distraction-free workstation, in PowerShell: 15 apps + 24 registry values + fonts + Windows Terminal + WSL + Ubuntu (see [`windows-dev-config/README.md`](../windows-dev-config/README.md)) |
| NVIDIA CUDA       | 🙋 manual     | `Nvidia.CUDA` x64 or checksum/signature-pinned 13.4 ARM64 preview + MSVC + GPU kernel |
| AMD ROCm / HIP    | 🙋 manual     | ROCm Core SDK 10.0 on supported Windows x64 AMD GPUs + compiled HIP kernel |
| Intel AI          | 🙋 manual     | OpenVINO device inference; optional oneAPI/SYCL toolkit and GPU kernel |
| Foundry Local     | 🙋 manual     | `Microsoft.FoundryLocal` architecture-native WinML package + Qwen3 inference; no CUDA dependency |
| PyTorch           | 🙋 manual     | `Python.Python.3.13` + private CPU/CUDA/ROCm/XPU environment + supported Triton provider |
| llama.cpp         | 🙋 manual     | `ggml.llamacpp` x64/Vulkan or SHA-256-verified upstream ARM64 CPU/CUDA release + pinned GGUF |
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
  llama.cpp/       # x64 WinGet or verified ARM64 release + pinned GGUF inference
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

**End users**: follow the [top-level README](../../README.md). Windows Dev Config's `bootstrap.ps1` verifies Microsoft signatures and installs to `%ProgramData%\CalmOS` with Administrator/SYSTEM-only write access. It requests process-scoped `RemoteSigned` without adding trusted publishers. Organization-enforced `AllSigned` may still prompt. For development, `-AllowUnsigned` uses `src/windows-dev-config/` without signature checks.

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
| CUDA | Current stable `Nvidia.CUDA` + MSVC | Checksum- and Authenticode-verified NVIDIA CUDA 13.4 Developer Preview + ARM64 MSVC | Compile and execute `smoke.cu`; `-SkipWorkloadSmoke` opts out |
| ROCm / HIP | AMD stable ROCm 10.0 feed on supported Radeon/Ryzen AI GPUs | Unsupported | Compile and execute `hip-smoke.cpp`; exact GPU maps to a published `gfx` target |
| Intel AI | OpenVINO CPU/GPU/NPU; optional oneAPI/SYCL GPU tooling | Unsupported | Generated OpenVINO model executes on requested device; Full profile also runs a SYCL kernel |
| Foundry | WinGet x64 WinML package | WinGet ARM64 WinML package | Download `qwen3-0.6b` (~593 MB) and generate a marker; CUDA is never assumed |
| PyTorch | CPU, NVIDIA CUDA, AMD ROCm, Intel XPU | Stable CPU, or pinned NVIDIA CUDA 13.4 preview wheel for CPython 3.13/RTX Spark | Tensor operation reports exact device; Triton runs only for supported CUDA/XPU stacks |
| llama.cpp | WinGet Vulkan package | Paginated rolling-release discovery for verified CPU or paired CUDA 13.4 + cudart archives | Pinned Qwen3-0.6B Q4_K_M GGUF (~397 MB) generates a grammar-constrained marker |
| Ollama | Current WinGet desktop package | Current verified official ARM64 release ZIP | Official `qwen3:0.6b` (~522 MB) blob hash verification + structured inference |

PyTorch's environment is
`$env:LOCALAPPDATA\DevConfig\pytorch\.venv`. Auto selection never installs the
standalone CUDA Toolkit: PyTorch wheels carry their runtime. An explicit
`-Backend CUDA` fails if `nvidia-smi`, the driver branch, architecture, or wheel
compatibility is insufficient. Use `-RequireTriton` when Triton is mandatory or
`-SkipTriton` to disable it.

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
```

Current real-hardware coverage:

| Host | Validated workloads |
| --- | --- |
| Windows 11 ARM64 build 28120, NVIDIA RTX Spark N1X, driver 616.62 | CUDA 13.4 kernel; PyTorch cu134 tensor; Triton vector-add; Foundry qwen3-0.6b inference; llama.cpp CUDA inference; Ollama qwen3:0.6b at 100% GPU |
| Supported Windows x64 AMD GPU | Partner run pending: ROCm/HIP kernel and PyTorch ROCm tensor |
| Supported Windows x64 Intel GPU/NPU | Partner run pending: OpenVINO selected-device inference, optional SYCL kernel, PyTorch XPU/torch.compile |

### Preview/rolling promotion metadata

`Workloads/_common/ai-catalog.psd1` is the single source of truth for maturity,
source identity, version policy, integrity validation, cache/install paths,
normal-channel gaps, expected stable channels, migration triggers, and cleanup.
The table below summarizes the non-normal channels. “Unconfirmed” means the
vendor has not announced a final package identity.

| Component | Vendor / architecture | Current identity | Resolver rule | Stable target | Evidence required to promote |
| --- | --- | --- | --- | --- | --- |
| CUDA ARM64 | NVIDIA / ARM64 | 13.4 Developer Preview EXE, pinned SHA-256 | Exact preview while `Nvidia.CUDA` lacks ARM64 | `Nvidia.CUDA` ARM64, unconfirmed | ARM64 manifest + compiled N1X kernel |
| PyTorch CUDA ARM64 | NVIDIA / ARM64 | pinned 2.15 cu134 nightly wheel | Exact wheel/hash and CPython 3.13/N1X checks | official stable PyTorch ARM64 CUDA feed, unconfirmed | stable wheel + tensor/Triton acceptance |
| Triton Windows | NVIDIA / x64, ARM64 | `triton-windows==3.8.0.post28` | exact PyTorch-compatible community build | official Windows Triton package, unconfirmed | official package + vector-add kernel |
| llama.cpp ARM64 | NVIDIA/Qualcomm/CPU | newest complete `bNNNNN` asset set | exact backend patterns; all assets from one release | matching `ggml.llamacpp` backend or unconfirmed | package architecture/backend + benchmark/inference |
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
| Triton Windows | NVIDIA / x64, ARM64 | Community | PyPI `triton-windows==3.8.0.post28` | Exact PyTorch-compatible tuple | TLS + wheel RECORD | pip cache → PyTorch venv | No general upstream Windows package | Official Windows Triton package, unconfirmed | Official package + vector-add | Replace venv |
| llama.cpp ARM64 | NVIDIA, Qualcomm, CPU / ARM64 | Rolling | newest complete ggml-org `bNNNNN` release asset set | Backend-specific patterns, one release | GitHub asset SHA-256 | resolver runtime cache → runtime directory | WinGet lacks ARM64 variants | matching `ggml.llamacpp` package or unconfirmed | package backend + inference/benchmark | Atomic runtime replacement |
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
