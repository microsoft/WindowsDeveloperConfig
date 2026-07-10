# Dev Configuration

A WinGet Configuration (DSC) file that sets up a clean, lightweight, distraction-free developer workstation. The goal is a PC state that devs actually love using: no clutter, no noise, just the tools you need.

This mirrors the curated environment currently provided by Cloud PC, so developers get a consistent experience regardless of device.

The flow is a single DSC document (`dev-config.winget`) that handles everything end-to-end: elevation, the OS tweaks, the apps, the fonts, the shell prompt, and the WSL platform + Ubuntu install (including the reboot dance).

> **Author:** Hamza Usmani.

## Table of Contents

- [Goals](#goals)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [What this configures](#what-this-configures)
- [Configuration details](#configuration-details)
  - [Phase resources (elevation + WSL)](#phase-resources-elevation--wsl)
  - [Apps](#apps)
  - [Theme and OS](#theme-and-os)
  - [File Explorer](#file-explorer)
  - [Taskbar](#taskbar)
  - [Start, Search, Notifications](#start-search-notifications)
  - [Services and features](#services-and-features)
  - [Edge](#edge)
  - [Fonts](#fonts)
  - [Windows Terminal](#windows-terminal)
  - [PowerShell profile](#powershell-profile)
- [Customization](#customization)
- [Design decisions](#design-decisions)
- [Known caveats](#known-caveats)

---

## Goals

- **A PC devs actually want to use.** Clean Explorer, dark theme, no pop-ups, no recommendations, no widgets. Just your code and your tools.
- **Cloud PC parity.** Same tooling, OS settings, and policies as the current Cloud PC image.
- **One command.** `winget configure -f dev-config.winget --accept-configuration-agreements --disable-interactivity` takes a fresh Windows machine to fully ready, including WSL + Ubuntu (with an auto-resume across the required reboot).
- **Idempotent.** Safe to re-run on existing machines to apply updates or fix drift. Every resource has a `testScript` or DSC-native idempotency.

## Prerequisites

- Windows 11 (latest).
- `winget` with the DSC v3 processor available (the file uses `Microsoft.WinGet/Package`, `Microsoft.Windows/Registry`, and `Microsoft.DSC.Transitional/*`).
- Administrator rights — the `ElevationCheck` resource will auto-relaunch winget elevated via `Start-Process -Verb RunAs` if you started in an unelevated session, but you'll need to consent at the UAC prompt.
- The Microsoft Visual C++ Redistributable when invoking `winget` from a non-elevated environment. Without it, `winget configure` fails with an internal error. See [aka.ms/vcredist](https://aka.ms/vcredist) or install via winget (see the Usage callout below).
- The repo on disk. `winget configure` reads a local file path, and the bootstrap is what installs Git, so on a fresh machine you'll either `git clone` (if Git is already installed) or download the repo as a ZIP from GitHub and extract it before running.
- **Hardware virtualization must be available to the OS** before WSL can install. On bare metal, this means virtualization (VT-x / AMD-V) is enabled in BIOS/UEFI. Inside a VM, it means the host has exposed nested virtualization to the guest. See the Usage callout below.

## Usage

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

> [!IMPORTANT]
> **WSL needs hardware virtualization.** If virtualization isn't available to the OS, the `InstallUbuntu` step fails with `wsl --install ... failed with exit code -1`.
>
> - **On bare metal:** enable virtualization (VT-x / AMD-V) in your BIOS/UEFI. The exact label varies by vendor — check your motherboard or laptop manufacturer's documentation if you can't find it. Reboot into firmware settings, toggle it on, save, and reboot back into Windows.
> - **Inside a VM:** the host must expose nested virtualization to the guest. For a Hyper-V host, run this from an elevated PowerShell session **on the host** (with the guest VM powered off):
>
>   ```powershell
>   Set-VMProcessor -VMName <VM_NAME> -ExposeVirtualizationExtensions $true
>   ```
>
>   Other hypervisors have their own equivalent settings — check your hypervisor's documentation.

**Get the files first** (skip if you already have the repo locally):

```powershell
# Git already installed:
git clone https://github.com/microsoft/WindowsDeveloperConfig.git
cd WindowsDeveloperConfig\windows-dev-config

# Otherwise, download and extract the ZIP:
Invoke-WebRequest -Uri https://github.com/microsoft/WindowsDeveloperConfig/archive/refs/heads/main.zip -OutFile WindowsDeveloperConfig.zip
Expand-Archive .\WindowsDeveloperConfig.zip -DestinationPath .
cd .\WindowsDeveloperConfig-main\windows-dev-config
```

**Full setup (recommended):**

```powershell
winget configure -f dev-config.winget --accept-configuration-agreements --disable-interactivity
```

This is the canonical invocation documented in the header of `dev-config.winget`.

**What to expect:**

1. The first phase applies all OS tweaks, installs apps, installs Cascadia Code/Mono Nerd Fonts, and configures Windows Terminal and the PowerShell profile.
2. WSL platform components install; the DSC reboots the machine and registers a `RunOnce` resume.
3. After login, winget configure resumes automatically and installs the default Ubuntu distro.
4. Open Ubuntu from the Start menu to complete its first-launch setup (create a UNIX username and password).

The configuration is idempotent, so it is safe to re-run after reboot or at any later point.

## What this configures

- **14 apps** via winget (PowerShell 7, Git, GitHub CLI, GitHub Copilot CLI, VS Code, .NET SDK 10, Python 3.14, UV, Node.js LTS, NVM for Windows, Coreutils for Windows, Windows Application CLI, plus optional Oh My Posh and PowerToys).
- **WSL + Ubuntu**, installed via 3 transitional script resources that bracket a reboot (Phase 2/3/4 below).
- **~24 registry settings** for theme/OS, Explorer, Taskbar, Search, Start, Notifications, Edge, Sudo, and the Widget service.
- **Cascadia Code & Cascadia Mono Nerd Fonts** downloaded from the `microsoft/cascadia-code` GitHub release and registered per-user.
- **5 script resources** beyond the WSL phases:
  - `ElevationCheck` — re-launches winget elevated if not already admin.
  - `darkTheme` — applies the built-in `dark.theme` to switch to dark mode.
  - `InstallCascadiaCodeNerdFonts` — downloads and installs the Nerd Font variants of Cascadia Code/Mono.
  - `SetCascadiaNfAsDefault` — sets `Cascadia Mono NF` as the default font face in Windows Terminal's `settings.json`.
  - `ps7default` — sets PowerShell 7 as Windows Terminal's default profile.
  - `ohMyPoshProfileSet` — adds `oh-my-posh init pwsh | Invoke-Expression` to `$PROFILE` and dot-sources it.

---

## Configuration details

All resources are dscv3 (`$schema: .../DSC/main/schemas/2023/08/config/document.json`, `metadata.winget.processor.identifier: dscv3`). Every resource that touches HKLM or runs elevated tools depends on `ElevationCheck`.

Package resources use `Microsoft.WinGet/Package` with `source: winget` and `useLatest: true` (except `Python.Python.3.14`, `Microsoft.dotnet.SDK.10`, and `OpenJS.NodeJS.LTS`, which are pinned by id).

### Phase resources (elevation + WSL)

| Name | Type | What it does |
|------|------|--------------|
| `ElevationCheck` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | `testScript` checks `IsInRole(Administrator)`. If false, `setScript` re-invokes `winget configure --file <this> --accept-configuration-agreements --disable-interactivity --wait` via `Start-Process -Verb RunAs`, then throws so the unelevated session ends cleanly. |
| `InstallWslComponents` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | `testScript` probes for the `vmcompute` service (presence ⇒ Virtual Machine Platform is active). `setScript` runs `wsl --install --no-distribution`. |
| `RebootForVmp` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | Same `vmcompute` test. `setScript` registers `HKCU:\...\RunOnce\DSCConfigureResume` with the same `winget configure --file <this> --accept-configuration-agreements` command, then `Restart-Computer -Force` and throws so DSC stops the current run. |
| `InstallUbuntu` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | `testScript` runs `wsl --list --quiet` and returns true if any distro is already registered. `setScript` runs `wsl --install -d Ubuntu --no-launch`. |

All app resources that need WSL present depend on `InstallUbuntu` so the OS work happens before the reboot — but the WSL install is still part of the same `winget configure` invocation thanks to the RunOnce resume.

### Apps

| Resource name | Package id | Notes |
|---------------|-----------|-------|
| `PowerShell` | `Microsoft.PowerShell` | Direct dependency on `ElevationCheck`. |
| `Git` | `Git.Git` | Depends on `ElevationCheck` + `InstallUbuntu`. |
| `GitHubCLI` | `GitHub.Cli` | Depends on `Git` + `InstallUbuntu`. |
| `GitHubCopilot` | `GitHub.Copilot` | Depends on `Git` + `InstallUbuntu`. |
| `VSCode` | `Microsoft.VisualStudioCode` | |
| `DotnetSdk` | `Microsoft.dotnet.SDK.10` | Pinned to v10. |
| `Python` | `Python.Python.3.14` | Pinned to 3.14. |
| `UV` | `astral-sh.uv` | |
| `NodeJS` | `OpenJS.NodeJS.LTS` | Pinned to the LTS line (currently Node 24 LTS). |
| `nvmForNode` | `CoreyButler.NVMforWindows` | Node version manager for Windows. |
| `Coreutils` | `Microsoft.Coreutils` | Microsoft-maintained Coreutils for Windows. Command integration is handled by the package itself after install. |
| `OhMyPosh` | `JanDeDobbeleer.OhMyPosh` | Marked Optional in the comments. Triggers `ohMyPoshProfileSet`. |
| `winappCli` | `Microsoft.winappcli` | Windows Application CLI. |
| `PowerToys` | `Microsoft.PowerToys` | Marked Optional. Followed by `PowerToysAOT` which disables AOT notifications via registry. |

### Theme and OS

Dark theme is applied via a `RunCommandOnSet` resource named `darkTheme` (not via registry):

| Resource | Type | What it does |
|----------|------|--------------|
| `darkTheme` | `Microsoft.DSC.Transitional/RunCommandOnSet` | `Start-Process` on `C:\Windows\Resources\Themes\dark.theme`, sleeps 2 s, then stops `SystemSettings` so the Settings window doesn't linger. Depends on `PowerShell`. |

The remaining theme/OS entries below are `Microsoft.Windows/Registry`.

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Sudo enabled (inline mode) | `HKLM\...\Sudo\Enabled` | DWord `3` |
| Developer Mode | `HKLM\...\AppModelUnlock\AllowDevelopmentWithoutDevLicense` | DWord `1` |
| Long path support | `HKLM\...\FileSystem\LongPathsEnabled` | DWord `1` |
| Remote Desktop on | `HKLM\...\Terminal Server\fDenyTSConnections` | DWord `0` |

### File Explorer

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Show file extensions | `HKCU\...\Advanced\HideFileExt` | DWord `0` |
| Show hidden files | `HKCU\...\Advanced\Hidden` | DWord `1` |
| Full path in titlebar | `HKCU\...\Advanced\FullPathAddress` | DWord `1` |
| Open to This PC | `HKCU\...\Advanced\LaunchTo` | DWord `1` |
| Frequent folders off | `HKCU\...\Advanced\ShowFrequent` | DWord `0` |
| Frequent files off | `HKCU\...\Explorer\ShowRecent` | DWord `0` |
| Recommended/cloud files off | `HKCU\...\Explorer\ShowCloudFilesInQuickAccess` | DWord `0` |
| Git integration in Explorer | `HKCU\...\Advanced\NavPaneShowVersionControl` | DWord `1` |
| Tips/sync-provider notifications off | `HKCU\...\Advanced\ShowSyncProviderNotifications` | DWord `0` |

### Taskbar

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Widgets button hidden | `HKCU\...\Advanced\TaskbarDa` | DWord `0` |
| Bluetooth notification icon off | `HKCU\Control Panel\Bluetooth\Notification Area Icon` | DWord `0` |
| End Task on right-click | `HKCU\...\Advanced\TaskbarEndTask` | DWord `1` |

### Start, Search, Notifications

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Web search suggestions off | `HKCU\...\Policies\Explorer\DisableSearchBoxSuggestions` | DWord `1` |
| Search highlights off | `HKCU\...\SearchSettings\IsDynamicSearchBoxEnabled` | DWord `0` |
| Start menu recommendations off | `HKCU\...\Advanced\Start_Layout` | DWord `1` |
| Toast notifications off (Do Not Disturb) | `HKCU\...\Notifications\Settings\NOC_GLOBAL_SETTING_TOASTS_ENABLED` | DWord `0` |

### Services and features

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Widget service off (HKLM policy) | `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests` | DWord `0` |
| PowerToys AOT notifications off | `HKCU\...\Notifications\Settings\PowerToys\Enabled` | DWord `0` |

### Edge

HKLM policies, applied via `Microsoft.Windows/Registry`:

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| New tab blank | `HKLM\SOFTWARE\Policies\Microsoft\Edge\NewTabPageLocation` | String `about:blank` |
| First-run experience off | `HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience` | DWord `1` |

### Fonts

| Resource | Type | What it does |
|----------|------|--------------|
| `InstallCascadiaCodeNerdFonts` | `Microsoft.DSC.Transitional/RunCommandOnSet` | Downloads `CascadiaCode-2407.24.zip` from `microsoft/cascadia-code` GitHub Releases, extracts `CascadiaCodeNF.ttf` and `CascadiaMonoNF.ttf` to `%LOCALAPPDATA%\Microsoft\Windows\Fonts`, and registers each under `HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`. Per-user install — no admin required for this step. Depends on `PowerShell`. |

### Windows Terminal

| Resource | Type | What it does |
|----------|------|--------------|
| `SetCascadiaNfAsDefault` | `Microsoft.DSC.Transitional/RunCommandOnSet` | Locates Windows Terminal's `settings.json` (Store or unpackaged install), backs it up to `settings.json.bak`, and sets `profiles.defaults.font.face = "Cascadia Mono NF"`. Depends on `InstallCascadiaCodeNerdFonts`. |
| `ps7default` | `Microsoft.DSC.Transitional/RunCommandOnSet` | Invokes `pwsh.exe -NoProfile -NoLogo -Command ...` which reads `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`, finds the PowerShell 7 profile, and sets it as `defaultProfile`. Depends on `PowerShell`. |

### PowerShell profile

| Resource | Type | What it does |
|----------|------|--------------|
| `ohMyPoshProfileSet` | `Microsoft.DSC.Transitional/RunCommandOnSet` | Creates `$PROFILE` if missing and appends `oh-my-posh init pwsh | Invoke-Expression` (idempotent — uses `Select-String` to check first), then dot-sources `$PROFILE`. Depends on `OhMyPosh`. |

---

## Customization

- **Pick and choose packages.** Comment out any `Microsoft.WinGet/Package` block to skip that install — most have no `dependsOn` chain beyond `InstallUbuntu` (exceptions: `GitHubCLI` and `GitHubCopilot` depend on `Git`; `PowerToysAOT` depends on `PowerToys`; `ohMyPoshProfileSet` depends on `OhMyPosh`).
- **Pin or unpin versions.** Switch `id: Python.Python.3.14` (pinned) to `id: Python.Python.3` if you want to drift forward, or switch `OpenJS.NodeJS.LTS` to `OpenJS.NodeJS` for current. Vice versa for the unpinned packages.
- **Toggle registry values.** Most settings are `DWord: 0` or `DWord: 1`; flip the value to invert the behavior.
- **Re-enable commented-out tweaks.** `HideDesktopIcons` ships commented out (it over-fires on some user setups). Uncomment to enable.
- **Change the WSL distro.** Edit the `wsl --install -d Ubuntu --no-launch` line inside the `InstallUbuntu` resource.
- **Change the terminal font.** Edit `$fontFace = 'Cascadia Mono NF'` inside `SetCascadiaNfAsDefault`, or change the `$WantedFonts` array in `InstallCascadiaCodeNerdFonts` to install a different Cascadia variant.
- **Skip the dark theme step.** Comment out the `darkTheme` resource if you prefer light mode (or want to set it manually).

## Design decisions

| Decision | Rationale |
|----------|-----------|
| Single dscv3 document, no modules | Easier to reason about and easier to re-run. The whole flow is one `winget configure` call. |
| `Microsoft.Windows/Registry` everywhere instead of `Microsoft.Windows.Developer/*` or `Microsoft.Windows.Settings/WindowsSettings` | Direct registry control is reliable across Windows 11 builds and avoids dependencies on legacy resource modules. |
| `Microsoft.DSC.Transitional/WindowsPowerShellScript` (not `PSDscResources/Script`) | The dscv3 transitional resource is the supported equivalent under the new processor. |
| Self-relaunch elevated from `ElevationCheck` | A user can double-click into an unelevated shell and the DSC will UAC-prompt itself rather than failing. |
| Reboot + RunOnce inside the DSC | The DSC owns the reboot and the resume, so the user only invokes `winget configure` once. The throw after `Restart-Computer -Force` is required because `Restart-Computer` returns immediately after signalling shutdown; without the throw DSC would treat the resource as succeeded and continue. |
| `useLatest: true` on most packages | Cloud PC parity tracks "current" tools. Pinned ids (`Python.Python.3.14`, `Microsoft.dotnet.SDK.10`, `OpenJS.NodeJS.LTS`) are used where a major-version line matters. |
| Dark theme via `dark.theme` file (not registry) | Applying the shipped `.theme` file flips both `AppsUseLightTheme` and `SystemUsesLightTheme` *and* applies the matching color scheme/cursors atomically, which the broadcast-message dance you'd otherwise need from a registry-only approach often misses. |
| Per-user font install | Avoids requiring admin for the font step and keeps the font registration under `HKCU`, which is what modern Windows + Terminal expect. |
| `RunCommandOnSet` to mutate `settings.json` | Windows Terminal's settings are JSON-based and not registry-mapped; a small pwsh fragment is the cleanest way. |

## Known caveats

| Area | Caveat |
|------|--------|
| **`acceptAgreements` not on packages** | None of the `Microsoft.WinGet/Package` resources set `acceptAgreements: true`. The header comment compensates by passing `--accept-configuration-agreements` on the command line. |
| **WSL reboot** | `RebootForVmp` will hard-reboot the machine via `Restart-Computer -Force`. Save your work before running. The RunOnce key resumes the config on next login. |
| **Ubuntu first-launch** | After `InstallUbuntu`, you still need to open Ubuntu from the Start menu once to create a UNIX user. Nothing inside the distro is configured by this flow. |
| **`useLatest: true`** | Each run grabs the latest available version. Builds may differ between machines applying the config on different days. |
| **HKLM registry keys** | Sudo, the Widget service policy, Edge policies, Remote Desktop, Long Paths, and Developer Mode all live in HKLM. The `ElevationCheck` gate guarantees the run is elevated; without it these would silently fail. |
| **PowerToys AOT path** | `HKCU\...\Notifications\Settings\PowerToys\Enabled` targets a specific registry path that may change across PowerToys versions. |
| **Idempotency of WSL phases** | `InstallWslComponents` and `RebootForVmp` both test for `vmcompute`. Re-running after the reboot is a no-op for those resources. `InstallUbuntu` queries `wsl --list --quiet`, so it skips once any distro is registered. |
| **Pinned font release** | `InstallCascadiaCodeNerdFonts` hard-codes Cascadia Code release `2407.24` from `microsoft/cascadia-code`. Bump `$Version` to pick up newer releases. |
| **Windows Terminal settings overwrite** | `SetCascadiaNfAsDefault` and `ps7default` rewrite `settings.json` via `ConvertTo-Json`. `SetCascadiaNfAsDefault` writes a `settings.json.bak` first; `ps7default` does not. JSON comments will not survive the round-trip. |
| **`ohMyPoshProfileSet` runs `. $PROFILE`** | Dot-sourcing the profile inside `pwsh -NoProfile` can surface errors from the user's existing profile during DSC apply. |
| **`darkTheme` opens Settings briefly** | Applying `dark.theme` pops the Settings app open; the script kills it after 2 seconds. On slow machines the window may flash visibly. |
| **Currently commented out** | The `HideDesktopIcons` block lives in the file but is commented out. Uncomment to hide desktop icons. |
