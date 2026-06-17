#!/usr/bin/env bash
# =============================================================================
#  😎 Comfort Shell 😎
#  WSL shell customization bootstrap
#
#  This script transforms a fresh WSL distro into a comfortable dev shell.
#  It's designed to be easily readable and extendable by humans or AI.
#
#  Usage:
#    ./comfort-shell-bootstrap.sh                    # Interactive (prompts each step)
#    ./comfort-shell-bootstrap.sh --non-interactive  # Accept all defaults, no prompts
#    ./comfort-shell-bootstrap.sh --shell=bash       # Override default shell choice
#    ./comfort-shell-bootstrap.sh --dry-run          # Preview without changes
#
#  Options:
#    --non-interactive   Accept all defaults without prompting (default: interactive)
#    --shell=SHELL     Shell to set as default: zsh (default) or bash
#    --no-brew         Skip Homebrew installation
#    --no-shims        Skip clipboard/open shims (pbcopy, pbpaste, open)
#    --no-prompt       Skip starship prompt installation
#    --no-tools        Skip CLI tools (fzf, rg, fd, bat, etc.)
#    --minimal         Equivalent to --no-brew --no-shims --no-tools
#    --force           Overwrite existing configs even if present
#    --dry-run         Show what would happen without making changes
#    --help            Show this help
#
#  To extend: add a new install_* function below and call it from main().
#  Each function is self-contained and can be toggled via options.
# =============================================================================
set -euo pipefail

# =============================================================================
# CONFIGURATION - Edit these to change defaults
# =============================================================================

DEFAULT_SHELL="zsh"           # Options: zsh, bash
INSTALL_PROMPT="yes"          # Install starship prompt
INSTALL_BREW="yes"            # Install Homebrew
INSTALL_SHIMS="yes"           # Install clipboard/open shims (pbcopy, pbpaste, open)
INSTALL_TOOLS="yes"           # Install modern CLI tools (fzf, rg, fd, bat, eza)
INSTALL_GIT_DEFAULTS="yes"    # Set sensible git defaults
FORCE_OVERWRITE=0             # Overwrite existing configs

readonly COMFORT_APT_REQUIRED=(
  build-essential
  pkg-config
  fzf
  ripgrep
  fd-find
  bat
  jq
  unzip
  curl
  wget
  git
  ca-certificates
)
readonly COMFORT_APT_OPTIONAL=(eza btop tmux)

# =============================================================================
# INTERNALS - You probably don't need to edit below this line
# =============================================================================

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
INTERACTIVE=1
CHOSEN_SHELL="$DEFAULT_SHELL"
APT_UPDATED=0
LOG_FILE=""
TOTAL_STEPS=0
CURRENT_STEP=0

# Skel mode (root): write dotfiles to /etc/skel; defer Homebrew to first user login.
IS_SKEL_MODE=0
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  IS_SKEL_MODE=1
  export HOME=/etc/skel
  mkdir -p "$HOME" "$HOME/.config" "$HOME/bin"
fi

# --- Colors & Output ---------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[  OK]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
die()     { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }
dimmed()  { printf "${DIM}  %s${NC}\n" "$*"; }

set_title() { printf '\033]0;%s\007' "$*"; }

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf "\n${BOLD}${CYAN}▶ [%d/%d] %s${NC}\n" "$CURRENT_STEP" "$TOTAL_STEPS" "$*"
  set_title "Comfort Shell · ${CURRENT_STEP}/${TOTAL_STEPS} · $*"
}

count_steps() {
  # install_shell + install_shell_config always run.
  local n=2
  [ "$INSTALL_PROMPT" = "yes" ]        && n=$((n + 1))
  [ "$INSTALL_TOOLS" = "yes" ]         && n=$((n + 1))
  [ "$INSTALL_SHIMS" = "yes" ]         && n=$((n + 1))
  [ "$INSTALL_BREW" = "yes" ]          && n=$((n + 1))
  [ "$INSTALL_GIT_DEFAULTS" = "yes" ]  && n=$((n + 1))
  echo "$n"
}

