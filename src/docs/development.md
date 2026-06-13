# WindowsDevSetupScripts — Developer Guide

> 👋 **Just want to run something?** See the
> [top-level README](../../README.md). This file is the contributor /
> CI / "how the sausage gets made" guide.

Opinionated, CI-validated configurations for bootstrapping developer
toolchains and Windows-desktop personalities using `winget` /
`winget configure`.

On Windows the **core artifact of each flow is a [winget DSC configuration
file](https://learn.microsoft.com/windows/package-manager/configuration/)**
(`configuration.winget` for language toolchains, `dev-config.winget` for the
Calm OS flow) — a declarative, idempotent description of the machine state
required for that flow. Where winget alone is not enough (e.g. `npm install
--global typescript`, registry tweaks, or a `RunOnce` reboot dance) the
configuration calls a DSC `Script` / `RunCommandOnSet` / `Registry`
resource, so everything the flow needs lives in one YAML file. A small
`install.ps1` shim next to it applies the config with `winget configure`
and handles session-level glue (PATH refresh, CI sentinel).

Every flow is **exercised on a real GitHub-hosted runner** on every push, pull
request, and nightly: the DSC config is applied, then a canonical "hello
world" is built and executed, and its stdout is diffed against a checked-in
expected output. If a flow's hello world prints the right thing, we know the
configuration actually produced a working toolchain.

## Supported flows

Each flow's `configuration.winget` (or `dev-config.winget` for Calm OS)
is the source of truth for what gets installed; the table below
summarizes it for quick scanning. Flows marked **manual** are excluded
from the automated CI matrix (they need an interactive desktop session
or pull multi-GB workloads we don't want to chew minutes on), but are
still verified end-to-end on demand and surfaced in the Command Palette
extension.

| Flow              | CI status     | Installs                                                                                |
| ----------------- | ------------- | --------------------------------------------------------------------------------------- |
| TypeScript        | ✅ automated   | `OpenJS.NodeJS.LTS` + `npm install -g typescript`                                       |
| PHP               | ✅ automated   | `PHP.PHP.8.5`                                                                           |
| .NET              | ✅ automated   | `Microsoft.DotNet.SDK.10`                                                               |
| Go                | ✅ automated   | `GoLang.Go` (rolling — winget publishes Go unversioned)                                 |
| Java              | ✅ automated   | `Microsoft.OpenJDK.25`                                                                  |
| Rust              | ✅ automated   | `Rustlang.Rustup` (then `rustup default stable`)                                        |
| Python            | ✅ automated   | `Python.Python.3.14`, `astral-sh.uv`                                                    |
| PowerShell        | ✅ automated   | `Microsoft.PowerShell`, `Microsoft.VisualStudioCode`, VS Code PowerShell/Pester extensions + PSScriptAnalyzer settings |
| WinForms          | 🙋 manual     | `Microsoft.DotNet.SDK.10` + the .NET desktop workload (multi-GB; manual to spare CI minutes) |
| WinUI 3           | 🙋 manual     | `Microsoft.DotNet.SDK.10`, `Microsoft.VisualStudio.Community`, `Microsoft.WinAppCLI` + WinUI/Universal/ManagedDesktop VS workloads |
| Calm OS           | 🙋 manual     | A full distraction-free workstation: apps + ~24 registry tweaks + WSL + Ubuntu (see [`windows-dev-config/README.md`](../windows-dev-config/README.md)) |
| Comfort Shell     | 🙋 manual     | WSL distro + zsh/bash + starship + modern CLI bundle + Cascadia Code Nerd Font + themed Windows Terminal profile (see [`wsl-comfort/readme.md`](../wsl-comfort/readme.md)) |

See [`manifest.yml`](../manifest.yml) for the canonical declarative
list (paths, build/run commands, onboarding URLs).

## Command Palette extension

A [PowerToys Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview)
extension lives under [`future/cmdpal/`](../future/cmdpal/). It reads the same
`manifest.yml` as CI and lets you browse + launch any flow without remembering
which `configuration.winget` to point `winget` at.

The UX metadata each flow needs (`name`, `description`, `category`, `tags`,
`icon`, `onboardingUrl`) is colocated with the CI fields in `manifest.yml` so
there is one source of truth. See [`future/cmdpal/README.md`](../future/cmdpal/README.md)
for build + configuration details.

## Repository layout

```
Workloads/
  _common/         # shared PowerShell shim helpers (retry, refresh PATH, preflight, assert-winget-configure, apply-configuration)
  typescript/      # configuration.winget (core) + install.ps1 (thin shim)
  php/             # configuration.winget (core) + install.ps1 (thin shim)
  python/          # configuration.winget (core) + install.ps1 (thin shim)
  dotnet/          # configuration.winget (core) + install.ps1 (thin shim)
  go/              # configuration.winget (core) + install.ps1 (thin shim)
  java/            # configuration.winget (core) + install.ps1 (thin shim)
  rust/            # configuration.winget (core) + install.ps1 (thin shim)
  winforms/        # configuration.winget (core) + install.ps1 (thin shim)
  winui/           # configuration.winget (core) + install.ps1 (thin shim)
windows-dev-config/    # Calm OS — dev-config.winget (single-file DSC) + install.ps1 + README.md
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

**End users**: the commands in the top-level [README](../../README.md) point at the **top-level signed copies** on purpose. If you're following the README on a Windows box you don't need to know `src/` exists. Every `winget configure -f .\windows-dev-config\dev-config.winget`-style invocation in the README is correct as written.

**Contributors**: edit `src/`. The top-level paths are **regenerated** by [`.pipelines/OneBranch.SignAndPackage.yml`](../../.pipelines/OneBranch.SignAndPackage.yml), which Authenticode-signs every `src/**/*.ps1` and ships them (plus the `.winget` configs and the manifest) as the release artifact. The signed copies were merged into `main` from the `signed` branch in [PR #6](https://github.com/microsoft/WindowsDeveloperConfig/pull/6). A change to a `src/` script becomes a new signed top-level copy on the next sign cycle, not at PR merge, so the two can briefly disagree on a script's body until that cycle runs.

**CI**: GitHub Actions ([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)) runs the **unsigned `src/` copies** (e.g. `./src/Workloads/_common/preflight.ps1`). This is intentional: CI exercises what contributors edit; signing is a release-time concern, not a build-time one.

**Don't**:

- Don't edit a top-level signed copy directly. The next sign cycle will overwrite it, and the cycle signs `src/`, not the top level.
- Don't expect the two trees to be byte-identical. The signed copies carry an Authenticode signature block (`# SIG # Begin signature block` … `# SIG # End signature block`); the bodies above that marker should match what's in `src/`. They will diverge for the window between a `src/` change landing on `main` and the next sign cycle catching up.
- Don't add a third copy of anything. Both copies exist for one reason only (to ship signed PS1s without losing the unsigned source), and any new flow or shared script lives only in `src/` until the sign pipeline mirrors it.

## Prerequisites (Windows)

Every flow — and the [Command Palette extension](../future/cmdpal/) — installs
toolchains through `winget configure`. That subcommand must be available on
your machine before anything in this repo can succeed:

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
