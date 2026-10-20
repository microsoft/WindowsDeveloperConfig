# WSL Comfort Shell 😎

Turns a fresh Windows + WSL machine into a cozy, themed shell: an Ubuntu distro running zsh + Starship + modern CLI tools, surfaced through a Windows Terminal profile in Cascadia Code Nerd Font. Everything is opt-in — pick what you want, skip the rest.

The Windows half (`install.ps1`) handles WSL, the distro, the font, and the terminal profile. The Linux half (`comfort-shell-bootstrap.sh`) configures the shell itself, and also runs standalone — copy it onto any Ubuntu host and run it directly. `setup.ps1` is the one-line entry point: it downloads and verifies both, then runs `install.ps1`.

## Table of Contents

- [Quick start](#quick-start)
  - [What this configures](#what-this-configures)
  - [From a clone](#from-a-clone)
- [Advanced setup](#advanced-setup)
  - [install.ps1 parameters](#installps1-parameters)
  - [Bootstrap options](#bootstrap-options)
- [Scripts](#scripts)
- [setup.ps1 (one-line setup)](#setupps1-one-line-setup)
- [install.ps1 (Windows side)](#installps1-windows-side)
  - [Step-by-step](#step-by-step)
  - [Reboot + auto-resume](#reboot--auto-resume)
- [comfort-shell-bootstrap.sh (Linux side)](#comfort-shell-bootstrapsh-linux-side)
  - [Step-by-step](#step-by-step-1)
  - [Skel mode (running as root)](#skel-mode-running-as-root)
- [Customization](#customization)
- [Philosophy](#philosophy)
- [Known caveats](#known-caveats)

---

## Quick start

Open any PowerShell window and run:

```powershell
irm https://aka.ms/devconfig/wsl-comfort/setup.ps1 | iex
```

Nothing to clone. It's interactive by default: pick a distro, then choose each component as it runs. See [setup.ps1](#setupps1-one-line-setup) for what it downloads and verifies.

<details>
<summary><strong>What this configures</strong></summary>

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
</details>

### From a clone

```powershell
git clone https://github.com/microsoft/WindowsDeveloperConfig.git
cd WindowsDeveloperConfig\wsl-comfort
.\install.ps1
```

---

## Advanced setup

```powershell
# Pass install.ps1 parameters through the one-liner
& ([scriptblock]::Create((irm https://aka.ms/devconfig/wsl-comfort/setup.ps1))) -NonInteractive
& ([scriptblock]::Create((irm https://aka.ms/devconfig/wsl-comfort/setup.ps1))) -Distro Ubuntu-24.04 -BootstrapArgs '--shell=bash','--no-brew'
```

```powershell
# The same parameters from a clone
.\install.ps1 -NonInteractive

# Example of passing params to the bootstrap
.\install.ps1 -BootstrapArgs '--shell=bash','--no-brew'

# Re-target an existing distro
.\install.ps1 -Distro Ubuntu-24.04
```

```bash
# Example of bootstrap params (run directly inside an existing Ubuntu shell)
./comfort-shell-bootstrap.sh --non-interactive
./comfort-shell-bootstrap.sh --dry-run
```

### install.ps1 parameters

`setup.ps1` accepts `-NonInteractive`, `-Distro`, and `-BootstrapArgs` too, and passes them through to `install.ps1`.

| Parameter | Default | Description |
| --- | --- | --- |
| `-NonInteractive` | `$false` | Skip all prompts: auto-pick the default distro (`Ubuntu`) and forward `--non-interactive` to the bootstrap. |
| `-Distro <name>` | (prompt) | Use a specific Ubuntu distro by name (`Ubuntu`, `Ubuntu-24.04`, `Ubuntu-22.04`, `Ubuntu-20.04`). Installs it if not present. Other distros are rejected. |
| `-BootstrapArgs <string[]>` | `@()` | Extra arguments forwarded verbatim to `comfort-shell-bootstrap.sh`. Example: `-BootstrapArgs '--shell=bash','--no-brew'`. |
| `-ResumeEncodedArgs <base64>` | — | Internal. Set by the RunOnce launcher after a reboot; round-trips the original arguments as base64-encoded JSON. |

### Bootstrap options

| Flag | Default | Effect |
| --- | --- | --- |
| `--shell=zsh\|bash` | `zsh` | Pick the default login shell. |
| `--non-interactive` | off | Accept all defaults; no prompts. |
| `--no-brew` | off | Skip Homebrew (and its formulae). |
| `--no-shims` | off | Skip `pbcopy`/`pbpaste`/`open`/`xdg-open`. |
| `--no-prompt` | off | Skip starship. |
| `--no-tools` | off | Skip the apt CLI tools list. |
| `--minimal` | off | Shorthand for `--no-brew --no-shims --no-tools`. |
| `--force` | off | Overwrite existing configs (e.g. `~/.config/starship.toml`) instead of preserving them. |
| `--dry-run` | off | Print what would happen; make no changes. |
| `--help` / `-h` | — | Print usage. |

---

## Scripts

| Script | Runs on | Role |
| --- | --- | --- |
| `setup.ps1` | Windows (PowerShell 5.1 or 7) | One-line entry point: downloads the signed release copy of this folder, verifies it, and runs `install.ps1` from a per-user copy. |
| `install.ps1` | Windows (PowerShell 5.1 or 7) | Orchestrator: ensures WSL, picks/installs a distro, invokes the bootstrap inside it, installs the font, drops the WT profile. |
| `comfort-shell-bootstrap.sh` | Ubuntu (inside WSL or bare-metal) | Installer: configures the shell, prompt, tools, shims, Homebrew, git defaults, and dotfiles. |
| `content-hashes.psd1` | — (data) | Signed SHA-256 list for files that can't carry a signature, such as `comfort-shell-bootstrap.sh`. `setup.ps1` won't run a file that doesn't match. |

---

## setup.ps1 (one-line setup)

`irm https://aka.ms/devconfig/wsl-comfort/setup.ps1 | iex` runs this launcher. It:

1. Stops early if organization policy sets PowerShell script execution to `Restricted`.
2. Downloads `install.ps1` and `content-hashes.psd1` from the signed `wsl-comfort/` release copy at a pinned commit, and checks that both carry a valid Microsoft Authenticode signature.
3. Downloads each file listed in `content-hashes.psd1` and checks its SHA-256, after converting CRLF line endings to LF.
4. Stages the verified files in a new folder under `%LOCALAPPDATA%\DevConfig\wsl-comfort`. Later runs never change it, so the [reboot auto-resume](#reboot--auto-resume) can come back to it.
5. Runs `install.ps1` from that folder in the same console and PowerShell edition, with process-scoped `RemoteSigned`, passing through `-NonInteractive`, `-Distro`, and `-BootstrapArgs`. From 32-bit PowerShell, which can't see `wsl.exe`, it uses 64-bit Windows PowerShell instead.

If any check fails, nothing runs and the new folder is removed. The launcher doesn't elevate: the font, Terminal profile, distro, and resume entry all belong to the signed-in user, and `wsl --install` asks for administrator approval itself when WSL is missing.

The one-liner always downloads the published files. They're checked when downloaded; a resume after the reboot reuses them without checking again. To run a customized `comfort-shell-bootstrap.sh`, use a [clone](#from-a-clone).

---

## install.ps1 (Windows side)

### Step-by-step

The script runs five labeled steps and updates the console title with the current step:

| # | Step | What it does | Key behavior |
| --- | --- | --- | --- |
| 1 | Ensuring WSL platform | `wsl.exe --status` probe. If WSL is missing, runs `wsl.exe --install --no-distribution` and exits via reboot. | Registers a RunOnce auto-resume so the script picks up where it left off after the reboot. |
| 2 | Choosing Ubuntu distro | Lists installed `Ubuntu*` distros from `wsl -l -q`. If none, offers the 4 supported LTS lines. | `Install-NewDistro` retries up to 3 times (5s → 15s backoff) and gives actionable hints on failure (DNS, proxy, VPN). |
| 3 | Running Comfort Shell bootstrap | Stages `comfort-shell-bootstrap.sh` to `%TEMP%`, copies it into the distro's `$HOME`, strips CRLFs, makes it executable, runs it. | Uses `Invoke-NativeConsole` so the child sees a real TTY (needed for `/dev/tty` prompts in the bootstrap). |
| 4 | Installing Cascadia Code Nerd Fonts | Downloads fonts from GitHub release; extracts and registers them. | Detects "already installed" and skips if so. |
| 5 | Installing Windows Terminal profile | Writes a JSON fragment under `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\ComfortShell\comfort-shell-<slug>.fragment.json`. | Deterministic per-distro GUID (MD5 of `comfort-shell:<distro>`) so re-runs update in place and multiple distros coexist. Touches `settings.json` mtime to nudge WT's hot-reload. |

Parameters are listed in [Advanced setup](#advanced-setup).

### Reboot + auto-resume

When `wsl.exe --install` requires a reboot, the script:

1. Registers `HKCU\...\RunOnce\ComfortShellResume` with an encoded launcher that re-opens Windows Terminal and re-invokes `install.ps1` from where it ran: your clone, or that run's folder under `%LOCALAPPDATA%\DevConfig\wsl-comfort` when you used the one-liner.
2. Round-trips `NonInteractive`, `Distro`, and `BootstrapArgs` as base64-JSON via `-ResumeEncodedArgs` so the post-reboot run picks up the original intent.
3. Optionally reboots immediately (10-second cancellable countdown) or hands control back to the user.

On a successful run the RunOnce key is cleared at the top of the script (so an unrelated subsequent reboot doesn't re-fire the installer).

The script also calls `Reset-TerminalInputMode` after every native console invocation. `wsl.exe` enables Win32 Input Mode and focus reporting on the parent console and doesn't always restore them; without this, later `Read-Host` calls echo escape sequences like `^[[I` and `^[[9;15;9;0;0;1_`.

---

## comfort-shell-bootstrap.sh (Linux side)

### Step-by-step

The bootstrap shows a plan + asks for confirmation, then runs N labeled steps (count depends on enabled modules). All steps are idempotent.

| # | Step | Function | What it does |
| --- | --- | --- | --- |
| 1 | Shell | `install_shell` | Installs zsh (with `zsh-autosuggestions` + `zsh-syntax-highlighting`) and `chsh`'s the user to it. In skel mode, edits `/etc/adduser.conf` `DSHELL=` instead. |
| 2 | Prompt | `install_prompt` | Installs starship via the upstream `install.sh`. Writes `~/.config/starship.toml` with a minimal config. |
| 3 | CLI tools | `install_cli_tools` | `apt-get install` for the required list (`build-essential`, `pkg-config`, `fzf`, `ripgrep`, `fd-find`, `bat`, `jq`, `unzip`, `curl`, `wget`, `git`, `ca-certificates`) and optional list (`eza`, `btop`, `tmux`). Drops `~/bin/fd` and `~/bin/bat` shims when the Debian binary names differ. |
| 4 | CLI shims | `install_cli_shims` | Writes `~/bin/pbcopy` (→ `clip.exe`), `~/bin/pbpaste` (→ `Get-Clipboard \| tr -d "\r"`), `~/bin/open` (→ `cmd.exe /c start`), `~/bin/xdg-open` (→ `open`). Marked `# comfort-shell shim` so the script can recognize its own files. |
| 5 | Homebrew | `install_homebrew` | Runs the upstream `install.sh` with `NONINTERACTIVE=1 CI=1`. Then `brew install gh direnv zoxide`. In skel mode this is deferred — see [Skel mode](#skel-mode-running-as-root). |
| 6 | Git defaults | `install_git_defaults` | `git config --global` for `init.defaultBranch=main`, `pull.rebase=false`, `core.autocrlf=input`. Only sets values that aren't already set (or with `--force`). |
| 7 | Shell config | `install_shell_config` | Replaces a `# >>> comfort-shell >>>` managed block in `~/.zprofile` + `~/.zshrc` (or `~/.profile` + `~/.bashrc`) with PATH, brew shellenv, prompt init, aliases (`ls`/`ll`/`lt`/`cat`/`grep`/`find` + git shortcuts), persistent zsh history (`~/.zsh_history`) with duplicate suppression, `/etc/zsh_command_not_found` integration when available, and zsh keybindings for Windows Terminal (including Up/Down history search by prefix, Ctrl+Left/Right, Home/End, Ctrl+Backspace, etc.). |

Before the steps run, `heal_wsl_issues` cleans NUL bytes from `/etc/wsl.conf` (a known WSL corruption that produces `Invalid key name` warnings on every shell launch).

All output is teed to `~/.comfort-shell-install.log` (using `stdbuf -o0 tee` when available, so partial lines flush in real time).

Options are listed in [Advanced setup](#advanced-setup).

### Skel mode (running as root)

This lets `install.ps1` bootstrap a fresh distro as root before any user exists — the real account is created on first Windows Terminal launch, inherits the dotfiles, and Homebrew installs itself on that first shell. When `comfort-shell-bootstrap.sh` runs as root (typical for pre-baking a distro image), it switches to **skel mode**:

- `HOME` is redirected to `/etc/skel` so dotfiles land in the template every new user is created from.
- Default shell is set via `/etc/adduser.conf`'s `DSHELL=`, not `chsh`.
- starship installs to `/usr/local/bin` (PATH-visible to every user).
- Homebrew is **deferred** to the new user's first interactive shell via a first-run hook in the skel `.zshrc`, since its installer needs a real (non-root) user.

---

## Customization

- **Change the apt package lists.** Edit `COMFORT_APT_REQUIRED` and `COMFORT_APT_OPTIONAL` near the top of `comfort-shell-bootstrap.sh`.
- **Change the prompt.** Edit the `write_file "$cfg" 644 ...` block in `install_prompt` (or set `INSTALL_PROMPT="no"` and bring your own).
- **Change the Terminal theme or font.** Edit `Install-TerminalProfile` in `install.ps1` — the color scheme is inline, and `font.face`/`font.size` are right there too.

These edits apply when you run `.\install.ps1` from a clone; the one-liner always downloads the published files. Contributing a change to `comfort-shell-bootstrap.sh`? Update its hash in `src\wsl-comfort\content-hashes.psd1` too — `src\tests\comfort-shell\unit.ps1` checks it and prints the expected value.

## Philosophy

- **Opt-in, not all-or-nothing.** Every piece — starship, the CLI bundle, clipboard shims, Homebrew, git defaults — can be skipped independently, or all at once with `--minimal`.
- **One command end-to-end.** The one-liner (or `.\install.ps1` from a clone) takes a fresh Windows machine to a fully configured, themed Windows Terminal profile.
- **Idempotent.** Re-running is always safe — managed dotfile blocks are replaced in place, the WT fragment is rewritten with a deterministic GUID, and already-installed packages are skipped.
- **Standalone halves.** `comfort-shell-bootstrap.sh` doesn't need `install.ps1` — drop it on any Ubuntu host (WSL or not) and it works on its own.

### Design decisions

| Decision | Rationale |
| --- | --- |
| Two scripts instead of one | The bootstrap is genuinely useful on its own (any Ubuntu host). Splitting it means `install.ps1` is a thin orchestrator and the actual shell setup is portable. |
| Separate one-line launcher (`setup.ps1`) | Matches the repo's other one-liners: a pinned payload commit and Microsoft signature checks before anything runs. Unlike Windows Dev Config's `bootstrap.ps1`, it doesn't elevate or install under `%ProgramData%`, because Comfort Shell configures the signed-in user's profile. Each run stages into its own folder, so a later run never changes files a pending resume will use. |
| Signed hash list for the bootstrap | `.sh` files can't carry an Authenticode signature, so the signed `content-hashes.psd1` pins their SHA-256. Hashing with LF line endings keeps the result independent of Git checkout settings. |
| Auto-resume via RunOnce + base64-JSON | `wsl --install` always requires a reboot on a fresh machine. Manually re-running the script with the same arguments is friction; RunOnce + a base64-encoded payload restores the exact original invocation. |
| Win32 Input Mode reset after every `wsl.exe` | `wsl.exe` enables Win32 Input Mode and focus reporting on the parent console and doesn't restore them. Without `Reset-TerminalInputMode`, follow-up `Read-Host` prompts echo `^[[I` etc. |
| `Invoke-NativeConsole` (Start-Process -NoNewWindow -Wait) | We need the child to see a real TTY so `/dev/tty` reads inside the bootstrap (interactive prompts) work. Plain `& wsl.exe` over a pipeline breaks this. |
| Deterministic per-distro WT profile GUID | MD5(`comfort-shell:<distro>`) gives stable GUIDs: re-runs update in place; different distros (Ubuntu vs Ubuntu-24.04) coexist as separate profiles. |
| Touch `settings.json` mtime | Windows Terminal re-scans `Fragments\\*.json` when `settings.json` changes. Touching it makes the new profile appear without a WT restart. |
| Managed blocks in dotfiles | `# >>> comfort-shell >>>` / `# <<< comfort-shell <<<` markers let us own a slice of `.zshrc` without trampling user edits. |
| Skel mode for fresh distros | Lets the Windows-side flow run the bootstrap as root before any user exists. The user is created on first WT launch, inherits the dotfiles, and triggers the deferred brew install. |
| `stdbuf -o0 tee` for logging | Without it, `tee` buffers partial lines and interactive prompts can render in the middle of banners. |
| Prompts on stderr (not `/dev/tty`) | Routing them to stderr keeps prompts in tee'd order with banner output, instead of racing the buffered banner to the terminal. |
| Ubuntu-only | The bootstrap calls `apt-get` directly and relies on package names that are Debian-family specific. Other distros are rejected at preflight to fail loudly rather than half-install. |

## Known caveats

| Area | Caveat |
| --- | --- |
| **Windows Terminal required** | The script hard-fails if `wt.exe` is not on PATH. A Comfort Shell without a WT profile would be half the experience, so we don't degrade. |
| **Internet access required** | Needed for the WSL distro download, Homebrew, starship, and apt. There's no offline mode. |
| **One-liner keeps a copy** | Each run keeps its verified files in a new folder under `%LOCALAPPDATA%\DevConfig\wsl-comfort` so the post-reboot resume can find them. They're checked when downloaded, not again on resume. Delete the folder once setup is done if you like. |
| **`AllSigned` policy** | If your organization enforces `AllSigned`, PowerShell may ask you to trust the Microsoft publisher before `install.ps1` runs. |
| **WSL install requires a reboot** | First-time WSL installs always reboot. The script registers RunOnce and offers to reboot for you; cancelling the countdown is fine — the auto-resume will fire after any subsequent logon. |
| **Ubuntu only** | Both halves bail on non-Ubuntu distros. Debian would mostly work but is untested; other families would not. |
| **`wsl -l -q` UTF-16 quirk** | `wsl.exe --list --quiet` emits UTF-16LE with embedded NUL bytes. The script strips NULs in `Get-InstalledWslDistros`; do the same in any new code that parses `wsl -l -q`. |
| **Homebrew in CI/skel** | Homebrew's installer probes for a real user. In skel mode we defer brew to the first interactive shell; the first user pays a one-time multi-minute cost on first login (logged to `~/.comfort-shell-install.log`). |
| **Clipboard / `open` shims are best-effort** | `pbpaste` strips `\r` from `Get-Clipboard` output; complex clipboard payloads (images, multi-format) won't round-trip. `open` uses `wslpath -w` for files and falls back to passing the raw target for URLs. |
| **`chsh` requires logout** | After the first run, `echo $SHELL` won't reflect zsh until you start a fresh login shell. The Windows Terminal "Comfort Shell" profile starts a fresh shell, so just open it. |
| **`fd` / `bat` Debian names** | Debian ships these as `fdfind` and `batcat`. The bootstrap drops `~/bin/fd` and `~/bin/bat` shims; if you install `fd`/`bat` elsewhere later, delete the shims. |
| **CRLF in the bootstrap** | When the bootstrap is staged from Windows, the script `sed -i 's/\r$//'` inside WSL before executing. If you copy it manually, make sure your editor doesn't re-introduce CRLF. |
| **NUL bytes in `/etc/wsl.conf`** | A known WSL bug occasionally writes NUL bytes into `/etc/wsl.conf`. `heal_wsl_issues` strips them; you may need to `wsl.exe --shutdown` afterward for the cleaned config to take effect. |
| **Idempotency vs `--force`** | Re-runs preserve user edits to existing configs (e.g. `~/.config/starship.toml`). Pass `--force` to overwrite. The managed dotfile blocks are always replaced wholesale — edits inside the markers are lost. |

## Inspired by

This system was inspired by [Scott Hanselman's WSL Comfort shell](https://github.com/shanselman/MacLikeWSLComfortShell).