# --- Helpers -----------------------------------------------------------------

has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null || [ -d /run/WSL ] || [ -n "${WSL_DISTRO_NAME:-}" ]
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "${DIM}  [dry-run] %s${NC}\n" "$*"
    return 0
  fi
  "$@"
}

confirm() {
  local prompt="$1" default="${2:-y}"
  if [ "$INTERACTIVE" -eq 0 ]; then
    return 0  # Non-interactive: always yes
  fi
  local hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi

  if ! { : >/dev/tty; } 2>/dev/null; then
    warn "/dev/tty unavailable; using default '$default' for: $prompt"
    case "$default" in [Yy]*) return 0 ;; *) return 1 ;; esac
  fi

  while true; do
    printf "${BOLD}  %s %s${NC} " "$prompt" "$hint" >&2
    read -r answer </dev/tty
    answer="${answer:-$default}"
    case "$answer" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) printf "  Please enter y or n.\n" >&2 ;;
    esac
  done
}

ask_toggle() {
  local var="$1" prompt="$2"
  if confirm "$prompt" "y"; then
    printf -v "$var" "yes"
  else
    printf -v "$var" "no"
  fi
}

choose() {
  local prompt="$1" default="$2"
  shift 2
  local options=("$@")

  if [ "$INTERACTIVE" -eq 0 ]; then
    echo "$default"
    return 0
  fi

  if ! { : >/dev/tty; } 2>/dev/null; then
    warn "/dev/tty unavailable; using default '$default' for: $prompt"
    echo "$default"
    return 0
  fi

  # Prompts go to stderr so they're teed in order with banner output and not captured by $(choose ...).
  printf "\n${BOLD}  %s${NC}\n" "$prompt" >&2
  local i=1
  for opt in "${options[@]}"; do
    if [ "$opt" = "$default" ]; then
      printf "    ${GREEN}%d) %s (default)${NC}\n" "$i" "$opt" >&2
    else
      printf "    %d) %s\n" "$i" "$opt" >&2
    fi
    ((i++))
  done

  while true; do
    printf "${BOLD}  Choice [%s]: ${NC}" "$default" >&2
    read -r answer </dev/tty
    answer="${answer:-$default}"

    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
      echo "${options[$((answer-1))]}"
      return 0
    fi

    for opt in "${options[@]}"; do
      if [ "$answer" = "$opt" ]; then
        echo "$opt"
        return 0
      fi
    done

    printf "  Invalid choice. Enter a number (1-%d) or name.\n" "${#options[@]}" >&2
  done
}

apt_update_once() {
  if [ "$APT_UPDATED" -eq 1 ]; then return 0; fi
  info "Updating package lists..."
  run sudo apt-get update -q
  APT_UPDATED=1
}

ensure_apt() {
  local pkg="$1" optional="${2:-0}"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  apt_update_once
  if [ "$optional" -eq 1 ]; then
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" || \
      warn "Optional package unavailable: $pkg"
  else
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" || \
      die "Failed to install required package: $pkg"
  fi
}

setup_logging() {
  # In skel mode HOME=/etc/skel; this file is copied to every new user's home on OOBE.
  LOG_FILE="$HOME/.comfort-shell-install.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  if has_cmd stdbuf; then
    exec > >(stdbuf -o0 tee -a "$LOG_FILE") 2>&1
  else
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
}

write_file() {
  local path="$1" mode="$2" content="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    dimmed "Would write: $path"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
}

install_shim() {
  local path="$1" content="$2"
  if [ -f "$path" ] && [ "$FORCE_OVERWRITE" -eq 0 ] && ! grep -q "comfort-shell shim" "$path" 2>/dev/null; then
    dimmed "Skipping existing: $path (use --force to overwrite)"
    return 0
  fi
  write_file "$path" 755 "$content"
}

