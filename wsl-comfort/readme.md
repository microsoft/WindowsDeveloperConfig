# WSL Comfort Shell 😎

A two-part installer that turns a fresh Windows + WSL machine into a cozy, opinionated-but-configurable shell: an Ubuntu distro running zsh + starship + modern CLI tools, surfaced through a themed Windows Terminal profile in a Cascadia Code Nerd Font. Every component is opt-in — pick the parts you want and skip the rest.

The Windows half (`install.ps1`) handles WSL, the distro, the font, and the terminal profile. The Linux half (`comfort-shell-bootstrap.sh`) runs inside the distro and does all the shell customization. They are designed to be runnable independently — the bootstrap is a standalone script you can scp onto any Ubuntu host and run by itself.

## Table of Contents

- [Goals](#goals)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [What this configures](#what-this-configures)
- [Scripts](#scripts)
- [install.ps1 (Windows side)](#installps1-windows-side)
  - [Step-by-step](#step-by-step)
  - [Parameters](#parameters)
  - [Reboot + auto-resume](#reboot--auto-resume)
- [comfort-shell-bootstrap.sh (Linux side)](#comfort-shell-bootstrapsh-linux-side)
  - [Step-by-step](#step-by-step-1)
  - [Options](#options)
  - [Skel mode (running as root)](#skel-mode-running-as-root)
- [Customization](#customization)
- [Design decisions](#design-decisions)
- [Known caveats](#known-caveats)

---

## Goals

- **Plenty of user options.** Pick zsh or bash; opt in or out of starship, the modern CLI bundle (`fzf`, `rg`, `fd`, `bat`, `eza`, `zoxide`), clipboard/`open` shims (`pbcopy`, `pbpaste`, `open`), Homebrew, and the git defaults — independently per flag, or in bulk with `--minimal`. Interactive runs prompt you for each toggle; `--non-interactive` accepts the defaults.
- **One command end-to-end.** `.\install.ps1` from a fresh Windows machine takes you to a fully configured, themed Windows Terminal profile — including the WSL platform install, distro install, font, and reboot dance.
- **Idempotent.** Safe to re-run. Managed blocks in dotfiles are replaced in place, the WT fragment is rewritten with a deterministic GUID, and already-installed packages are skipped.
- **Standalone halves.** `comfort-shell-bootstrap.sh` does not require `install.ps1` — drop it on any Ubuntu host (WSL or not) and it works.

## Prerequisites

- Windows 11 with **Windows Terminal** (`wt.exe`) installed and on PATH. The installer hard-fails if it can't find `wt.exe`.
- Internet access for the WSL distro download, Homebrew, starship, and apt.
- The bootstrap requires Ubuntu (any supported LTS). Other distros are rejected at preflight.

## Usage

**Full setup (recommended):**

```powershell
.\install.ps1
```

You'll be prompted at each step: pick a distro, accept the bootstrap plan inside WSL, reboot if WSL was just installed.

**Unattended:**

```powershell
.\install.ps1 -NonInteractive
```

Picks `Ubuntu` (latest LTS) as the distro and forwards `--non-interactive` to the bootstrap.

**Re-target an existing distro:**

```powershell
.\install.ps1 -Distro Ubuntu-24.04
```

**Pass options to the bootstrap:**

```powershell
.\install.ps1 -BootstrapArgs '--shell=bash','--no-brew'
```

**Bootstrap only (e.g. inside an existing Ubuntu shell):**

```bash
./comfort-shell-bootstrap.sh                    # interactive
./comfort-shell-bootstrap.sh --non-interactive  # defaults, no prompts
./comfort-shell-bootstrap.sh --dry-run          # preview without changes
```

## What this configures

- **WSL + an Ubuntu distro** (installs both if missing, with a reboot + auto-resume in between).
- **Default login shell** set to zsh (or bash, if you opt in).
- **starship** prompt with a minimal config.
- **~12 apt packages** for modern CLI tools: `fzf`, `ripgrep`, `fd-find`, `bat`, `jq`, plus `eza`/`btop`/`tmux` when available.
- **Homebrew** with `gh`, `direnv`, `zoxide` formulae layered on top.
- **Clipboard / `open` shims** in `~/bin`: `pbcopy`, `pbpaste`, `open`, `xdg-open` — bridged to `clip.exe`, PowerShell `Get-Clipboard`, and `cmd /c start`.
- **Managed dotfile blocks** in `~/.zprofile` + `~/.zshrc` (or `~/.profile` + `~/.bashrc`) for PATH, brew shellenv, prompt init, aliases, and (zsh) keybindings.
- **Git defaults**: `init.defaultBranch=main`, `pull.rebase=false`, `core.autocrlf=input`.
- **Cascadia Code Nerd Fonts** both mono and not.
- **A Windows Terminal profile fragment** named `Comfort Shell - <distro>`, with a custom Catppuccin-ish dark scheme, the sunglasses icon, and `wsl.exe -d <distro>` as the command line.

---

## Scripts

| Script | Runs on | Role |
|--------|---------|------|
| `install.ps1` | Windows (PowerShell 5.1 or 7) | Orchestrator: ensures WSL, picks/installs a distro, invokes the bootstrap inside it, installs the font, drops the WT profile. |
| `comfort-shell-bootstrap.sh` | Ubuntu (inside WSL or bare-metal) | Installer: configures the shell, prompt, tools, shims, Homebrew, git defaults, and dotfiles. |

---

## install.ps1 (Windows side)

### Step-by-step

The script runs five labeled steps and updates the console title with the current step:

| Step | What it does | Key behavior |
|------|--------------|--------------|
| 1. Ensuring WSL platform | `wsl.exe --status` probe. If WSL is missing, runs `wsl.exe --install --no-distribution` and exits via reboot. | Registers a RunOnce auto-resume so the script picks up where it left off after the reboot. |
| 2. Choosing Ubuntu distro | Lists installed `Ubuntu*` distros from `wsl -l -q`. If none, offers the 4 supported LTS lines. | `Install-NewDistro` retries up to 3 times (5s → 15s backoff) and gives actionable hints on failure (DNS, proxy, VPN). |
| 3. Running Comfort Shell bootstrap | Stages `comfort-shell-bootstrap.sh` to `%TEMP%`, copies it into the distro's `$HOME`, strips CRLFs, makes it executable, runs it. | Uses `Invoke-NativeConsole` so the child sees a real TTY (needed for `/dev/tty` prompts in the bootstrap). |
| 4. Installing Cascadia Code Nerd Fonts | Downloads fonts from GitHub release; extracts and registers them. | Detects "already installed" and skips if so. |
| 5. Installing Windows Terminal profile | Writes a JSON fragment under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\ComfortShell\comfort-shell-<slug>.fragment.json`. | Deterministic per-distro GUID (MD5 of `comfort-shell:<distro>`) so re-runs update in place and multiple distros coexist. Touches `settings.json` mtime to nudge WT's hot-reload. |

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-NonInteractive` | `$false` | Skip all prompts: auto-pick the default distro (`Ubuntu`) and forward `--non-interactive` to the bootstrap. |
| `-Distro <name>` | (prompt) | Use a specific Ubuntu distro by name (`Ubuntu`, `Ubuntu-24.04`, `Ubuntu-22.04`, `Ubuntu-20.04`). Installs it if not present. Other distros are rejected. |
| `-BootstrapArgs <string[]>` | `@()` | Extra arguments forwarded verbatim to `comfort-shell-bootstrap.sh`. Example: `-BootstrapArgs '--shell=bash','--no-brew'`. |
| `-ResumeEncodedArgs <base64>` | — | Internal. Set by the RunOnce launcher after a reboot; round-trips the original arguments as base64-encoded JSON. |

### Reboot + auto-resume

When `wsl.exe --install` requires a reboot, the script:

1. Registers `HKCU\...\RunOnce\ComfortShellResume` with an encoded launcher that re-opens Windows Terminal and re-invokes `install.ps1`.
2. Round-trips `NonInteractive`, `Distro`, and `BootstrapArgs` as base64-JSON via `-ResumeEncodedArgs` so the post-reboot run picks up the original intent.
3. Optionally reboots immediately (10-second cancellable countdown) or hands control back to the user.

On a successful run the RunOnce key is cleared at the top of the script (so an unrelated subsequent reboot doesn't re-fire the installer).

The script also calls `Reset-TerminalInputMode` after every native console invocation. `wsl.exe` enables Win32 Input Mode and focus reporting on the parent console and doesn't always restore them; without this, later `Read-Host` calls echo escape sequences like `^[[I` and `^[[9;15;9;0;0;1_`.

---

## comfort-shell-bootstrap.sh (Linux side)

### Step-by-step

The bootstrap shows a plan + asks for confirmation, then runs N labeled steps (count depends on enabled modules). All steps are idempotent.

| Step | Function | What it does |
|------|----------|--------------|
| Shell | `install_shell` | Installs zsh (with `zsh-autosuggestions` + `zsh-syntax-highlighting`) and `chsh`'s the user to it. In skel mode, edits `/etc/adduser.conf` `DSHELL=` instead. |
| Prompt | `install_prompt` | Installs starship via the upstream `install.sh`. Writes `~/.config/starship.toml` with a minimal config. |
| CLI tools | `install_cli_tools` | `apt-get install` for the required list (`build-essential`, `pkg-config`, `fzf`, `ripgrep`, `fd-find`, `bat`, `jq`, `unzip`, `curl`, `wget`, `git`, `ca-certificates`) and optional list (`eza`, `btop`, `tmux`). Drops `~/bin/fd` and `~/bin/bat` shims when the Debian binary names differ. |
| CLI shims | `install_cli_shims` | Writes `~/bin/pbcopy` (→ `clip.exe`), `~/bin/pbpaste` (→ `Get-Clipboard \| tr -d "\r"`), `~/bin/open` (→ `cmd.exe /c start`), `~/bin/xdg-open` (→ `open`). Marked `# comfort-shell shim` so the script can recognize its own files. |
| Homebrew | `install_homebrew` | Runs the upstream `install.sh` with `NONINTERACTIVE=1 CI=1`. Then `brew install gh direnv zoxide`. In skel mode this is deferred — see [Skel mode](#skel-mode-running-as-root). |
| Git defaults | `install_git_defaults` | `git config --global` for `init.defaultBranch=main`, `pull.rebase=false`, `core.autocrlf=input`. Only sets values that aren't already set (or with `--force`). |
| Shell config | `install_shell_config` | Replaces a `# >>> comfort-shell >>>` managed block in `~/.zprofile` + `~/.zshrc` (or `~/.profile` + `~/.bashrc`) with PATH, brew shellenv, prompt init, aliases (`ls`/`ll`/`lt`/`cat`/`grep`/`find` + git shortcuts), persistent zsh history (`~/.zsh_history`) with duplicate suppression, `/etc/zsh_command_not_found` integration when available, and zsh keybindings for Windows Terminal (including Up/Down history search by prefix, Ctrl+Left/Right, Home/End, Ctrl+Backspace, etc.). |

Before the steps run, `heal_wsl_issues` cleans NUL bytes from `/etc/wsl.conf` (a known WSL corruption that produces `Invalid key name` warnings on every shell launch).

All output is teed to `~/.comfort-shell-install.log` (using `stdbuf -o0 tee` when available, so partial lines flush in real time).

### Options

| Flag | Effect |
|------|--------|
| `--non-interactive` | Accept all defaults; no prompts. |
| `--shell=zsh\|bash` | Pick the default login shell. Default `zsh`. |
| `--no-brew` | Skip Homebrew (and its formulae). |
| `--no-shims` | Skip `pbcopy`/`pbpaste`/`open`/`xdg-open`. |
| `--no-prompt` | Skip starship. |
| `--no-tools` | Skip the apt CLI tools list. |
| `--minimal` | `--no-brew --no-shims --no-tools`. |
| `--force` | Overwrite existing configs (e.g. `~/.config/starship.toml`) instead of preserving them. |
| `--dry-run` | Print what would happen; make no changes. |
| `--help` / `-h` | Print usage. |

### Skel mode (running as root)

When `comfort-shell-bootstrap.sh` runs as root (typical for pre-baking a distro image), it switches to **skel mode**:

- `HOME` is redirected to `/etc/skel` so dotfiles land in the template every new user is created from.
- Default shell is set via `/etc/adduser.conf`'s `DSHELL=`, not `chsh`.
- starship installs to `/usr/local/bin` (PATH-visible to every user).
- Homebrew install is **deferred**: an installer script is dropped at `/usr/local/share/comfort-shell/install-brew.sh`, and `/etc/skel/.comfort-shell-first-run` is created as a marker. The skel `.zshrc` contains a first-run hook that runs the brew installer once on the new user's first interactive shell, logs the attempt, and removes the marker on success.

This is what makes the Windows-side flow work on a freshly installed distro that hasn't been opened yet — the bootstrap runs as root via `wsl -d <distro> -- bash`, the user account is created on first launch from the Windows Terminal profile, and Homebrew installs itself on that first shell.

---

## Customization

- **Pick a shell.** Default zsh; pass `--shell=bash` (bootstrap) or `-BootstrapArgs '--shell=bash'` (install.ps1) to use bash.
- **Trim the install.** Use any combination of `--no-*` flags, or `--minimal` for the smallest sensible footprint (shell + dotfiles + git defaults only).
- **Change the apt package lists.** Edit `COMFORT_APT_REQUIRED` and `COMFORT_APT_OPTIONAL` near the top of `comfort-shell-bootstrap.sh`.
- **Change the prompt.** Edit the `write_file "$cfg" 644 ...` block in `install_prompt` (or set `INSTALL_PROMPT="no"` and bring your own).
- **Change the Terminal theme or font.** Edit `Install-TerminalProfile` in `install.ps1` — the color scheme is inline, and `font.face`/`font.size` are right there too.
- **Re-run safely.** The script is idempotent. To force overwrites of preserved configs, run the bootstrap with `--force`.

## Design decisions

| Decision | Rationale |
|----------|-----------|
| Two scripts instead of one | The bootstrap is genuinely useful on its own (any Ubuntu host). Splitting it means `install.ps1` is a thin orchestrator and the actual shell setup is portable. |
| Auto-resume via RunOnce + base64-JSON | `wsl --install` always requires a reboot on a fresh machine. Manually re-running the script with the same arguments is friction; RunOnce + a base64-encoded payload restores the exact original invocation. |
| Win32 Input Mode reset after every `wsl.exe` | `wsl.exe` enables Win32 Input Mode and focus reporting on the parent console and doesn't restore them. Without `Reset-TerminalInputMode`, follow-up `Read-Host` prompts echo `^[[I` etc. |
| `Invoke-NativeConsole` (Start-Process -NoNewWindow -Wait) | We need the child to see a real TTY so `/dev/tty` reads inside the bootstrap (interactive prompts) work. Plain `& wsl.exe` over a pipeline breaks this. |
| Deterministic per-distro WT profile GUID | MD5(`comfort-shell:<distro>`) gives stable GUIDs: re-runs update in place; different distros (Ubuntu vs Ubuntu-24.04) coexist as separate profiles. |
| Touch `settings.json` mtime | Windows Terminal re-scans `Fragments\*.json` when `settings.json` changes. Touching it makes the new profile appear without a WT restart. |
| Managed blocks in dotfiles | `# >>> comfort-shell >>>` / `# <<< comfort-shell <<<` markers let us own a slice of `.zshrc` without trampling user edits. |
| Skel mode for fresh distros | Lets the Windows-side flow run the bootstrap as root before any user exists. The user is created on first WT launch, inherits the dotfiles, and triggers the deferred brew install. |
| `stdbuf -o0 tee` for logging | Without it, `tee` buffers partial lines and interactive prompts can render in the middle of banners. |
| Prompts on stderr (not `/dev/tty`) | Routing them to stderr keeps prompts in tee'd order with banner output, instead of racing the buffered banner to the terminal. |
| Ubuntu-only | The bootstrap calls `apt-get` directly and relies on package names that are Debian-family specific. Other distros are rejected at preflight to fail loudly rather than half-install. |

## Known caveats

| Area | Caveat |
|------|--------|
| **Windows Terminal required** | The script hard-fails if `wt.exe` is not on PATH. A Comfort Shell without a WT profile would be half the experience, so we don't degrade. |
| **WSL install requires a reboot** | First-time WSL installs always reboot. The script registers RunOnce and offers to reboot for you; cancelling the countdown is fine — the auto-resume will fire after any subsequent logon. |
| **Ubuntu only** | Both halves bail on non-Ubuntu distros. Debian would mostly work but is untested; other families would not. |
| **`wsl -l -q` UTF-16 quirk** | `wsl.exe --list --quiet` emits UTF-16LE with embedded NUL bytes. The script strips NULs in `Get-WslSupportedDistros`; do the same in any new code that parses `wsl -l -q`. |
| **Homebrew in CI/skel** | Homebrew's installer probes for a real user. In skel mode we defer brew to the first interactive shell; the first user pays a one-time multi-minute cost on first login (logged to `~/.comfort-shell-install.log`). |
| **Clipboard / `open` shims are best-effort** | `pbpaste` strips `\r` from `Get-Clipboard` output; complex clipboard payloads (images, multi-format) won't round-trip. `open` uses `wslpath -w` for files and falls back to passing the raw target for URLs. |
| **`chsh` requires logout** | After the first run, `echo $SHELL` won't reflect zsh until you start a fresh login shell. The Windows Terminal "Comfort Shell" profile starts a fresh shell, so just open it. |
| **`fd` / `bat` Debian names** | Debian ships these as `fdfind` and `batcat`. The bootstrap drops `~/bin/fd` and `~/bin/bat` shims; if you install `fd`/`bat` elsewhere later, delete the shims. |
| **CRLF in the bootstrap** | When the bootstrap is staged from Windows, the script `sed -i 's/\r$//'` inside WSL before executing. If you copy it manually, make sure your editor doesn't re-introduce CRLF. |
| **NUL bytes in `/etc/wsl.conf`** | A known WSL bug occasionally writes NUL bytes into `/etc/wsl.conf`. `heal_wsl_issues` strips them; you may need to `wsl.exe --shutdown` afterward for the cleaned config to take effect. |
| **Idempotency vs `--force`** | Re-runs preserve user edits to existing configs (e.g. `~/.config/starship.toml`). Pass `--force` to overwrite. The managed dotfile blocks are always replaced wholesale — edits inside the markers are lost. |

## Inspired by

This system was inspired by [Scott Hanselman's WSL Comfort shell](https://github.com/shanselman/MacLikeWSLComfortShell).
