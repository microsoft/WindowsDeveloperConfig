# Windows Dev Config

*Turns a fresh Windows 11 machine into a clean, distraction-free developer workstation in one command.*

This flow installs the tools you'd install anyway, applies the Windows settings you'd change anyway, and sets up WSL + Ubuntu including the reboot in the middle. It is a set of PowerShell scripts: no configuration file to point at, no repo to clone, nothing to install first.

It is **idempotent** — every change is checked before it's made, so re-running it only fixes what has drifted. It is also **resumable** — if it fails, or you close the window, running it again picks up where it left off.

> **Original design and curation:** Hamza Usmani.

## Table of contents

- [Quick start](#quick-start)
- [Setup actions](#setup-actions)
- [What to expect](#what-to-expect)
- [Requirements](#requirements)
- [Before you run this](#before-you-run-this)
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

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url)))
```

You'll get one UAC prompt before setup and another after the restart.

Bootstrap avoids publisher-trust prompts by default. Organization policy can require them (`AllSigned`) or block setup (`Restricted`).

<details>
<summary><strong>What the command does</strong></summary>

`irm` (`Invoke-RestMethod`) downloads [`bootstrap.ps1`](./bootstrap.ps1). The script block runs it with any supplied switches. Bootstrap then:

1. Resolves the ref to a commit and requests UAC consent if needed.
2. Verifies the downloaded security helper, then downloads the repository ZIP into an administrator-protected temporary directory.
3. Verifies the Microsoft Corporation signature on every `.ps1` in the repository-root `windows-dev-config/` folder.
4. Copies [`bootstrap.ps1`](./bootstrap.ps1), [`dev-config.ps1`](./dev-config.ps1), and [`steps/`](./steps) to `%ProgramData%\CalmOS`. Administrators/SYSTEM own and can modify the files; ordinary users have read/execute access.
5. Rechecks permissions and signatures, unblocks files, removes temporary downloads, and launches setup.

Files stay on disk so setup can load its helpers and resume after reboot.

For elevation, the launcher downloads and verifies the bootstrap, installs it in the protected directory, and runs it with `-File`.

`-AllowUnsigned` selects `src/windows-dev-config/` and skips signature checks. Bootstrap never selects unsigned source automatically.

</details>

## Setup actions

Both `bootstrap.ps1` and `dev-config.ps1` accept `-Action`:

| Action | Behavior |
| ------ | -------- |
| `Full` | Default. Applies the complete setup. |
| `Partial` | A subset of `Full`, with the exclusions below. |
| `Uninstall` | [Resets settings and removes tools and Ubuntu data](#uninstall-and-manual-cleanup). |

`Partial` skips changes to Sudo, Developer Mode, Remote Desktop, Edge policies, Explorer's
recommended/cloud files, global notifications, the Bluetooth tray icon, web
search, search highlights, Widgets, and WinUI templates. It still
installs the WinUI Copilot plugin.

```powershell
$url = 'https://raw.githubusercontent.com/microsoft/WindowsDeveloperConfig/main/src/windows-dev-config/bootstrap.ps1'
& ([scriptblock]::Create((irm $url))) -Action Partial
```

The action is preserved across elevation, PowerShell relaunch, and reboot.
Skipped settings are not reverted.

## What to expect

Roughly **30 minutes** on a clean machine with a good connection, most of it spent downloading Visual Studio Code, the .NET SDK, PowerToys, and Ubuntu.

| # | What happens | Your involvement |
| - | ------------ | ---------------- |
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
- **Internet access** to `github.com`, `api.github.com`, `raw.githubusercontent.com`, the PowerShell Gallery, and the winget package sources. Behind a proxy, the run needs your proxy configured for WinHTTP and for `winget`.
- **Hardware virtualization available to the OS** — WSL cannot install without it. On a physical machine that means VT-x / AMD-V enabled in BIOS/UEFI. In a VM it means the host has exposed nested virtualization to the guest. Everything except WSL still works without it; see [Troubleshooting](#troubleshooting).
- **About 15 GB of free disk space** for the full package set.

You do **not** need Git, a repository clone, `winget configure`, the Visual C++ Redistributable, or PowerShell 7 beforehand. The flow handles all of those.

## Before you run this

See [Setup actions](#setup-actions) for what each action changes.

| Change | Why it might matter to you |
| ------ | -------------------------- |
| **Remote Desktop is enabled** | `fDenyTSConnections` is set to `0`, which allows incoming RDP sessions. The Windows Firewall rule is *not* opened, so this alone doesn't expose the machine to your network — but it is a real change to the machine's posture. |
| **Two Edge settings are applied as policy** | They're written under `HKLM\SOFTWARE\Policies\Microsoft\Edge`, so Edge will report "managed by your organization" and grey those two settings out in its UI. |
| **All notifications are turned off** | Do Not Disturb is enabled globally, not just for a quiet-hours window. Teams, Outlook, and everything else stop raising toasts until you turn it back on. |
| **Both Node.js LTS and nvm-windows are installed** | They are two different ways to manage Node. If you plan to use nvm, uninstall Node.js first so nvm owns the PATH entry. |
| **Windows Terminal's `settings.json` is rewritten** | A `settings.json.bak` is written next to it first, but any comments in your settings file are lost, because the file is round-tripped through JSON. If the file can't be parsed, the Terminal change is flagged and skipped, the file is left untouched, and the remaining phases continue. |
| **Uninstall is destructive cleanup** | Deletes `Ubuntu` and its files and removes targeted tools, including pre-existing installations. Previous settings are not restored. |

Every one of these is listed in full detail in [What it changes](#what-it-changes).

## What it changes

`Full` applies the setup below, skipping steps already in the desired state.

### Packages

Installed with winget from the `winget` source, silently, with agreements accepted:

| Package | winget id |
| ------- | --------- |
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
| Full path in the title bar | `CabinetState\FullPath` | `1` |
| Open Explorer to This PC | `Advanced\LaunchTo` | `1` |
| No frequent folders in Quick Access | `ShowFrequent` | `0` |
| No recent files in Quick Access | `ShowRecent` | `0` |
| No recommended or cloud files | `ShowCloudFilesInQuickAccess` | `0` |
| No sync-provider tips | `Advanced\ShowSyncProviderNotifications` | `0` |
| Details pane state | `Modules\GlobalSettings\DetailsContainer\DetailsContainer` | Binary `01 00 00 00 02 00 00 00` |

**Taskbar, Start, search and notifications**

| Setting | Key | Value |
| ------- | --- | ----- |
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

- **Cascadia Code NF** and **Cascadia Mono NF** are downloaded from the pinned [`microsoft/cascadia-code`](https://github.com/microsoft/cascadia-code/releases) release `2407.24`, verified against a known SHA-256, and installed **for all users** under `%SystemRoot%\Fonts`. An earlier per-user copy left by a previous run is removed.
- **Windows Terminal** gets Cascadia Mono NF as its default font face and PowerShell 7 as its default profile. `settings.json` is backed up to `settings.json.bak` before either change.
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

## How it works

### The phases

`Full` runs all phases below. `Partial` skips Edge and uses [fewer settings](#setup-actions).

| # | Phase | Notes |
| - | ----- | ----- |
| 1 | Getting ready | Confirms PowerShell 7, then updates winget to the latest public stable release |
| 2 | Packages | The packages above, plus the PowerToys notification setting |
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

Each step is counted once in the summary, including across a reboot.

### Elevation and PowerShell 7

Before configuring the machine, setup:

1. **Elevates** before downloading the payload. Declining UAC stops the run.
2. **Uses PowerShell 7**, installing it if needed for more reliable WinGet support. If installation fails, setup reports it and continues on Windows PowerShell 5.1.

A machine-wide lock (`Global\WindowsDevConfigSetup`) means a second copy won't start while one is running — it tells you to switch windows instead of letting two runs fight over the same installs.

### Reboot and resume

Enabling the WSL platform requires a restart. When one is needed, the setup:

1. Registers a scheduled task named **`WindowsDevConfigResume`** that runs at your next logon, as you, at normal privilege after a 30-second delay.
2. Saves its progress so far to `devconfig-tally.json`.
3. Prints a warning and restarts after **10 seconds**.

After you sign in, the task opens a window and Windows asks for fresh UAC consent before resuming elevated. Accept it to finish the run, print the combined summary for both halves, and remove the task. If Windows refuses the restart, the setup tells you and leaves the task registered — restart whenever you like and it still resumes.

Only one restart is ever performed. If WSL still isn't usable after it, the run stops and explains why rather than rebooting again.

### Logs

The transcript is **`devconfig-log.txt`** next to `dev-config.ps1`, normally `%ProgramData%\CalmOS\devconfig-log.txt`. Setup prints the path when it finishes.

The transcript is more verbose than the console on purpose: it records handled errors and raw command output that are deliberately kept off screen. Text in the log that isn't on your console is usually something the run recovered from.

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

Add [`-Action Partial`](#setup-actions) for the reduced setup.

**Pin a tag, or try a branch.** `-Ref` accepts a branch, tag, or commit SHA. Bootstrap resolves it once so its downloads use the same commit. Pass arguments with a script block, not `| iex`:

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

**What runs elevated.** The setup runs elevated after each UAC prompt. It needs Administrator for the `HKLM` settings, the WSL Windows features, and machine-wide package installs. The logon task itself runs at normal privilege, so it cannot silently elevate modified files.

**What it downloads, and from where.** GitHub (this repository, the pinned Cascadia Code release, which is checked against a SHA-256, and the latest `microsoft/winget-cli` release), the PowerShell Gallery (the `Microsoft.WinGet.Client` module), the winget package sources, and the GitHub favicon used as the Copilot profile icon. Failing to fetch the icon is not treated as an error, and neither is failing to look up the latest winget version.

**Code signing.** Production requires valid Microsoft Corporation Authenticode signatures. Before execution, the elevation launcher verifies the bootstrap's signature and confirms the installed copy has the same hash. Bootstrap verifies its security helper before loading it and every payload `.ps1` before and after copying, including with `-NoLaunch`. Each production launch rechecks permissions and signatures before loading other helpers. Failed checks stop setup. `-AllowUnsigned` skips signature verification for source development.

**Protected files.** Administrators/SYSTEM own the setup and download directories and have write access. Ordinary users have read/execute access only. Unsafe permissions and reparse points are rejected, not repaired.

**Execution policy.** Production requests process-scoped `RemoteSigned` for all launches, including PowerShell 7 relaunches and reboot resume. Verified files are unblocked to avoid publisher-trust prompts. Organization policy takes precedence: `AllSigned` may still prompt; `Restricted` blocks setup. Setup does not change saved policies or add trusted publishers. `-AllowUnsigned` leaves execution policy unchanged.

**What it does not do.** It doesn't collect or send telemetry, doesn't sign you in to anything, doesn't change credentials or Windows Defender settings, and doesn't touch files in your user profile beyond the PowerShell profile and Windows Terminal settings described above.

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
<summary><strong>winget can't be updated</strong></summary>

The setup updates winget to the latest [microsoft/winget-cli](https://github.com/microsoft/winget-cli/releases/latest) public stable release. If it can't — usually because the built-in `winget` command is being used and the PowerShell module isn't reachable — update **App Installer** from the Microsoft Store, or install the latest release directly, then run the setup again.

The step is best-effort, so a machine that can't be updated is flagged rather than stopped, and the rest of the run continues on whatever winget it has.

A winget delivered by the Store or by Windows itself can be *newer* than the latest GitHub stable release — the 1.30.x previews, for instance. That counts as up to date, not as behind. If the latest release can't be looked up at all, a working winget is left alone rather than flagged.

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

Run in an elevated PowerShell window:

```powershell
& "$env:ProgramData\CalmOS\dev-config.ps1" -Action Uninstall
```

From source: `.\src\windows-dev-config\dev-config.ps1 -AllowUnsigned -Action Uninstall`.
`bootstrap.ps1` also accepts `-Action Uninstall`. Cleanup uses Windows PowerShell to remove PowerShell 7.
Per-user tools are removed through temporary tasks in the same account's non-elevated, signed-in session.
Some uninstallers may request Administrator approval.

**Cleanup runs without confirmation and permanently deletes the `Ubuntu` distro and its files.**
It uninstalls WSL and the tools below, including pre-existing, machine-wide, and all-user MSIX installations.
It does not restore previous settings.

- **Settings:** reset targeted Explorer, Start, notification, taskbar End Task, long-path, and WSL first-run settings.
- **Terminal:** remove `defaultProfile`, `profiles.defaults`, PowerShell/Copilot/Ubuntu profile entries, and the Copilot fragment.
- **Tools:** remove uv executables, caches, and local data; NVM; the WinUI Copilot plugin; Node.js; Copilot; Python 3.14 and its launcher/install manager; Git; GitHub CLI; Oh My Posh; Azure CLI; Coreutils; .NET SDK 10; Intelligent Terminal; PowerToys; Visual Studio Code; Windows App CLI; and PowerShell 7.

Failed or timed-out steps are flagged; cleanup continues. Long-running commands show progress.
Unlisted settings, fonts, the Windows Terminal app, the Visual C++ runtime, and setup files remain.

Manual resets for other settings (`HKLM` requires elevation):

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

Additional manual cleanup:

- **Packages:** `winget uninstall --id <id>` using the ids in [Packages](#packages).
- **Explorer, Start and search settings:** all of them are also in Settings and Explorer's Options dialog. Sign out and back in for them to take effect.
- **Windows Terminal:** restore the `settings.json.bak` written next to `settings.json`.
- **The Copilot Terminal profile:** delete `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\DevConfig`.
- **The Oh My Posh prompt:** remove the `oh-my-posh init` block from your PowerShell 7 `$PROFILE`.
- **Ubuntu:** `wsl --unregister Ubuntu`. This permanently deletes the distro's file system.
- **The setup itself:** delete `%ProgramData%\CalmOS` from an elevated terminal.

## Customizing it

Edit the files under `src\windows-dev-config` in your clone, then run the [unsigned-source command](#running-it-other-ways).

| To... | Edit |
| ----- | ---- |
| Add or remove a package | The shared `$packages` list in [`steps/packages.ps1`](./steps/packages.ps1) |
| Change or drop a Windows setting | The shared `$tweaks` list in the matching `steps/registry-*.ps1` |
| Skip the Edge policies entirely | Remove `edge.ps1` from the `$phases` list in [`dev-config.ps1`](./dev-config.ps1) |
| Keep Remote Desktop off | Delete the `RemoteDesktop` entry in [`steps/registry-system.ps1`](./steps/registry-system.ps1) |
| Change the terminal font | `$Script:CascadiaDefaultFontFace` in [`steps/fonts.ps1`](./steps/fonts.ps1) |
| Install a different distro | `$Script:DevConfigWslDistributionName` in [`steps/wsl.ps1`](./steps/wsl.ps1) |
| Add something new | Copy the shape of any phase file: build steps with `New-DevConfigStep` and pass them to `Invoke-DevConfigSteps` |

A phase is just a file plus an entry in the `$phases` list. Files prefixed with `_` are shared helpers, not phases.

Setup and cleanup use the same phase files and definitions. Phases marked `Uninstall = $true` provide cleanup steps.
Package entries use `KeepOnUninstall`, `AdditionalUninstallIds`, and `UninstallOrder` for cleanup differences;
registry entries marked `ResetOnUninstall` are reset.
`New-DevConfigRegistryStep` builds registry steps; `-Reset` deletes only the named value.

## Known limitations

| Area | Detail |
| ---- | ------ |
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

Source of truth for this flow is `src/windows-dev-config/`. The copy at the repository root is the Authenticode-signed release copy, regenerated by the sign pipeline — don't edit it directly. See [`src/docs/development.md`](https://github.com/microsoft/WindowsDeveloperConfig/blob/main/src/docs/development.md#repo-layout-signed-vs-source).

| File | What it is |
| ---- | ---------- |
| `bootstrap.ps1` | Remote entry point: elevation, verified downloads, protected installation, and launch. |
| `dev-config.ps1` | The orchestrator: elevation, shell selection, run lock, logging, phases, and summary. |
| `steps/_step-runner.ps1` | The check/apply/verify engine, the tally, and the flag reporting. |
| `steps/_security.ps1` | Signature and directory-permission checks. Its signature is verified before loading unless `-AllowUnsigned` is used. |
| `steps/_*.ps1` | Shared helpers: elevation, reboot and resume, winget, registry, Terminal settings, retry, process execution, console. |
| `steps/<phase>.ps1` | One file per phase, each exporting a single `Invoke-<Name>Phase` function. |

Adding a phase means adding one file and one line in the `$phases` list. Adding a step to an existing phase means one `New-DevConfigStep` call. Keep every step's check cheap and side-effect free — it runs on every invocation, including the fast path where nothing needs doing.