managed_block() {
  local file="$1" marker="$2" content="$3"
  local start="# >>> ${marker} >>>"
  local end="# <<< ${marker} <<<"

  if [ "$DRY_RUN" -eq 1 ]; then
    dimmed "Would update managed block '$marker' in $file"
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  touch "$file"

  # Remove existing block if present
  local tmp
  tmp="$(mktemp)"
  awk -v s="$start" -v e="$end" '$0==s{skip=1;next} $0==e{skip=0;next} !skip{print}' "$file" > "$tmp"

  # Append new block
  {
    # Trim trailing blank lines
    awk 'NF{p=NR} {lines[NR]=$0} END{for(i=1;i<=p;i++)print lines[i]}' "$tmp"
    [ -s "$tmp" ] && printf '\n'
    printf '%s\n' "$start"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
  } > "${tmp}.new"
  mv "${tmp}.new" "$file"
  rm -f "$tmp"
}

# =============================================================================
# INSTALL MODULES - Each function is one self-contained step
# =============================================================================

install_shell() {
  step "Setting up shell: $CHOSEN_SHELL"

  if [ "$CHOSEN_SHELL" = "zsh" ]; then
    ensure_apt zsh 0
    ensure_apt zsh-autosuggestions 1
    ensure_apt zsh-syntax-highlighting 1

    local zsh_path
    zsh_path="$(command -v zsh)"

    if [ "$IS_SKEL_MODE" -eq 1 ]; then
      info "Setting default shell for new users to $zsh_path (via /etc/adduser.conf)..."
      if [ -f /etc/adduser.conf ]; then
        if grep -q '^DSHELL=' /etc/adduser.conf; then
          run sed -i "s|^DSHELL=.*|DSHELL=$zsh_path|" /etc/adduser.conf
        else
          run sh -c "printf '\nDSHELL=%s\n' '$zsh_path' >> /etc/adduser.conf"
        fi
      fi
      success "Default shell for new users: zsh"
    else
      local current_shell
      current_shell="$(getent passwd "$USER" | awk -F: '{print $7}')"

      if [ "$current_shell" != "$zsh_path" ]; then
        info "Changing default shell to zsh..."
        run sudo chsh -s "$zsh_path" "$USER"
        success "Default shell set to zsh"
      else
        success "Already using zsh"
      fi
    fi
  else
    success "Keeping bash as default shell"
  fi
}

