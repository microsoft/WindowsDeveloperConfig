# Windows Dev Config

Set up a new Windows dev box in minutes, not hours. Pick a setup below, run one command, get back to building. Everything here is **idempotent** — safe to re-run any time, on any machine, in any state.

## Table of contents

- [Quick start](#quick-start)
- [Setup actions](#setup-actions)
- [Single workloads](#single-workloads)
- [Local AI scenario](#local-ai-scenario)
- [Step-by-step quick overview](#step-by-step-quick-overview)
- [Requirements](#requirements)
- [What it changes](#what-it-changes)
- [How it works](#how-it-works)
- [Running it other ways](#running-it-other-ways)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Uninstall and manual cleanup](#uninstall-and-manual-cleanup)
- [Customizing it](#customizing-it)
- [Known limitations](#known-limitations)
- [For contributors](#for-contributors)

---

## Quick start

Run this in Windows PowerShell 5.1 or PowerShell 7. Bootstrap requests elevation when needed:

> ⚠️ **Possible restart** WSL needs virtualization enabled, so save your work first; the script resumes right where it left off.
> ⚠️ **Up to 2 UAC prompts** (once to elevate, once after the WSL reboot)

### Standard experience
```powershell
irm https://aka.ms/devconfig/standard/setup.ps1 | iex
```
<details>
<summary><strong>Details on standard experience</strong></summary>

- **Dev tools:** Windows Terminal, PowerShell 7, Git, GitHub CLI, GitHub Copilot CLI, VS Code, .NET SDK 10, Python 3.14 + uv, Node.js LTS + nvm, Coreutils for Windows, Windows App CLI, Oh My Posh, and PowerToys.
- **Terminal:** PowerShell 7 as the default profile, Oh My Posh in your prompt, Cascadia Mono NF as the default font, and a GitHub Copilot profile in the dropdown.
- **Windows settings:** Dark theme, long paths, File Explorer defaults, Start/Search settings, and Do Not Disturb
- **WSL:** WSL platform + Ubuntu, including the restart and the automatic resume afterwards.
</details>

### Full experience
```powershell
irm https://aka.ms/devconfig/full/setup.ps1 | iex
```

<details>
<summary><strong>Details on full experience</strong></summary>

- **Everything from standard**
- **Windows settings:** Developer Mode, Sudo, widgets off, and Edge policies, additional Start/Search/System Tray settings
- **Remote Desktop:** Enabled and firewall settings set
</details>

### Uninstall for both full and standard experiences
```powershell
irm https://aka.ms/devconfig/standard/uninstall.ps1 | iex
```

<details>
<summary><strong>What the command does</strong></summary>

The AKA.ms links point to [`setup-full.ps1`](./setup-full.ps1) and [`setup-standard.ps1`](./setup-standard.ps1). If aka.ms is blocked on your network, use the raw URL instead:

```powershell
irm https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/windows-dev-config/setup-full.ps1 | iex
```

`irm` (`Invoke-RestMethod`) downloads [`setup-full.ps1`](./setup-full.ps1), which downloads and verifies [`bootstrap.ps1`](./bootstrap.ps1) from a pinned commit, then runs it. Bootstrap then:

1. Requests UAC consent if needed, using the pinned commit with no ref lookup.
2. Verifies the downloaded security helper, then downloads the repository ZIP into a protected temp directory.
3. Verifies the Microsoft signature on every `.ps1` in the repository-root `windows-dev-config/` folder.
4. Copies [`bootstrap.ps1`](./bootstrap.ps1), [`dev-config.ps1`](./dev-config.ps1), [`steps/`](./steps), and [`workloads/`](./workloads) to `%ProgramData%\CalmOS`, owned by Administrators/SYSTEM with read/execute for everyone else.
5. Rechecks permissions and signatures, unblocks files, cleans up temp downloads, and launches setup.

Files stay on disk so setup can resume after a reboot. Each entry point prefers its running shell's built-in modules, so switching between PowerShell 7 and Windows PowerShell doesn't break signature verification.

`-AllowUnsigned` selects `src/windows-dev-config/` and skips signature checks — bootstrap never picks unsigned source on its own.

</details>

## Setup actions with parameters
Both `bootstrap.ps1` and `dev-config.ps1` accept `-Action`:

| Action | Behavior |
| --- | --- |
| `Full` | Default. Applies the complete setup. |
| `Partial` | A subset of `Full`, with the exclusions below. |
| `Uninstall` | [Resets Full's settings and removes tools and Ubuntu data](#uninstall-and-manual-cleanup), even after Partial. |

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Action Partial
```

Replace `setup-full.ps1` with the chosen wrapper — short URLs point at these repository-root release files, not `src/`, and all three require `| iex`.

## Single workloads

The same engine can apply one developer workload instead of the whole workstation — same elevation, signature checks, PowerShell 7 switch, check/apply/verify steps, log, and summary.  More coming soon.

| Workload | Installs | One-liner |
| --- | --- | --- |
| `winui` | Developer Mode, PowerShell 7, .NET SDK 10, Windows App CLI, Visual Studio Community 2026 with the .NET desktop and WinUI application development workloads, and the WinUI `dotnet new` templates | `irm https://aka.ms/devconfig/winui/setup.ps1 \| iex` |
| `go` | Developer Mode, PowerShell 7, and the Go toolchain | `irm https://aka.ms/devconfig/go/setup.ps1 \| iex` |
| `rust` | PowerShell 7, Rustup, Visual Studio Community 2026 with the Desktop development with C++ workload (for the msvc toolchain's linker), and the stable Rust toolchain | `irm https://aka.ms/devconfig/rust/setup.ps1 \| iex` |
| `winappcli` | Developer Mode, PowerShell 7, .NET SDK 10, and the Windows App Development CLI | `irm https://aka.ms/devconfig/winappcli/setup.ps1 \| iex` |
| `dotnet` | Developer Mode, PowerShell 7, and .NET SDK 10 | `irm https://aka.ms/devconfig/dotnet/setup.ps1 \| iex` |
| `php` | PowerShell 7 and the PHP runtime/CLI | `irm https://aka.ms/devconfig/php/setup.ps1 \| iex` |

The short URL points at the signed wrapper [`Workloads/winui/setup.ps1`](../Workloads/winui/setup.ps1),
which verifies and runs `bootstrap.ps1 -Workload winui -Action Full`. To pick a workload with the
bootstrap directly, pass `-Workload`:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Workload winui
```

Workloads support `-Action Full` only for now. The WinUI workload adds its Visual Studio workloads to a Community 2026 install — next to any other edition, without upgrading one already there. Visual Studio must be closed while workloads are added; a restart requested by the VS Installer shows up in the summary.

## Local AI scenario

`-Scenario local-ai` is a separate product-level entry point. It does not run
the Full or Partial workstation setup. It detects AI hardware, installs the
matching contained PyTorch backend and compatible Triton when available, then
executes tensor and neural-network acceptance:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Scenario local-ai
# Expected: PYTORCH_READY ... then LOCAL_AI_SCENARIO_READY
```

Optional model runtimes are selected explicitly:

```powershell
& ([scriptblock]::Create((irm $url))) -Scenario local-ai -AiRuntime LlamaCpp
& ([scriptblock]::Create((irm $url))) -Scenario local-ai -AiRuntime Ollama
& ([scriptblock]::Create((irm $url))) -Scenario local-ai -AiRuntime Foundry
```

Windows ARM64 RTX Spark golden path:

```powershell
& ([scriptblock]::Create((irm $url))) `
  -Scenario local-ai -AiBackend Auto -RequireTriton -AiRuntime Ollama `
  -ReportRoot (Join-Path $env:TEMP 'devconfig-local-ai')
```

Expected readiness includes `PYTORCH_READY: backend=CUDA`, `TRITON_READY`,
`OLLAMA_READY`, and `LOCAL_AI_SCENARIO_READY`. Bootstrap is the remote verified
downloader/protected launcher. From a repository clone, use an elevated shell
and invoke `src\Workloads\local-ai\install.ps1` directly; `dev-config.ps1`
continues to represent the workstation setup engine.

Use `-PlanOnly -ReportRoot <directory>` to inspect hardware, selected backend,
transitive acquisitions, and blockers without installing. `-AiBackend` accepts
`Auto`, `CPU`, `CUDA`, `ROCm`, or `XPU`; `-RequireTriton` makes compatible
Triton execution mandatory. Drivers remain prerequisites and are not replaced.

Bootstrap downloads the complete scenario dependency tree, verifies every
Microsoft-signed PowerShell file and the signed hash manifest for non-PowerShell
inputs, copies the payload into an administrator-protected scenario directory,
reverifies it, and launches only `Workloads\local-ai\install.ps1`.
Explicit `-AllowUnsigned` scenario tests use
`%ProgramData%\CalmOS-Development`, keeping unsigned files out of the production
`%ProgramData%\CalmOS` tree.

All bootstrap modes stream setup output. Scenario elevation waits only for its
launcher so AI runtimes can keep running; workstation actions retain process-tree
waiting and their existing error handling.

## Step-by-step quick overview

Roughly **30 minutes** on a clean machine with a good connection, most of it spent downloading applications like Git, Python, Visual Studio Code, PowerToys, and Ubuntu.

| # | What happens | Your involvement |
| --- | --- | --- |
| 1 | The first UAC prompt appears | **Accept it.** Most of the settings are machine-wide and need Administrator. |
| 2 | PowerShell 7 is installed if it isn't already, and the setup restarts itself on it | None |
| 3 | Packages, Windows settings, fonts, Terminal, prompt, and Copilot are configured | None. Long silent stretches during big downloads are normal — a "still working" note prints every minute |
| 4 | WSL is installed. The machine warns you and **restarts after 10 seconds** | **Save your work before you start.** |
| 5 | You sign back in; a window opens and the second UAC prompt appears | **Accept it** to finish the run |
| 6 | A summary prints: how many things changed, how many were already fine | Press a key to close, or leave it — it closes itself after 15 minutes |

Afterwards, open **Ubuntu** from the Start menu once to create your Linux username and password. Some Explorer and taskbar changes appear after you sign out and back in.

## Requirements

- **Windows 11.** Built and tested against current Windows 11 releases. A few of the settings only exist on newer builds; on older ones those steps are skipped rather than failing the run. Windows 10 is not supported.
- **Administrator rights** on the machine, and the ability to accept both UAC prompts.
- **Internet access** to `github.com`, `raw.githubusercontent.com`, `codeload.github.com`, `release-assets.githubusercontent.com`, the PowerShell Gallery, and the winget package sources. Behind a proxy, the run needs your proxy configured for WinHTTP and for `winget`.
- **Hardware virtualization available to the OS** — WSL cannot install without it. On a physical machine that means VT-x / AMD-V enabled in BIOS/UEFI. In a VM it means the host has exposed nested virtualization to the guest. Everything except WSL still works without it; see [Troubleshooting](#troubleshooting).
- **About 15 GB of free disk space** for the full package set.

## How bootstrap and full experience works

### Packages

Installed silently via winget, with license agreements accepted. A flaky WinGet connection is repaired and retried automatically; if it still can't install a package, that one is flagged and skipped while everything else continues.

<details>
<summary><strong>WinGet retry and fallback details</strong></summary>

Setup checks the WinGet module's connection first — a failure triggers a repair and retry, then falls back to `winget.exe` if it can query packages; if neither works, setup stops with a repair message. Install and query retries happen up to three times on a recognized source failure; if recovery still fails, the remaining package operations are skipped and flagged for that run (other settings keep applying) — check your connection and WinGet source configuration, then re-run setup. Package-specific install failures retry on their own.

</details>

| Package | winget id |
| --- | --- |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| Intelligent Terminal | `Microsoft.IntelligentTerminal` |
| PowerShell 7 | `Microsoft.PowerShell` |
| Git | `Git.Git` |
| GitHub CLI | `GitHub.cli` |
| Azure CLI | `Microsoft.AzureCLI` |
| GitHub Copilot CLI | `GitHub.Copilot` |
| Visual Studio Code | `Microsoft.VisualStudioCode` |
| .NET SDK 10 | `Microsoft.DotNet.SDK.10` |
| Python 3.14 | `Python.Python.3.14` |
| Visual C++ Redistributable | `Microsoft.VCRedist.2015+.x64` or `Microsoft.VCRedist.2015+.arm64` |
| uv | `astral-sh.uv` |
| Node.js LTS | `OpenJS.NodeJS.LTS` |
| nvm for Windows | `CoreyButler.NVMforWindows` |
| Coreutils for Windows | `Microsoft.Coreutils` |
| Oh My Posh | `JanDeDobbeleer.OhMyPosh` |
| Windows App CLI | `Microsoft.WinAppCli` |
| PowerToys | `Microsoft.PowerToys` |

A package counts as done only when winget reports it installed **and** current, so a re-run also picks up available updates.

The Visual C++ runtime is installed before uv, matching Windows' native architecture.

<details>
<summary><strong>Windows registry settings</strong></summary>

**System** (`HKLM`, requires Administrator)

| Setting | Key | Value |
| --- | --- | --- |
| Sudo, inline mode | `SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo\Enabled` | `3` |
| Developer Mode | `SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense` | `1` |
| Win32 long paths | `SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled` | `1` |
| Remote Desktop allowed | `SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections` | `0` |

**File Explorer** (`HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`)

| Setting | Value name | Value |
| --- | --- | --- |
| Show file extensions | `Advanced\HideFileExt` | `0` |
| Show hidden files | `Advanced\Hidden` | `1` |
| Full path in the title bar | `CabinetState\FullPath` | `1` |
| Open Explorer to This PC | `Advanced\LaunchTo` | `1` |
| No frequent folders in Quick Access | `ShowFrequent` | `0` |
| No recent files in Quick Access | `ShowRecent` | `0` |
| No recommended or cloud files | `ShowCloudFilesInQuickAccess` | `0` |
| No sync-provider tips | `Advanced\ShowSyncProviderNotifications` | `0` |
| Details pane state | `Modules\GlobalSettings\DetailsContainer\DetailsContainer` | Binary `01 00 00 00 02 00 00 00` |

**Taskbar, Start, search and notifications**

| Setting | Key | Value |
| --- | --- | --- |
| Do Not Disturb (all toasts off) | `HKCU\...\Notifications\Settings\NOC_GLOBAL_SETTING_TOASTS_ENABLED` | `0` |
| Hide the Bluetooth tray icon | `HKCU\Control Panel\Bluetooth\Notification Area Icon` | `0` |
| "End Task" on taskbar right-click | `HKCU\...\Explorer\Advanced\TaskbarDeveloperSettings\TaskbarEndTask` | `1` |
| No web results in search | `HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions` | `1` |
| No search highlights | `HKCU\...\SearchSettings\IsDynamicSearchBoxEnabled` | `0` |
| No Start menu recommendations | `HKCU\...\Explorer\Advanced\Start_IrisRecommendations` | `0` |
| No Start menu account notifications | `HKCU\...\Explorer\Advanced\Start_AccountNotifications` | `0` |
| Widgets off | `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests` | `0` |
| No PowerToys always-on-top toasts | `HKCU\...\Notifications\Settings\PowerToys\Enabled` | `0` |

Widgets are turned off through OS policy. If Windows protects that policy, the step is flagged and setup continues.

**Microsoft Edge** (`HKLM\SOFTWARE\Policies\Microsoft\Edge`)

| Setting | Value name | Value |
| --- | --- | --- |
| Blank new tab page | `NewTabPageLocation` | `about:blank` |
| Skip the first-run experience | `HideFirstRunExperience` | `1` |

**Theme** (`HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize`)

| Setting | Value name | Value |
| --- | --- | --- |
| Dark mode for apps | `AppsUseLightTheme` | `0` |
| Dark mode for the system | `SystemUsesLightTheme` | `0` |

</details>

### Fonts, Terminal and prompt

- **Cascadia Code NF** and **Cascadia Mono NF** are downloaded from the pinned [`microsoft/cascadia-code`](https://github.com/microsoft/cascadia-code/releases) release `2407.24`, verified against a known SHA-256, and installed **for all users** under `%SystemRoot%\Fonts`. An earlier per-user copy left by a previous run is removed.
- **Windows Terminal** gets PowerShell 7 as its default profile. After font installation verifies, a one-time, per-user `RunOnce` update selects Cascadia Mono NF at the next sign-in, without elevation or another setup run. Until then, the current font stays selected so an open Terminal does not warn about a newly installed font. This also works when WSL needs no reboot. If font installation fails, setup flags it and keeps the current font, or uses Cascadia Mono if the missing NF font was already selected.
- **Terminal backups:** `settings.json.bak` preserves the original settings across setup, reboot/resume, and the next-sign-in font update. A font choice changed manually after setup is left alone.
- **Oh My Posh** runs only in Windows Terminal or non-elevated PowerShell 7 sessions, in both modes. Setup updates its block in `$PROFILE`. If other initialization is present, it leaves the profile unchanged and flags it for manual adjustment.
- A **GitHub Copilot** profile is added to Windows Terminal as a settings fragment in `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\DevConfig`, so it appears in the dropdown without editing your settings file.

### Developer extras

These are **best-effort**: they need the network and a PATH that has just been updated, so a failure is flagged in the summary rather than stopping the run.

- The **WinUI templates** for `dotnet new` (`Microsoft.WindowsAppSDK.WinUI.CSharp.Templates`).
- The **`microsoft/win-dev-skills`** marketplace and its **WinUI plugin**, registered with the GitHub Copilot CLI.

### WSL

- The WSL platform components, via `wsl --install --no-distribution`. If that isn't available, the `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux` Windows features are enabled directly with `dism.exe` instead.
- A restart, if one is needed — see [Reboot and resume](#reboot-and-resume).
- **Ubuntu**, via `wsl --install -d Ubuntu --no-launch`, falling back to `--web-download` if the Microsoft Store route doesn't complete. The distro's first-run welcome screen is suppressed; open Ubuntu from the Start menu to create your Linux user.

Nothing *inside* the distro is configured by this flow. For that, see [WSL Comfort](../wsl-comfort/readme.md).

Readiness and distro-list checks close standard input first, so a missing WSL runtime can't pause them at a prompt. Installation and update commands keep their normal console behavior.

## How it works

### Check, apply, verify

Every step checks first, applies only if needed, then checks again — `already OK` means nothing ran. A failed apply is an error, not a silent success. A failed **best-effort** step is **flagged** instead, and the run continues; the summary names every flagged step so it doesn't scroll past you.

A machine-wide lock (`Global\WindowsDevConfigSetup`) stops a second copy from running at the same time — it tells you to switch windows instead of fighting over the same installs.

### Reboot and resume

If a restart is needed, setup registers a scheduled task (**`WindowsDevConfigResume`**) that resumes the run at your next logon, then restarts after **10 seconds**. Sign in, accept the second UAC prompt, and it finishes with a combined summary. Only one restart is ever performed — if WSL still isn't usable afterward, the run stops and explains why rather than rebooting again.

### Logs

Setup writes `devconfig-log.txt` next to `dev-config.ps1` (normally `%ProgramData%\CalmOS`) and prints the path when it finishes. [Single workloads](#single-workloads) log to `<workload>-log.txt` in the same folder.

## Running it other ways

**Unsigned development.** On a test machine, record the setup user's current policy, then run these commands in both Windows PowerShell 5.1 and PowerShell 7:

```powershell
Get-ExecutionPolicy -List
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
```

`CurrentUser` affects all scripts for that user and survives reboot; `Process` does not. Restore the previous policy after testing. Group Policy takes precedence.

**From a clone, using unsigned source:**

```powershell
powershell.exe -NoProfile -File .\src\windows-dev-config\dev-config.ps1 -AllowUnsigned
```

Add [`-Action Partial`](#setup-actions) for the reduced setup, or [`-Workload winui`](#single-workloads) for a single workload.

**Pin a tag, or try a branch.** `-Ref` accepts a branch, tag, or full 40-character commit SHA. Bootstrap resolves branches and tags once through Git ref discovery so its downloads use the same commit without consuming the GitHub REST API quota. Abbreviated commit SHAs are not supported. Pass arguments with a script block, not `| iex`:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Ref 'v1.2.3'
```

**Test an unsigned branch.** `-AllowUnsigned` selects `src/windows-dev-config/` instead of the signed repository-root copy:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Ref 'my-branch' -AllowUnsigned
```

**Install without running the configuration.** Protecting the files still requires Administrator rights:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -NoLaunch
```

**Install somewhere else:** `-InstallRoot 'D:\tools\devconfig'`. Use an existing administrator-controlled parent and a location that survives reboot. User-owned paths, user-writable installations, and junctions are rejected.

**Already elevated and want it to stay that way:** `dev-config.ps1 -NoElevate` fails fast instead of prompting.

## Security

<details>
<summary><strong>What runs elevated</strong></summary>

The setup runs elevated after each UAC prompt. It needs Administrator for the `HKLM` settings, the WSL Windows features, and machine-wide package installs. The logon task itself runs at normal privilege, so it cannot silently elevate modified files.

</details>

<details>
<summary><strong>What it downloads, and from where</strong></summary>

GitHub (this repository, the pinned Cascadia Code release, and the pinned `microsoft/winget-cli` installer and dependencies), the PowerShell Gallery (`Microsoft.WinGet.Client`), the winget package sources, and the GitHub favicon used as the Copilot profile icon. Font and WinGet downloads are checked against pinned SHA-256 hashes. GitHub downloads can still be throttled even though bootstrap and WinGet setup avoid the REST API. A failed icon fetch is not treated as an error.

</details>

<details>
<summary><strong>Download retries</strong></summary>

Bootstrap's HTTP requests and the WinGet release downloads retry transient failures up to four times, with randomized exponential backoff honoring `Retry-After`, capped at two minutes of retry waiting per request. A server asking for a longer wait than remains fails the request rather than retrying early. Bootstrap stops if it can't fetch or verify required files; a failed WinGet update is flagged and setup continues with the existing installation. The initial launcher fetches aren't covered by this retry policy.

</details>

<details>
<summary><strong>Code signing</strong></summary>

Production requires valid Microsoft Corporation Authenticode signatures. Before execution, the elevation launcher verifies the bootstrap's signature and confirms the installed copy has the same hash. Bootstrap verifies its security helper before loading it and every payload `.ps1` before and after copying, including with `-NoLaunch`. Each production launch rechecks permissions and signatures before loading other helpers. Failed checks stop setup. `-AllowUnsigned` skips signature verification for source development.

</details>

<details>
<summary><strong>Web wrappers</strong></summary>

Each action wrapper verifies and executes the same downloaded bootstrap text, with no unsigned fallback. `irm | iex` does not verify the wrapper's own signature; it trusts the HTTPS endpoint. To verify the entry script too, download the wrapper to a file and check its Authenticode signature and Microsoft Corporation signer before running it.

</details>

<details>
<summary><strong>Protected files</strong></summary>

Administrators/SYSTEM own the setup and download directories and have write access. Ordinary users have read/execute access only. Unsafe permissions and reparse points are rejected, not repaired.

</details>

<details>
<summary><strong>Execution policy</strong></summary>

Production requests process-scoped `RemoteSigned` for every launch, including PowerShell 7 relaunches and reboot resume. Verified files are unblocked to avoid publisher-trust prompts. Organization policy wins: `AllSigned` may still prompt, `Restricted` blocks setup. Setup never changes saved policies or adds trusted publishers. `-AllowUnsigned` leaves execution policy unchanged.

</details>

<details>
<summary><strong>What it does not do</strong></summary>

It doesn't collect or send telemetry, doesn't sign you in to anything, doesn't change credentials or Windows Defender settings, and doesn't touch files in your user profile beyond the PowerShell profile and Windows Terminal settings described above.

</details>

## Troubleshooting

<details>
<summary><strong>Setup reports an unsafe installation directory</strong></summary>

Choose a new directory under `%ProgramData%` with `-InstallRoot`. Review an existing folder before removing it from an elevated terminal; do not use a folder containing unrelated files.

</details>

<details>
<summary><strong>The run stopped and said it needs Administrator</strong></summary>

The UAC prompt was declined. Nothing was changed. Run the command again and accept it, or start from a terminal that's already elevated.

</details>

<details>
<summary><strong>"Setup is already running in another window"</strong></summary>

Exactly what it says — switch to the other window. Two copies would fight over the same installs, so the full setup and single workloads share this lock. If you're sure nothing is running, the previous process didn't exit cleanly; sign out and back in, or restart, and try again.

</details>

<details>
<summary><strong>Some steps came back "flagged"</strong></summary>

Flagged means best-effort work that couldn't be completed or confirmed. The run finishes and names them in the summary. Everything else was applied.

The most common cause is a step that needs a package that hasn't finished registering yet — the WinUI templates need the .NET SDK on `PATH`, and the Copilot plugin steps need the GitHub Copilot CLI. **Run the command again**: the steps that already succeeded are skipped in seconds and only the flagged ones are retried.

</details>

<details>
<summary><strong>WSL fails, or Ubuntu doesn't install</strong></summary>

Almost always hardware virtualization not being available to the OS.

- **Physical machine:** enable virtualization (VT-x / AMD-V) in BIOS/UEFI. The label varies by vendor — check your manufacturer's documentation. Reboot into firmware settings, turn it on, save, and boot back into Windows.
- **Virtual machine:** the host has to expose nested virtualization to the guest. On a Hyper-V host, with the guest powered off:

  ```powershell
  Set-VMProcessor -VMName <VM_NAME> -ExposeVirtualizationExtensions $true
  ```

  Other hypervisors have their own equivalent.

Then run the setup again. Everything else stays applied; only the WSL steps are retried.

If virtualization is definitely on and WSL still won't activate after the restart, the run says so and stops rather than rebooting in a loop. The other likely cause is that the machine couldn't reach the WSL download.

</details>

<details>
<summary><strong>winget can't be updated</strong></summary>

The setup targets the public stable release pinned in [`steps/_winget.ps1`](steps/_winget.ps1). Older or missing installations use direct GitHub release downloads, with SHA-256 checks and Windows package-signature enforcement, working with either the PowerShell module or the built-in `winget` command. If it fails, update **App Installer** from the Microsoft Store, or install an official [WinGet release](https://github.com/microsoft/winget-cli/releases), then run the setup again.

This step is best-effort — a machine that can't be updated is flagged rather than stopped, and the rest of the run continues on whatever winget it has. Setup reuses installed dependencies that meet the required version for the same package name, publisher, and architecture: an installed version equal to or newer than the pin skips the update without a network lookup. RPC recovery re-registers the installed App Installer package locally and retries the package query; it does not download or downgrade a newer version.

To change the target release, update `DevConfigWinGetTargetVersion` and both asset hashes in `steps/_winget.ps1` together, then sign and publish the payload as usual.

</details>

<details>
<summary><strong>Nothing happened after the restart</strong></summary>

The resume task waits 30 seconds after logon before starting, then opens a window and requests UAC consent. Accept that prompt; the first checks after elevation are quiet, so give it a couple of minutes.

If nothing appears at all, check the task exists:

```powershell
Get-ScheduledTask -TaskName WindowsDevConfigResume
```

Either way, running the original command again is safe and picks up exactly where it left off.

</details>

<details>
<summary><strong>"Windows Terminal's settings file couldn't be read as JSON"</strong></summary>

Your `settings.json` has a syntax error, so the setup stopped rather than overwrite a file it couldn't understand. Fix or rename the file named in the message, then run the setup again.

</details>

<details>
<summary><strong>Downloads fail or time out</strong></summary>

The setup retries with backoff and raises TLS 1.2 for you, so this is usually a proxy. `winget` and WinHTTP each need to know about it:

```powershell
netsh winhttp show proxy
```

Configure your proxy for both, then run the setup again.

</details>

<details>
<summary><strong>Where do I look when none of the above fits?</strong></summary>

Read `devconfig-log.txt` next to `dev-config.ps1`, normally in `%ProgramData%\CalmOS`. Setup prints the path when it finishes.

Then please [open an issue](https://github.com/microsoft/WindowsDeveloperConfig/issues) with your Windows build (`winver`), the command you ran, and the relevant part of that log. Setup that fails on a real machine is a bug worth fixing.

</details>

## Uninstall and manual cleanup

Use the [uninstall command](#quick-start) from Quick start (from source, add `-AllowUnsigned`). It:

- **Permanently deletes `Ubuntu`** and its files, without confirmation.
- Reverts all of Full's settings and tools, regardless of which action set them up — previous settings are not restored.
- Flags failed or timed-out steps and keeps going; long-running removals show progress.

<details>
<summary><strong>What gets removed</strong></summary>

- **Settings:** disable Sudo, Developer Mode, and Remote Desktop; reset Explorer, Start, search, notification, Bluetooth tray, taskbar End Task, Widgets, Edge policies, long-path, and WSL first-run settings; select the unrestricted QuietHours profile and switch app/system themes to light.
- **Terminal:** cancel any pending next-sign-in font update; remove `defaultProfile`, `profiles.defaults`, PowerShell/Copilot/Ubuntu profile entries (including dynamically generated PowerShell entries), and the Copilot fragment.
- **Integrations:** remove the managed Oh My Posh profile block, WinUI template package, and win-dev-skills marketplace. Custom profile code and unrelated plugins are preserved.
- **Tools:** uv, NVM, the WinUI Copilot plugin, Node.js, Copilot, Python 3.14, Git, GitHub CLI, Oh My Posh, Azure CLI, Coreutils, .NET SDK 10, Intelligent Terminal, PowerToys, Visual Studio Code, Windows App CLI, and PowerShell 7.
- **Not removed:** fonts, the Visual C++ runtime, WinGet, Windows optional features, and setup files/logs under `%ProgramData%\CalmOS`.

</details>

### Additional manual cleanup

- **Packages:** `winget uninstall --id <id>` using the ids in [Packages](#packages).
- **Explorer, Start and search settings:** also in Settings and Explorer's Options dialog — sign out and back in to apply.
- **Windows Terminal:** restore the `settings.json.bak` written next to `settings.json`.
- **The Copilot Terminal profile:** delete `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\DevConfig`.
- **Ubuntu:** `wsl --unregister Ubuntu` — permanently deletes the distro's file system.
- **The setup itself:** delete `%ProgramData%\CalmOS` from an elevated terminal.

## Customizing it

Edit the files under `src\windows-dev-config` in your clone, then run the [unsigned-source command](#running-it-other-ways).

| To... | Edit |
| --- | --- |
| Add or remove a package | Add it to the catalog in [`steps/packages.ps1`](./steps/packages.ps1), then list or remove its name in the packages phase of [`workloads/devconfig.ps1`](./workloads/devconfig.ps1) |
| Change or drop a Windows setting | The shared `$tweaks` list in the matching `steps/registry-*.ps1` |
| Skip the Edge policies entirely | Remove the `edge.ps1` entry from the phase list in [`workloads/devconfig.ps1`](./workloads/devconfig.ps1) |
| Keep Remote Desktop off | Delete the `RemoteDesktop` entry in [`steps/registry-system.ps1`](./steps/registry-system.ps1) |
| Change the terminal font | `$Script:CascadiaDefaultFontFace` in [`steps/fonts.ps1`](./steps/fonts.ps1) |
| Install a different distro | `$Script:DevConfigWslDistributionName` in [`steps/wsl.ps1`](./steps/wsl.ps1) |
| Add something new | Copy the shape of any phase file: build steps with `New-DevConfigStep` and pass them to `Invoke-DevConfigSteps` |
| Add a single workload | See [Adding a workload](#adding-a-workload) |

A phase is just a file plus an entry in a workload's phase list. Files prefixed with `_` are shared helpers, not phases.

Setup and cleanup use the same phase files and definitions. Phases marked `Uninstall = $true` provide cleanup steps.
Package entries use `KeepOnUninstall`, `AdditionalUninstallIds`, `UninstallOrder`, and `InnoUninstall` for cleanup differences;
registry entries are reset by default. `New-DevConfigRegistryStep -Reset` applies `ResetValue` when specified;
otherwise it deletes only the named value.

## Known limitations

See [Setup actions](#setup-actions) and [What it changes](#what-it-changes) for full detail on any row below.

| Area | Detail |
| --- | --- |
| **Remote Desktop is enabled** | `fDenyTSConnections` is set to `0`, allowing incoming RDP. The firewall rule isn't opened, so this alone doesn't expose the machine to your network — but it's a real change to its posture. |
| **Two Edge settings become policy** | Written under `HKLM\SOFTWARE\Policies\Microsoft\Edge`; Edge reports "managed by your organization" and greys those two settings out. |
| **All notifications are turned off** | Do Not Disturb is enabled globally, not just for quiet hours, until you turn it back on. |
| **Node.js LTS and nvm-windows are both installed** | Two ways to manage Node — uninstall Node.js first if you want nvm to own the PATH entry. |
| **Uninstall is destructive** | Deletes `Ubuntu` and its files and removes targeted tools, including pre-existing installs. Previous settings aren't restored. |
| **One restart, always visible** | The WSL platform genuinely requires it. The setup warns you for 10 seconds and then restarts with `shutdown /r`. Save your work before you begin. |
| **Ubuntu's first launch is still manual** | You have to open Ubuntu once to create a Linux username and password. |
| **Package versions move** | Packages are installed at whatever winget currently publishes, so two machines set up on different days can differ. `Microsoft.DotNet.SDK.10` and `Python.Python.3.14` pin a major version and will need bumping as those age. |
| **The font release is pinned** | Cascadia Code `2407.24`, verified by hash. Newer releases need both the version and the hash updated in `steps/fonts.ps1`. |
| **Terminal settings lose their comments** | `settings.json` is round-tripped through JSON, so comments don't survive. A `.bak` is written first. |
| **No package selection at run time** | `Full` and `Partial` install all packages. There's no `-Skip` switch or selection prompt. |
| **No dry run** | There's no `-WhatIf`. The `already OK` output tells you what a re-run *would* skip, but only after the fact. |
| **Git and GitHub CLI are installed, not configured** | No `git config user.name`, no `gh auth login`. |
| **`%ProgramData%\CalmOS` stays behind** | Setup and its log remain for resume and reruns. Deleting them requires Administrator rights. |
| **Some changes need a sign-out** | Several Explorer and taskbar values are read by Explorer at logon. |

## For contributors

Source of truth for this flow is `src/windows-dev-config/`. The copy at the repository root is the Authenticode-signed release copy, regenerated by the sign pipeline — don't edit it directly.

See [`src/docs/windows-dev-config.md`](https://github.com/microsoft/WindowsDeveloperConfig/blob/main/src/docs/windows-dev-config.md) for the file layout, the phase list, publishing a release, and adding a workload.
