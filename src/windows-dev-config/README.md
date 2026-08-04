# Windows Dev Config

*Turns a fresh Windows 11 machine into a clean, distraction-free developer workstation in one command.*

This flow installs the tools you'd install anyway, applies the Windows settings you'd change anyway, and sets up WSL + Ubuntu including the reboot in the middle. It is a set of PowerShell scripts: no configuration file to point at, no repo to clone, nothing to install first.

It is **idempotent** — every change is checked before it's made, so re-running it only fixes what has drifted. It is also **resumable** — if it fails, or you close the window, running it again picks up where it left off.

> **Original design and curation:** Hamza Usmani.

## Table of contents

- [Quick start](#quick-start)
- [What to expect](#what-to-expect)
- [Requirements](#requirements)
- [Before you run this](#before-you-run-this)
- [What it changes](#what-it-changes)
- [How it works](#how-it-works)
- [Running it other ways](#running-it-other-ways)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Undoing it](#undoing-it)
- [Customizing it](#customizing-it)
- [Known limitations](#known-limitations)
- [For contributors](#for-contributors)

---

## Quick start

Open **any** PowerShell window — Windows PowerShell or PowerShell 7, elevated or not — and run:

```powershell
irm https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1 | iex
```

That's the whole thing. You'll get one UAC prompt, and the machine will restart once.

<details>
<summary><strong>What that command actually does</strong></summary>

`irm` (`Invoke-RestMethod`) downloads [`bootstrap.ps1`](./bootstrap.ps1) as text and `iex` (`Invoke-Expression`) runs it. The bootstrap then:

1. Downloads the repository as a ZIP from `github.com/microsoft/WindowsDeveloperConfig`.
2. Copies the setup — [`dev-config.ps1`](./dev-config.ps1) plus the [`steps/`](./steps) folder — into `%LOCALAPPDATA%\CalmOS`, deletes its temporary download folder, and starts the setup from there.

The setup is installed to disk rather than run from the pipe because it loads two dozen files from its own folder, relaunches itself elevated, and has to survive a reboot — none of which a piped-in string can do.

</details>

## What to expect

Roughly **30 minutes** on a clean machine with a good connection, most of it spent downloading Visual Studio Code, the .NET SDK, PowerToys, and Ubuntu.

| # | What happens | Your involvement |
| - | ------------ | ---------------- |
| 1 | A UAC prompt appears | **Accept it.** Most of the settings are machine-wide and need Administrator. |
| 2 | PowerShell 7 is installed if it isn't already, and the setup restarts itself on it | None |
| 3 | Ten phases run: packages, Windows settings, fonts, Terminal, prompt, Copilot | None. Long silent stretches during big downloads are normal — a "still working" note prints every minute |
| 4 | WSL is installed. The machine warns you and **restarts after 10 seconds** | **Save your work before you start.** |
| 5 | You sign back in; a window opens by itself and finishes the run | None |
| 6 | A summary prints: how many things changed, how many were already fine | Press a key to close, or leave it — it closes itself after 15 minutes |

Afterwards, open **Ubuntu** from the Start menu once to create your Linux username and password. Some Explorer and taskbar changes appear after you sign out and back in.

## Requirements

- **Windows 11.** Built and tested against current Windows 11 releases. A few of the settings only exist on newer builds; on older ones those steps are skipped rather than failing the run. Windows 10 is not supported.
- **Administrator rights** on the machine, and the ability to accept a UAC prompt.
- **Internet access** to `github.com`, `raw.githubusercontent.com`, the PowerShell Gallery, and the winget package sources. Behind a proxy, the run needs your proxy configured for WinHTTP and for `winget`.
- **Hardware virtualization available to the OS** — WSL cannot install without it. On a physical machine that means VT-x / AMD-V enabled in BIOS/UEFI. In a VM it means the host has exposed nested virtualization to the guest. Everything except WSL still works without it; see [Troubleshooting](#troubleshooting).
- **About 15 GB of free disk space** for the full package set.

You do **not** need Git, a repository clone, `winget configure`, the Visual C++ Redistributable, or PowerShell 7 beforehand. The flow handles all of those.

## Before you run this

This flow is opinionated, and a few of its choices are worth knowing about up front rather than discovering later.

| Change | Why it might matter to you |
| ------ | -------------------------- |
| **Remote Desktop is enabled** | `fDenyTSConnections` is set to `0`, which allows incoming RDP sessions. The Windows Firewall rule is *not* opened, so this alone doesn't expose the machine to your network — but it is a real change to the machine's posture. |
| **Two Edge settings are applied as policy** | They're written under `HKLM\SOFTWARE\Policies\Microsoft\Edge`, so Edge will report "managed by your organization" and grey those two settings out in its UI. |
| **All notifications are turned off** | Do Not Disturb is enabled globally, not just for a quiet-hours window. Teams, Outlook, and everything else stop raising toasts until you turn it back on. |
| **Both Node.js LTS and nvm-windows are installed** | They are two different ways to manage Node. If you plan to use nvm, uninstall Node.js first so nvm owns the PATH entry. |
| **Windows Terminal's `settings.json` is rewritten** | A `settings.json.bak` is written next to it first, but any comments in your settings file are lost, because the file is round-tripped through JSON. If the file can't be parsed the run stops and leaves it untouched. |
| **There's no uninstall** | Nothing that gets applied is reverted automatically. [Undoing it](#undoing-it) lists the manual reversals. |

Every one of these is listed in full detail in [What it changes](#what-it-changes).

## What it changes

51 individual steps across 11 phases. Each one is checked first and skipped if the machine is already in that state.

### Packages

Installed with winget from the `winget` source, silently, with agreements accepted:

| Package | winget id |
| ------- | --------- |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| PowerShell 7 | `Microsoft.PowerShell` |
| Git | `Git.Git` |
| GitHub CLI | `GitHub.cli` |
| GitHub Copilot CLI | `GitHub.Copilot` |
| Visual Studio Code | `Microsoft.VisualStudioCode` |
| .NET SDK 10 | `Microsoft.DotNet.SDK.10` |
| Python 3.14 | `Python.Python.3.14` |
| uv | `astral-sh.uv` |
| Node.js LTS | `OpenJS.NodeJS.LTS` |
| nvm for Windows | `CoreyButler.NVMforWindows` |
| Coreutils for Windows | `Microsoft.Coreutils` |
| Oh My Posh | `JanDeDobbeleer.OhMyPosh` |
| Windows App CLI | `Microsoft.WinAppCli` |
| PowerToys | `Microsoft.PowerToys` |

A package counts as done only when winget reports it installed **and** current, so a re-run also picks up available updates.

<details>
<summary><strong>Windows settings — all 25 registry values</strong></summary>

**System** (`HKLM`, requires Administrator)

| Setting | Key | Value |
| ------- | --- | ----- |
| Sudo, inline mode | `SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo\Enabled` | `3` |
| Developer Mode | `SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense` | `1` |
| Win32 long paths | `SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled` | `1` |
| Remote Desktop allowed | `SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections` | `0` |

**File Explorer** (`HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`)

| Setting | Value name | Value |
| ------- | ---------- | ----- |
| Show file extensions | `Advanced\HideFileExt` | `0` |
| Show hidden files | `Advanced\Hidden` | `1` |
| Full path in the title bar | `Advanced\FullPathAddress` | `1` |
| Open Explorer to This PC | `Advanced\LaunchTo` | `1` |
| No frequent folders in Quick Access | `Advanced\ShowFrequent` | `0` |
| No recent files in Quick Access | `ShowRecent` | `0` |
| No recommended or cloud files | `ShowCloudFilesInQuickAccess` | `0` |
| Git status columns in Explorer | `Advanced\NavPaneShowVersionControl` | `1` |
| No sync-provider tips | `Advanced\ShowSyncProviderNotifications` | `0` |

**Taskbar, Start, search and notifications**

| Setting | Key | Value |
| ------- | --- | ----- |
| Do Not Disturb (all toasts off) | `HKCU\...\Notifications\Settings\NOC_GLOBAL_SETTING_TOASTS_ENABLED` | `0` |
| Hide the Bluetooth tray icon | `HKCU\Control Panel\Bluetooth\Notification Area Icon` | `0` |
| "End Task" on taskbar right-click | `HKCU\...\Explorer\Advanced\TaskbarEndTask` | `1` |
| No web results in search | `HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions` | `1` |
| No search highlights | `HKCU\...\SearchSettings\IsDynamicSearchBoxEnabled` | `0` |
| No Start menu recommendations | `HKCU\...\Explorer\Advanced\Start_IrisRecommendations` | `0` |
| Widgets off | `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests` | `0` |
| No PowerToys always-on-top toasts | `HKCU\...\Notifications\Settings\PowerToys\Enabled` | `0` |

Widgets are turned off through the OS policy value because the per-user taskbar icon value no longer takes effect on Windows 11 24H2 and later.

**Microsoft Edge** (`HKLM\SOFTWARE\Policies\Microsoft\Edge`)

| Setting | Value name | Value |
| ------- | ---------- | ----- |
| Blank new tab page | `NewTabPageLocation` | `about:blank` |
| Skip the first-run experience | `HideFirstRunExperience` | `1` |

**Theme** (`HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize`)

| Setting | Value name | Value |
| ------- | ---------- | ----- |
| Dark mode for apps | `AppsUseLightTheme` | `0` |
| Dark mode for the system | `SystemUsesLightTheme` | `0` |

</details>

### Fonts, Terminal and prompt

- **Cascadia Code NF** and **Cascadia Mono NF** are downloaded from the pinned [`microsoft/cascadia-code`](https://github.com/microsoft/cascadia-code/releases) release `2407.24`, verified against a known SHA-256, and installed **per-user** under `%LOCALAPPDATA%\Microsoft\Windows\Fonts`.
- **Windows Terminal** gets Cascadia Mono NF as its default font face and PowerShell 7 as its default profile. `settings.json` is backed up to `settings.json.bak` before either change.
- **Oh My Posh** is initialized from your PowerShell 7 `$PROFILE`. If an `oh-my-posh init` line is already there, nothing is added.
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

## How it works

### The phases

| # | Phase | Notes |
| - | ----- | ----- |
| 1 | Getting ready | Confirms PowerShell 7 and a winget new enough to drive non-interactively (1.6.0+), repairing winget if not |
| 2 | Packages | The 15 packages above, plus the PowerToys notification setting |
| 3 | System settings | Sudo, Developer Mode, long paths, Remote Desktop |
| 4 | File Explorer tweaks | |
| 5 | Taskbar, search & start tweaks | |
| 6 | Microsoft Edge tweaks | |
| 7 | Fonts | |
| 8 | Windows Terminal | |
| 9 | PowerShell profile | |
| 10 | GitHub Copilot | The Terminal profile, WinUI templates, and the Copilot CLI plugin — all best-effort |
| 11 | WSL + Ubuntu | Last on purpose, so its restart happens after everything else is done |

### Check, apply, verify

Every step is a triple: a check, an apply, and the same check again.

- If the check passes first time, the step prints `already OK` and nothing runs.
- If the apply runs but the check still fails afterwards, that's an error — not a silent success.
- Steps that aren't worth stopping the whole run for are marked **best-effort**. If one of those fails it's reported as **flagged**, the run continues, and the summary names it at the end so it doesn't scroll past you.

That's why the totals in the summary can add up to more than 51: the tally is saved across the reboot and carried into the resumed run, which re-checks every step it already did. Steps counted before the restart are counted again when they're confirmed after it.

### Elevation and PowerShell 7

The setup relaunches itself twice before doing any work:

1. **Elevated**, via UAC, if it wasn't already. Declining the prompt stops the run cleanly without changing anything.
2. **On PowerShell 7**, installing it first if necessary. The WinGet PowerShell module behaves more consistently there than on Windows PowerShell 5.1. If PowerShell 7 can't be installed the run continues on Windows PowerShell and says so.

A machine-wide lock (`Global\WindowsDevConfigSetup`) means a second copy won't start while one is running — it tells you to switch windows instead of letting two runs fight over the same installs.

### Reboot and resume

Enabling the WSL platform requires a restart. When one is needed, the setup:

1. Registers a scheduled task named **`WindowsDevConfigResume`** that runs at your next logon, as you, elevated, after a 30-second delay.
2. Saves its progress so far to `devconfig-tally.json`.
3. Prints a warning and restarts after **10 seconds**.

After you sign in, the task opens a window, finishes the run, prints the combined summary for both halves, and removes itself. If Windows refuses the restart, the setup tells you and leaves the task registered — restart whenever you like and it still resumes.

Only one restart is ever performed. If WSL still isn't usable after it, the run stops and explains why rather than rebooting again.

### Logs

A full transcript is written to **`devconfig-log.txt`** next to `dev-config.ps1` — so `%LOCALAPPDATA%\CalmOS\devconfig-log.txt` for the one-liner. The path is printed at the end of every run.

The transcript is more verbose than the console on purpose: it records handled errors and raw command output that are deliberately kept off screen. Text in the log that isn't on your console is usually something the run recovered from.

## Running it other ways

**From a clone, with the repo already on disk:**

```powershell
.\src\windows-dev-config\dev-config.ps1
```

**Pin a tag, or try a branch.** `-Ref` takes a branch, tag, or commit SHA. Passing arguments needs the script-block form rather than `| iex`:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Ref 'v1.2.3'
```

**Download it but don't run it**, so you can read it first:

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -NoLaunch
```

**Install somewhere else:** `-InstallRoot 'D:\tools\devconfig'`. The location has to survive the reboot, so avoid `%TEMP%`.

**Already elevated and want it to stay that way:** `dev-config.ps1 -NoElevate` fails fast instead of prompting.

## Security

**What runs elevated.** The whole setup, after the single UAC prompt. It needs Administrator for the `HKLM` settings, the WSL Windows features, and machine-wide package installs.

**What it downloads, and from where.** GitHub (this repository, and the pinned Cascadia Code release, which is checked against a SHA-256), the PowerShell Gallery (the `Microsoft.WinGet.Client` module), the winget package sources, and the GitHub favicon used as the Copilot profile icon. Failing to fetch the icon is not treated as an error.

**Code signing.** The release pipeline Authenticode-signs every `.ps1` in this repository with a Microsoft certificate and publishes the signed copies at the repository root. Whichever address you fetch the bootstrap from, it installs the signed copy of the setup when the ref you asked for has one, and tells you in its output when it falls back to the source copy instead.

**What it does not do.** It doesn't collect or send telemetry, doesn't sign you in to anything, doesn't change credentials or Windows Defender settings, and doesn't touch files in your user profile beyond the PowerShell profile and Windows Terminal settings described above.

## Troubleshooting

<details>
<summary><strong>The run stopped and said it needs Administrator</strong></summary>

The UAC prompt was declined. Nothing was changed. Run the command again and accept it, or start from a terminal that's already elevated.

</details>

<details>
<summary><strong>"Calm OS setup is already running in another window"</strong></summary>

Exactly what it says — switch to the other window. Two copies would fight over the same installs. If you're sure nothing is running, the previous process didn't exit cleanly; sign out and back in, or restart, and try again.

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
<summary><strong>"WinGet is older than 1.6.0" or winget can't be updated</strong></summary>

The setup needs a winget that supports non-interactive installs, and tries to repair or update it. If it can't — usually because the built-in `winget` command is being used and the PowerShell module isn't reachable — update **App Installer** from the Microsoft Store, or install the latest release from [microsoft/winget-cli](https://github.com/microsoft/winget-cli/releases/latest), then run the setup again.

</details>

<details>
<summary><strong>Nothing happened after the restart</strong></summary>

The resume task waits 30 seconds after logon before starting, and the first thing it does is re-check what's already done, which is quiet. Give it a couple of minutes.

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

`devconfig-log.txt`, in the same folder as `dev-config.ps1` (`%LOCALAPPDATA%\CalmOS` when you used the one-liner). The path is printed at the end of every run.

Then please [open an issue](https://github.com/microsoft/WindowsDeveloperConfig/issues) with your Windows build (`winver`), the command you ran, and the relevant part of that log. Setup that fails on a real machine is a bug worth fixing.

</details>

## Undoing it

There is no automatic undo, and the setup never removes anything on its own. The reversals below are the ones most people ask about. Registry changes under `HKLM` need an elevated prompt.

```powershell
# Remote Desktop off again
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 1

# Drop the two Edge policies (removes "managed by your organization" for them)
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' NewTabPageLocation, HideFirstRunExperience

# Notifications back on
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' NOC_GLOBAL_SETTING_TOASTS_ENABLED 1

# Widgets back on
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' AllowNewsAndInterests

# Back to light mode
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme 1
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' SystemUsesLightTheme 1
```

Everything else:

- **Packages:** `winget uninstall --id <id>` using the ids in [Packages](#packages).
- **Explorer, Start and search settings:** all of them are also in Settings and Explorer's Options dialog. Sign out and back in for them to take effect.
- **Windows Terminal:** restore the `settings.json.bak` written next to `settings.json`.
- **The Copilot Terminal profile:** delete `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\DevConfig`.
- **The Oh My Posh prompt:** remove the `oh-my-posh init` block from your PowerShell 7 `$PROFILE`.
- **Ubuntu:** `wsl --unregister Ubuntu`. This permanently deletes the distro's file system.
- **The setup itself:** delete `%LOCALAPPDATA%\CalmOS`.

## Customizing it

Everything lives in a named file under [`steps/`](./steps), so changing what runs is a local edit rather than a fork of a large document. Take a copy of the repository, edit, and run `dev-config.ps1` directly.

| To... | Edit |
| ----- | ---- |
| Add or remove a package | The `$packages` list in [`steps/packages.ps1`](./steps/packages.ps1) |
| Change or drop a Windows setting | The `$tweaks` list in the matching `steps/registry-*.ps1` |
| Skip the Edge policies entirely | Remove `edge.ps1` from the `$phases` list in [`dev-config.ps1`](./dev-config.ps1) |
| Keep Remote Desktop off | Delete the `RemoteDesktop` entry in [`steps/registry-system.ps1`](./steps/registry-system.ps1) |
| Change the terminal font | `$Script:CascadiaDefaultFontFace` in [`steps/fonts.ps1`](./steps/fonts.ps1) |
| Install a different distro | The `wsl --install -d Ubuntu` arguments in [`steps/wsl.ps1`](./steps/wsl.ps1) |
| Add something new | Copy the shape of any phase file: build steps with `New-DevConfigStep` and pass them to `Invoke-DevConfigSteps` |

A phase is just a file plus an entry in the `$phases` list. Files prefixed with `_` are shared helpers, not phases.

## Known limitations

| Area | Detail |
| ---- | ------ |
| **One restart, always visible** | The WSL platform genuinely requires it. The setup warns you for 10 seconds and then restarts with `Restart-Computer -Force`. Save your work before you begin. |
| **Ubuntu's first launch is still manual** | You have to open Ubuntu once to create a Linux username and password. |
| **Package versions move** | Packages are installed at whatever winget currently publishes, so two machines set up on different days can differ. `Microsoft.DotNet.SDK.10` and `Python.Python.3.14` pin a major version and will need bumping as those age. |
| **The font release is pinned** | Cascadia Code `2407.24`, verified by hash. Newer releases need both the version and the hash updated in `steps/fonts.ps1`. |
| **Terminal settings lose their comments** | `settings.json` is round-tripped through JSON, so comments don't survive. A `.bak` is written first. |
| **No package selection at run time** | It's the full set or a local edit. There's no `-Skip` switch and no prompt. |
| **No dry run** | There's no `-WhatIf`. The `already OK` output tells you what a re-run *would* skip, but only after the fact. |
| **Git and GitHub CLI are installed, not configured** | No `git config user.name`, no `gh auth login`. |
| **`%LOCALAPPDATA%\CalmOS` stays behind** | The installed copy and its log are left in place so a resumed or repeated run works. Delete it when you're done. |
| **Some changes need a sign-out** | Several Explorer and taskbar values are read by Explorer at logon. |

## For contributors

Source of truth for this flow is `src/windows-dev-config/`. The copy at the repository root is the Authenticode-signed release copy, regenerated by the sign pipeline — don't edit it directly. See [`src/docs/development.md`](https://github.com/microsoft/WindowsDeveloperConfig/blob/main/src/docs/development.md#repo-layout-signed-vs-source).

| File | What it is |
| ---- | ---------- |
| `bootstrap.ps1` | The remote entry point. Downloads, resolves signed-versus-source, installs, launches. |
| `dev-config.ps1` | The orchestrator. Elevation, PowerShell 7, run lock, logging, the phase list, the summary. |
| `steps/_step-runner.ps1` | The check/apply/verify engine, the tally, and the flag reporting. |
| `steps/_*.ps1` | Shared helpers: elevation, reboot and resume, winget, registry, Terminal settings, retry, process execution, console. |
| `steps/<phase>.ps1` | One file per phase, each exporting a single `Invoke-<Name>Phase` function. |

Adding a phase means adding one file and one line in the `$phases` list. Adding a step to an existing phase means one `New-DevConfigStep` call. Keep every step's check cheap and side-effect free — it runs on every invocation, including the fast path where nothing needs doing.