install_prompt() {
  if [ "$INSTALL_PROMPT" != "yes" ]; then return 0; fi
  step "Installing starship prompt"

  if has_cmd starship && [ "$FORCE_OVERWRITE" -eq 0 ]; then
    success "starship already installed"
  else
    info "Downloading starship..."
    if [ "$DRY_RUN" -eq 0 ]; then
      if [ "$IS_SKEL_MODE" -eq 1 ]; then
        # Install to /usr/local/bin so every new user picks it up from PATH
        curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir /usr/local/bin
      else
        curl -fsSL https://starship.rs/install.sh | sh -s -- --yes
      fi
    else
      dimmed "Would install starship via install script"
    fi
    success "starship installed"
  fi

  local cfg="$HOME/.config/starship.toml"
  if [ ! -f "$cfg" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
    write_file "$cfg" 644 'add_newline = false

[character]
success_symbol = "[➜](bold green)"
error_symbol = "[➜](bold red)"

[directory]
truncation_length = 4
truncate_to_repo = false'
    success "Wrote starship config"
  else
    dimmed "Keeping existing $cfg"
  fi
}

install_cli_tools() {
  if [ "$INSTALL_TOOLS" != "yes" ]; then return 0; fi
  step "Installing modern CLI tools"

  for pkg in "${COMFORT_APT_REQUIRED[@]}"; do
    ensure_apt "$pkg" 0
  done
  for pkg in "${COMFORT_APT_OPTIONAL[@]}"; do
    ensure_apt "$pkg" 1
  done

  # Create convenience shims for tools with different binary names
  if ! has_cmd fd && has_cmd fdfind; then
    install_shim "$HOME/bin/fd" '#!/usr/bin/env bash
# comfort-shell shim
exec fdfind "$@"'
  fi

  if ! has_cmd bat && has_cmd batcat; then
    install_shim "$HOME/bin/bat" '#!/usr/bin/env bash
# comfort-shell shim
exec batcat "$@"'
  fi

  success "CLI tools installed"
}

install_cli_shims() {
  if [ "$INSTALL_SHIMS" != "yes" ]; then return 0; fi
  step "Installing CLI shims (pbcopy, pbpaste, open)"

  mkdir -p "$HOME/bin"

  install_shim "$HOME/bin/pbcopy" '#!/usr/bin/env bash
# comfort-shell shim - clipboard copy
clip.exe'

  install_shim "$HOME/bin/pbpaste" '#!/usr/bin/env bash
# comfort-shell shim - clipboard paste
powershell.exe -NoProfile -Command Get-Clipboard | tr -d "\r"'

  install_shim "$HOME/bin/open" '#!/usr/bin/env bash
# comfort-shell shim - open files/URLs
if [ "$#" -lt 1 ]; then
  echo "Usage: open <url-or-path>" >&2
  exit 1
fi
target="$*"
if [ -e "$1" ]; then
  target="$(wslpath -w "$1")"
fi
cmd.exe /c start "" "$target" >/dev/null 2>&1'

  if ! has_cmd xdg-open; then
    install_shim "$HOME/bin/xdg-open" '#!/usr/bin/env bash
# comfort-shell shim
exec open "$@"'
  fi

  success "CLI shims installed"
}

install_homebrew() {
  if [ "$INSTALL_BREW" != "yes" ]; then return 0; fi

  if [ "$IS_SKEL_MODE" -eq 1 ]; then
    install_deferred_brew
    return 0
  fi

  step "Installing Homebrew"

  if has_cmd brew; then
    success "Homebrew already installed"
  else
    info "Installing Homebrew (this may take a minute)..."
    if [ "$DRY_RUN" -eq 0 ]; then
      NONINTERACTIVE=1 CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || \
        warn "Homebrew install failed; continuing without it"
      # Verify the brew binary landed on disk.
      if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ] && [ ! -x "$HOME/.linuxbrew/bin/brew" ]; then
        warn "Homebrew installer ran but brew binary was not produced. Skipping brew formula install."
      fi
    else
      dimmed "Would install Homebrew"
    fi
  fi

  # Load brew into current session
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
      eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
    fi
  fi

  # starship is handled by install_prompt; only install brew-only extras here.
  if has_cmd brew && [ "$INSTALL_TOOLS" = "yes" ]; then
    local formulae=(gh direnv zoxide)
    for f in "${formulae[@]}"; do
      if ! brew list --formula "$f" >/dev/null 2>&1; then
        info "brew install $f"
        run brew install "$f" || warn "brew install $f failed"
      fi
    done
  fi

  success "Homebrew setup complete"
}

install_deferred_brew() {
  # Drop a Homebrew installer + marker so the first user's first interactive shell runs the install.
  step "Configuring deferred Homebrew install (runs on first shell launch)"

  local share_dir=/usr/local/share/comfort-shell
  local installer="$share_dir/install-brew.sh"

  run mkdir -p "$share_dir"

  if [ "$DRY_RUN" -eq 0 ]; then
    cat > "$installer" <<'BREW_INSTALLER'
#!/usr/bin/env bash
# Comfort Shell: deferred Homebrew installer.
# Invoked by /etc/skel/.zshrc on a new user's first interactive shell.
set -e

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  echo "Comfort Shell: skipping brew install (must run as a regular user)." >&2
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  exit 0
fi

cat <<'BANNER'

  😎 Comfort Shell: first-run setup
  ────────────────────────────────────────────────────
  Installing Homebrew. This is a one-time step and may
  take a few minutes. You'll be prompted once for your
  sudo password.

BANNER

# Prime the sudo timestamp so NONINTERACTIVE=1 brew install doesn't re-prompt.
if ! sudo -v; then
  echo "Comfort Shell: sudo authentication required to install Homebrew." >&2
  echo "  Retry: /usr/local/share/comfort-shell/install-brew.sh" >&2
  exit 1
fi

NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
  echo "Comfort Shell: brew install failed. Re-run /usr/local/share/comfort-shell/install-brew.sh later." >&2
  exit 1
}

# Verify the brew binary landed on disk before declaring success.
BREW=""
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  BREW=/home/linuxbrew/.linuxbrew/bin/brew
elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
  BREW="$HOME/.linuxbrew/bin/brew"
fi

if [ -z "$BREW" ]; then
  echo "Comfort Shell: brew binary not found after install attempt." >&2
  echo "  Likely cause: the installer download failed (network, DNS, proxy)." >&2
  echo "  Retry: /usr/local/share/comfort-shell/install-brew.sh" >&2
  exit 1
fi

eval "$("$BREW" shellenv)"
for f in gh direnv zoxide; do
  if ! "$BREW" list --formula "$f" >/dev/null 2>&1; then
    "$BREW" install "$f" || true
  fi
done

cat <<'DONE'

  ✓ Welcome to your Comfort Shell.

DONE
BREW_INSTALLER
    chmod 755 "$installer"
  fi

  # Marker copied into every new user's $HOME; removed by the first-run hook after success.
  run touch /etc/skel/.comfort-shell-first-run

  success "Deferred brew installer dropped at $installer"
}

install_git_defaults() {
  if [ "$INSTALL_GIT_DEFAULTS" != "yes" ]; then return 0; fi
  step "Setting git defaults"

  local -A defaults=(
    ["init.defaultBranch"]="main"
    ["pull.rebase"]="false"
    ["core.autocrlf"]="input"
  )

  for key in "${!defaults[@]}"; do
    local current
    current="$(git config --global --get "$key" || true)"
    if [ -z "$current" ] || [ "$FORCE_OVERWRITE" -eq 1 ]; then
      run git config --global "$key" "${defaults[$key]}"
      dimmed "$key = ${defaults[$key]}"
    fi
  done

  success "Git defaults configured"
}

install_shell_config() {
  step "Writing shell configuration"

  mkdir -p "$HOME/bin"
  export PATH="$HOME/bin:$PATH"

  # --- .zprofile managed block (login shell env) ---
  local profile_block='export PATH="$HOME/bin:$PATH"
if [ -d /home/linuxbrew/.linuxbrew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [ -d "$HOME/.linuxbrew" ]; then
  eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
fi
if command -v xdg-open >/dev/null 2>&1; then
  export BROWSER=xdg-open
elif command -v open >/dev/null 2>&1; then
  export BROWSER=open
fi'

  # --- .zshrc / .bashrc managed block (interactive shell) ---
  local rc_block=""
  if [ "$IS_SKEL_MODE" -eq 1 ]; then
    # First-run hook: runs the deferred brew installer and logs each attempt.
    rc_block='if [ -f "$HOME/.comfort-shell-first-run" ] && [ -t 0 ] && [ -t 1 ]; then
  if [ -x /usr/local/share/comfort-shell/install-brew.sh ]; then
    printf "%s comfort-shell: starting deferred install\n" "$(date -Is 2>/dev/null || date)" >> "$HOME/.comfort-shell-install.log"
    if /usr/local/share/comfort-shell/install-brew.sh; then
      printf "%s comfort-shell: deferred install succeeded\n" "$(date -Is 2>/dev/null || date)" >> "$HOME/.comfort-shell-install.log"
      rm -f "$HOME/.comfort-shell-first-run"
    else
      _comfort_rc=$?
      printf "%s comfort-shell: deferred install failed (exit %s)\n" "$(date -Is 2>/dev/null || date)" "$_comfort_rc" >> "$HOME/.comfort-shell-install.log"
      printf "\n\033[1;33mComfort Shell:\033[0m first-run setup did not complete cleanly.\n" >&2
      printf "  It will retry on the next shell launch.\n" >&2
      printf "  Log: %s\n" "$HOME/.comfort-shell-install.log" >&2
      printf "  Or run it now: /usr/local/share/comfort-shell/install-brew.sh\n\n" >&2
      unset _comfort_rc
    fi
  fi
  # Make brew available in this shell session.
  if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
    eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
  fi
fi
'
  fi
  rc_block="${rc_block}"'export PATH="$HOME/bin:$PATH"
# Load Homebrew (idempotent; covers non-login shells).
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
  eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
fi
# Prompt
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init '"$CHOSEN_SHELL"')"
fi
# Integrations
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook '"$CHOSEN_SHELL"')"
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init '"$CHOSEN_SHELL"')"
# Modern aliases
command -v eza >/dev/null 2>&1 && alias ls="eza --icons" && alias ll="eza -la --icons --git" && alias lt="eza --tree"
command -v bat >/dev/null 2>&1 && alias cat="bat"
command -v rg >/dev/null 2>&1 && alias grep="rg"
command -v fd >/dev/null 2>&1 && alias find="fd"
# Git shortcuts
alias gs="git status"
alias ga="git add"
alias gc="git commit"
alias gp="git push"'

  if [ "$CHOSEN_SHELL" = "zsh" ]; then
    # Zsh-specific: keybindings + plugin sources
    rc_block="${rc_block}"'
# Persistent history
HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
HISTSIZE=5000
SAVEHIST=5000
setopt appendhistory
setopt hist_ignore_all_dups
# Windows Terminal / xterm keybindings (zsh has no readline so these are needed)
bindkey "^[[1;5C" forward-word          # Ctrl+Right -> next word
bindkey "^[[1;5D" backward-word         # Ctrl+Left  -> previous word
bindkey "^[[H"    beginning-of-line     # Home
bindkey "^[[F"    end-of-line           # End
bindkey "^[[3~"   delete-char           # Delete
bindkey "^[[3;5~" kill-word             # Ctrl+Delete -> delete word forward
bindkey "^H"      backward-kill-word    # Ctrl+Backspace -> delete word back
# History search by current prefix
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
[[ -n "${key[Up]}"   ]] && bindkey -- "${key[Up]}"   up-line-or-beginning-search
[[ -n "${key[Down]}" ]] && bindkey -- "${key[Down]}" down-line-or-beginning-search
# Plugins
[ -f /etc/zsh_command_not_found ] && source /etc/zsh_command_not_found
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh'

    managed_block "$HOME/.zprofile" "comfort-shell" "$profile_block"
    managed_block "$HOME/.zshrc" "comfort-shell" "$rc_block"
    success "Wrote ~/.zprofile and ~/.zshrc managed blocks"
  else
    managed_block "$HOME/.profile" "comfort-shell" "$profile_block"
    managed_block "$HOME/.bashrc" "comfort-shell" "$rc_block"
    success "Wrote ~/.profile and ~/.bashrc managed blocks"
  fi
}

# =============================================================================
# HEAL KNOWN WSL ISSUES
# =============================================================================

heal_wsl_issues() {
  # Fix NUL bytes in /etc/wsl.conf that cause "Invalid key name" warnings
  if [ -f /etc/wsl.conf ] && [ "$DRY_RUN" -eq 0 ]; then
    if LC_ALL=C grep -qaP '\x00' /etc/wsl.conf 2>/dev/null; then
      warn "/etc/wsl.conf contains NUL bytes; healing..."
      if sudo sh -c 'tr -d "\0" < /etc/wsl.conf > /etc/wsl.conf.clean && mv /etc/wsl.conf.clean /etc/wsl.conf'; then
        info "Healed /etc/wsl.conf. Run 'wsl.exe --shutdown' after this finishes."
      fi
    fi
  fi
}

# =============================================================================
# MAIN FLOW
# =============================================================================

show_warning() {
  printf "\n"
  printf "${BOLD}${YELLOW}  ⚠️  WARNING ⚠️${NC}\n"
  printf "${YELLOW}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  if [ "$IS_SKEL_MODE" -eq 1 ]; then
    printf "${YELLOW}  Running as root — configuring this distro for the user${NC}\n"
    printf "${YELLOW}  that will be created on first launch. Changes include:${NC}\n"
    printf "${YELLOW}  /etc/skel dotfiles, default login shell, system packages.${NC}\n"
  else
    printf "${YELLOW}  This script will modify your WSL distro's shell defaults.${NC}\n"
    printf "${YELLOW}  Changes include: default shell, shell config files,${NC}\n"
    printf "${YELLOW}  installed packages, and PATH modifications.${NC}\n"
  fi
  printf "${YELLOW}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "\n"
}

apt_to_binary() {
  case "$1" in
    ripgrep) echo "rg" ;;
    fd-find) echo "fd" ;;
    *)       echo "$1" ;;
  esac
}

join_apt_names() {
  local out="" pkg name
  for pkg in "$@"; do
    name="$(apt_to_binary "$pkg")"
    out="${out:+$out, }$name"
  done
  printf '%s' "$out"
}

show_plan() {
  printf "${BOLD}  Plan:${NC}\n"
  printf "    Shell:       ${CYAN}%s${NC}\n" "$CHOSEN_SHELL"
  printf "    Prompt:      ${CYAN}%s${NC}\n" "$([ "$INSTALL_PROMPT" = "yes" ] && echo "starship" || echo "none")"
  if [ "$INSTALL_TOOLS" = "yes" ]; then
    printf "    CLI tools:   ${CYAN}%s${NC}\n" "$(join_apt_names "${COMFORT_APT_REQUIRED[@]}")"
    printf "                 ${DIM}+ optional: %s${NC}\n" "$(join_apt_names "${COMFORT_APT_OPTIONAL[@]}")"
  else
    printf "    CLI tools:   ${CYAN}skip${NC}\n"
  fi
  printf "    CLI shims:   ${CYAN}%s${NC}\n" "$([ "$INSTALL_SHIMS" = "yes" ] && echo "pbcopy, pbpaste, open, xdg-open" || echo "skip")"
  local brew_status="skip"
  if [ "$INSTALL_BREW" = "yes" ]; then
    if [ "$IS_SKEL_MODE" -eq 1 ]; then brew_status="deferred (runs on first shell launch)"; else brew_status="yes"; fi
    brew_status="$brew_status (formulae: gh, direnv, zoxide)"
  fi
  printf "    Homebrew:    ${CYAN}%s${NC}\n" "$brew_status"
  printf "    Git config:  ${CYAN}%s${NC}\n" "$([ "$INSTALL_GIT_DEFAULTS" = "yes" ] && echo "sensible defaults" || echo "skip")"
  printf "\n"
}

show_banner() {
  printf "\n"
  printf "${BOLD}${GREEN}   Distro configured. Ready for first user.${NC}\n"
  printf "\n"
  printf "  ${DIM}To open this shell anytime: wsl -d ${WSL_DISTRO_NAME:-Ubuntu}${NC}\n"
  if [ -n "$LOG_FILE" ]; then
    printf "  ${DIM}Log: $LOG_FILE${NC}\n"
  fi
  printf "\n"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) INTERACTIVE=0 ;;
      --shell=*)       CHOSEN_SHELL="${1#--shell=}" ;;
      --no-brew)       INSTALL_BREW="no" ;;
      --no-shims)      INSTALL_SHIMS="no" ;;
      --no-prompt)     INSTALL_PROMPT="no" ;;
      --no-tools)      INSTALL_TOOLS="no" ;;
      --minimal)       INSTALL_TOOLS="no"; INSTALL_BREW="no"; INSTALL_SHIMS="no" ;;
      --force)         FORCE_OVERWRITE=1 ;;
      --dry-run)       DRY_RUN=1 ;;
      --help|-h)       usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
    shift
  done

  # Validate shell choice
  case "$CHOSEN_SHELL" in
    zsh|bash) ;;
    *) die "Invalid shell choice: $CHOSEN_SHELL (supported: zsh, bash)" ;;
  esac
}

usage() {
  cat <<EOF
${BOLD}😎 Comfort Shell 😎${NC} - WSL shell customization

${BOLD}Usage:${NC}
  $SCRIPT_NAME [OPTIONS]

${BOLD}Options:${NC}
  --non-interactive   Accept all defaults without prompting (default: interactive)
  --shell=SHELL     Default shell: zsh (default) or bash
  --no-brew         Skip Homebrew
  --no-shims        Skip clipboard/open shims (pbcopy, pbpaste, open)
  --no-prompt       Skip starship prompt
  --no-tools        Skip CLI tools (fzf, rg, fd, bat, etc.)
  --minimal         Equivalent to --no-brew --no-shims --no-tools
  --force           Overwrite existing configs
  --dry-run         Preview changes without applying
  --help            Show this help

${BOLD}Examples:${NC}
  $SCRIPT_NAME                         # Step-by-step with prompts
  $SCRIPT_NAME --non-interactive       # Full setup, no questions asked
  $SCRIPT_NAME --shell=bash --no-brew  # Bash shell, skip Homebrew
  $SCRIPT_NAME --dry-run               # See what would change
EOF
}

interactive_configure() {
  printf "\n${BOLD}  Let's configure your shell:${NC}\n"

  CHOSEN_SHELL="$(choose "Which shell?" "$CHOSEN_SHELL" "zsh" "bash")"

  ask_toggle INSTALL_PROMPT       "Install starship prompt?"
  ask_toggle INSTALL_TOOLS        "Install modern CLI tools (fzf, rg, fd, ...)?"
  ask_toggle INSTALL_SHIMS        "Install CLI shims (pbcopy, pbpaste, open)?"
  ask_toggle INSTALL_BREW         "Install Homebrew?"
  ask_toggle INSTALL_GIT_DEFAULTS "Set sensible git defaults (main branch, no-rebase, autocrlf=input)?"
}

main() {
  parse_args "$@"
  setup_logging

  # Preflight checks
  if ! is_wsl; then
    die "This script is intended for WSL. Detected non-WSL environment."
  fi
  if [ ! -f /etc/os-release ]; then
    die "Cannot detect Linux distribution (missing /etc/os-release)."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    die "Unsupported distro: ${ID:-unknown}. Comfort Shell currently supports Ubuntu only."
  fi

  show_warning

  if [ "$INTERACTIVE" -eq 1 ]; then
    interactive_configure
  fi

  show_plan
  if ! confirm "Proceed with setup?" "y"; then
    info "Cancelled. No changes were made."
    exit 0
  fi

  if ! sudo -n true 2>/dev/null; then
    warn "sudo required. You'll be prompted for your password once."
    if [ "$DRY_RUN" -eq 0 ]; then
      sudo -v
    fi
  fi

  heal_wsl_issues

  mkdir -p "$HOME/bin" "$HOME/src"
  export PATH="$HOME/bin:$PATH"

  TOTAL_STEPS=$(count_steps)

  install_shell
  install_prompt
  install_cli_tools
  install_cli_shims
  install_homebrew
  install_git_defaults
  install_shell_config

  set_title "Comfort Shell · ready"
  show_banner
}

main "$@"
