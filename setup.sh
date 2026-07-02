#!/usr/bin/env bash
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR"

# --- Files to symlink ---
DOTFILES=(
  .zshrc
  .zprofile
  .gitconfig
  .gitignore
  .vimrc
  .ideavimrc
  .tmux.conf
)

# --- Helpers ---
info()    { printf '[INFO] %s\n' "$1"; }
success() { printf '[OK]   %s\n' "$1"; }
warn()    { printf '[WARN] %s\n' "$1"; }
error()   { printf '[ERR]  %s\n' "$1" >&2; }

# --- Tracking ---
linked=()
replaced=()
skipped=()

# --- Mode-aware symlink creation ---
link_file() {
  local src="$1"
  local dest="$2"
  local label="$3"

  if [[ ! -e "$src" ]]; then
    warn "$label source not found, skipping"
    skipped+=("$label (source missing)")
    return
  fi

  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    skipped+=("$label")
    success "$label already linked"
    return
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$MODE" == "skip" ]]; then
      skipped+=("$label")
      success "$label skipped (conflict)"
      return
    elif [[ "$MODE" == "prompt" ]]; then
      read -rp "  $label already exists. Replace? [y/n]: " answer < /dev/tty
      if [[ "$answer" != "y" ]]; then
        skipped+=("$label")
        success "$label skipped (user chose)"
        return
      fi
    fi
    rm -f "$dest"
    replaced+=("$label")
  fi

  ln -s "$src" "$dest"
  linked+=("$label")
  success "$label linked"
}

is_codex_runtime_rel() {
  local rel="$1"
  case "$rel" in
    auth.json|history.jsonl|installation_id|models_cache.json|version.json|.personality_migration)
      return 0
      ;;
    cache/*|.tmp/*|tmp/*|log/*|logs_*|state_*|goals_*|memories_*|memories/*|session_index.jsonl|shell_snapshots/*|app-server-control/*|app-server-daemon/*)
      return 0
      ;;
  esac
  return 1
}

# --- Linux package lists (native, in-repo packages only) ---
# Name deltas: python3<->python, golang-go<->go, default-jdk<->jdk-openjdk.
# gh and nodejs need apt-repo bootstraps on Ubuntu (stale/absent by default),
# so they're excluded from APT_PACKAGES and handled by install_gh_apt/install_node_apt.
# Keep this list, PACMAN_PACKAGES below, and Brewfile in sync when adding a tool.
APT_PACKAGES=(zsh git vim python3 cmake tmux golang-go default-jdk build-essential python3-dev pipx unzip jq)
PACMAN_PACKAGES=(zsh git vim python cmake tmux go jdk-openjdk base-devel nodejs npm github-cli python-pipx unzip jq)

install_gh_apt() {
  command -v gh &>/dev/null && return
  info "Adding GitHub CLI apt repo..."
  if sudo mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
    && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
    && sudo apt-get update \
    && sudo apt-get install -y gh; then
    return 0
  fi
  # ponytail: repo/keyring partially written above; wipe it so a re-run
  # re-derives cleanly instead of re-failing the same broken state forever.
  warn "GitHub CLI apt repo setup failed; cleaning up partial state"
  sudo rm -f /etc/apt/sources.list.d/github-cli.list /etc/apt/keyrings/githubcli-archive-keyring.gpg
  return 1
}

install_node_apt() {
  command -v node &>/dev/null && return
  info "Adding NodeSource apt repo..."
  # ponytail: paths below are NodeSource's own install locations, not ours;
  # re-check if their setup script changes them.
  if (curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -) \
    && sudo apt-get install -y nodejs; then
    return 0
  fi
  warn "NodeSource apt repo setup failed; cleaning up partial state"
  sudo rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/keyrings/nodesource.gpg
  return 1
}

# --- Cross-distro installs (official scripts, identical on apt + pacman) ---
# ponytail: these (and the gh keyring above) pull unpinned scripts/keys straight
# from upstream with no checksum/signature check - accepted risk for a personal
# dotfiles repo. Pin/verify if this ever runs somewhere that matters more.

# ponytail: these installers default to appending PATH blocks to the active
# shell rc file, which by Section 3 is a symlink into this repo - the env
# vars/flags below redirect or suppress that so a run never dirties the
# tracked .zshrc. Re-verify on major version bumps of each tool.
install_deno() {
  command -v deno &>/dev/null && return
  info "Installing deno..."
  # CI=1 skips deno's interactive shell-rc setup entirely.
  CI=1 DENO_INSTALL="$HOME/.deno" sh -c "$(curl -fsSL https://deno.land/install.sh)"
}
install_pnpm() {
  command -v pnpm &>/dev/null && return
  info "Installing pnpm..."
  # No official skip flag; pnpm's sh/dash path writes its PATH block to $ENV
  # instead of ~/.zshrc when SHELL=/bin/sh, so point $ENV at a throwaway file.
  local rc_sink
  rc_sink="$(mktemp)"
  SHELL=/bin/sh ENV="$rc_sink" PNPM_HOME="$HOME/.local/share/pnpm" sh -c "$(curl -fsSL https://get.pnpm.io/install.sh)"
  rm -f "$rc_sink"
}
install_trufflehog() { command -v trufflehog &>/dev/null || { info "Installing trufflehog..."; curl -fsSL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sudo sh -s -- -b /usr/local/bin; }; }
install_semgrep()    { command -v semgrep &>/dev/null    || { info "Installing semgrep...";    pipx install semgrep; }; }
install_supabase() {
  command -v supabase &>/dev/null && return
  info "Installing supabase CLI..."
  # SUPABASE_INSTALL_DIR is script-internal (not read for the skip decision);
  # --no-modify-path is the flag that actually suppresses the rc write.
  SUPABASE_INSTALL_DIR="$HOME/.supabase/bin" bash -c "$(curl -fsSL https://raw.githubusercontent.com/supabase/cli/main/install)" -- --no-modify-path
}

install_packages_linux() {
  if [[ "$PKG" == "apt" ]]; then
    info "Installing packages via apt..."
    sudo apt-get update
    sudo apt-get install -y "${APT_PACKAGES[@]}"
    install_gh_apt
    install_node_apt
  else
    info "Installing packages via pacman..."
    sudo pacman -Syu --needed --noconfirm "${PACMAN_PACKAGES[@]}"
  fi

  # Each optional tool's install dir, put on PATH now so the presence checks
  # below see it in this same run (mirrors what .zprofile does for future
  # login shells: pipx->~/.local/bin, deno->~/.deno/bin,
  # pnpm->~/.local/share/pnpm, supabase->~/.supabase/bin; trufflehog installs
  # straight to /usr/local/bin, already on PATH).
  export PATH="$HOME/.local/bin:$HOME/.deno/bin:$HOME/.local/share/pnpm:$HOME/.supabase/bin:$PATH"

  optional_status=""
  for tool in deno pnpm trufflehog semgrep supabase; do
    declare -F "install_$tool" >/dev/null || { error "internal: install_$tool undefined"; exit 1; }
    if "install_$tool"; then :; else warn "$tool install failed"; fi
    if command -v "$tool" &>/dev/null; then
      optional_status+=" $tool=ok"
    else
      optional_status+=" $tool=missing"
    fi
  done
}

# =============================================================================
# Section 1: Preflight Checks
# =============================================================================

case "$(uname -s)" in
  Darwin)
    OS="macos"
    if ! xcode-select -p &>/dev/null; then
      error "Xcode Command Line Tools not found. Install them with:"
      echo "  xcode-select --install"
      exit 1
    fi
    ;;
  Linux)
    OS="linux"
    if command -v apt-get &>/dev/null; then
      PKG="apt"
    elif command -v pacman &>/dev/null; then
      PKG="pacman"
    else
      error "Unsupported Linux distro (need apt or pacman)."
      exit 1
    fi
    if ! command -v sudo &>/dev/null; then
      error "sudo not found; required for native package installs."
      exit 1
    fi
    if ! command -v curl &>/dev/null; then
      error "curl not found; required for package and tool installs."
      exit 1
    fi
    ;;
  *)
    error "Unsupported OS: $(uname -s)"
    exit 1
    ;;
esac

# =============================================================================
# Section 2: Conflict Detection
# =============================================================================

conflicts=()

for file in "${DOTFILES[@]}"; do
  src="$DOTFILES_DIR/$file"
  dest="$HOME/$file"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    continue
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    conflicts+=("$file")
  fi
done

while IFS= read -r -d '' file; do
  rel="${file#"$DOTFILES_DIR"/.claude/}"
  dest="$HOME/.claude/$rel"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$file" ]]; then
    continue
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    conflicts+=("~/.claude/$rel")
  fi
done < <(find "$DOTFILES_DIR/.claude" -type f -not -name "*.local.*" -print0)

if [[ -d "$DOTFILES_DIR/.codex" ]]; then
  while IFS= read -r -d '' file; do
    rel="${file#"$DOTFILES_DIR"/.codex/}"
    is_codex_runtime_rel "$rel" && continue
    dest="$HOME/.codex/$rel"
    if [[ -L "$dest" && "$(readlink "$dest")" == "$file" ]]; then
      continue
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
      conflicts+=("~/.codex/$rel")
    fi
  done < <(find "$DOTFILES_DIR/.codex" -type f -not -name "*.local.*" -print0)
fi

while IFS= read -r -d '' file; do
  rel="${file#"$DOTFILES_DIR"/.config/}"
  dest="$HOME/.config/$rel"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$file" ]]; then
    continue
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    conflicts+=("~/.config/$rel")
  fi
done < <(find "$DOTFILES_DIR/.config" -type f -print0)

MODE="replace"
if [[ ${#conflicts[@]} -gt 0 ]]; then
  echo "The following files already exist and will need replacement:"
  for c in "${conflicts[@]}"; do
    echo "  - $c"
  done
  echo ""
  echo "How would you like to handle conflicts?"
  echo "  1) Replace — overwrite all conflicts"
  echo "  2) Skip — only link files that don't exist yet"
  echo "  3) Prompt — decide file-by-file"
  echo ""
  read -rp "Choose [1/2/3]: " choice < /dev/tty

  case "$choice" in
    1) MODE="replace" ;;
    2) MODE="skip" ;;
    3) MODE="prompt" ;;
    *)
      error "Invalid choice. Aborting."
      exit 1
      ;;
  esac
fi

# =============================================================================
# Section 3: Create Symlinks
# =============================================================================

info "Creating symlinks..."

for file in "${DOTFILES[@]}"; do
  link_file "$DOTFILES_DIR/$file" "$HOME/$file" "$file"
done

# =============================================================================
# Section 4: Claude Code Symlinks
# =============================================================================

info "Creating Claude Code symlinks..."
mkdir -p ~/.claude

while IFS= read -r -d '' file; do
  rel="${file#"$DOTFILES_DIR"/.claude/}"
  dest="$HOME/.claude/$rel"
  mkdir -p "$(dirname "$dest")"
  link_file "$file" "$dest" "~/.claude/$rel"
done < <(find "$DOTFILES_DIR/.claude" -type f -not -name "*.local.*" -print0)

# Ensure hook scripts are executable (git may not preserve +x on all systems)
find "$HOME/.claude/hooks" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# =============================================================================
# Section 4a: Codex Symlinks
# =============================================================================

info "Creating Codex symlinks..."
mkdir -p "$HOME/.codex"

if [[ -d "$DOTFILES_DIR/.codex" ]]; then
  while IFS= read -r -d '' file; do
    rel="${file#"$DOTFILES_DIR"/.codex/}"
    is_codex_runtime_rel "$rel" && continue
    dest="$HOME/.codex/$rel"
    mkdir -p "$(dirname "$dest")"
    link_file "$file" "$dest" "~/.codex/$rel"
  done < <(find "$DOTFILES_DIR/.codex" -type f -not -name "*.local.*" -print0)
fi

find "$HOME/.codex/hooks" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Register the git clean filter that strips Codex-managed [hooks.state] from
# .codex/config.toml on commit. The working file (symlinked into ~/.codex) keeps
# the section so hook-trust survives; git just never sees the machine-specific
# churn. Filter definitions live in git config (not .gitattributes) for security.
if command -v git >/dev/null 2>&1 && [[ -d "$DOTFILES_DIR/.git" ]]; then
  git -C "$DOTFILES_DIR" config filter.codex-strip-hooks-state.clean ".codex/strip-hooks-state.sh"
  git -C "$DOTFILES_DIR" config filter.codex-strip-hooks-state.smudge cat
  git -C "$DOTFILES_DIR" config filter.codex-strip-hooks-state.required false
fi

# =============================================================================
# Section 4b: XDG Config Symlinks
# =============================================================================

info "Creating ~/.config symlinks..."

while IFS= read -r -d '' file; do
  rel="${file#"$DOTFILES_DIR"/.config/}"
  dest="$HOME/.config/$rel"
  mkdir -p "$(dirname "$dest")"
  link_file "$file" "$dest" "~/.config/$rel"
done < <(find "$DOTFILES_DIR/.config" -type f -print0)

# =============================================================================
# Section 5: Create Required Directories
# =============================================================================

mkdir -p ~/.vim/undodir
mkdir -p ~/.vim/plugged

# =============================================================================
# Section 6: Install Packages
# =============================================================================

if [[ "$OS" == "macos" ]]; then
  brew_status="already installed"

  if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew_status="freshly installed"

    # Ensure brew is on PATH for the rest of this script
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi

  info "Running brew bundle..."
  brew bundle --file="$DOTFILES_DIR/Brewfile"
  pkg_summary="Homebrew: $brew_status"
else
  install_packages_linux
  pkg_summary="Packages ($PKG): installed"
fi

# =============================================================================
# Section 7: Install Claude Code
# =============================================================================

claude_status="already installed"

if ! command -v claude &>/dev/null; then
  info "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
  claude_status="freshly installed"
fi

# =============================================================================
# Section 8: Install Vim Plugins
# =============================================================================

ycm_dir="$HOME/.vim/plugged/YouCompleteMe"
vim_plugins_status="installed"
if [[ -f "$ycm_dir/install.py" ]]; then
  vim_plugins_status="already installed"
  success "Vim plugins already installed, skipping"
else
  info "Installing vim plugins..."
  vim +PlugInstall +qall
fi

ycm_status="installed"
if [[ ! -f "$ycm_dir/install.py" ]]; then
  warn "YouCompleteMe install.py not found, skipping compilation"
  ycm_status="skipped (not found)"
elif compgen -G "$ycm_dir/third_party/ycmd/ycm_core.*.so" > /dev/null 2>&1; then
  ycm_status="already compiled"
  success "YouCompleteMe already compiled, skipping"
else
  info "Compiling YouCompleteMe..."
  python3 "$ycm_dir/install.py" --ts-completer
fi

# =============================================================================
# Section 9: Install Claude Code Plugins
# =============================================================================

plugins_status="skipped (claude CLI not found)"

if command -v claude &>/dev/null; then
  info "Registering third-party marketplaces..."
  claude plugin marketplace add github:JuliusBrussee/caveman 2>/dev/null || true
  claude plugin marketplace add github:openai/codex-plugin-cc 2>/dev/null || true

  info "Installing Claude Code plugins..."
  plugins_status="installed"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if claude plugin install "$line" --scope user 2>/dev/null; then
      success "Plugin: $line"
    else
      warn "Plugin already installed or failed: $line"
    fi
  done < "$DOTFILES_DIR/.claude/plugins.txt"
fi

# =============================================================================
# Section 9b: Install Codex Plugins
# =============================================================================

codex_plugins_status="skipped (codex CLI not found)"

if command -v codex &>/dev/null && [[ -f "$DOTFILES_DIR/.codex/plugins.txt" ]]; then
  info "Installing Codex plugins..."
  codex_plugins_status="installed"
  available_plugins=$(codex plugin list 2>/dev/null | awk 'NF {print $1}' || true)
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! printf '%s\n' "$available_plugins" | grep -qx "$line"; then
      warn "Codex plugin not in marketplace snapshot: $line"
      continue
    fi
    if codex plugin add "$line" 2>/dev/null; then
      success "Codex plugin: $line"
    else
      warn "Codex plugin already installed or failed: $line"
    fi
  done < "$DOTFILES_DIR/.codex/plugins.txt"
fi

# =============================================================================
# Section 10: Summary
# =============================================================================

echo ""
echo "=== Summary ==="

if [[ ${#linked[@]} -gt 0 ]]; then
  echo "Linked:"
  for f in "${linked[@]}"; do echo "  + $f"; done
fi

if [[ ${#replaced[@]} -gt 0 ]]; then
  echo "Replaced:"
  for f in "${replaced[@]}"; do echo "  ~ $f"; done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Skipped (already correct):"
  for f in "${skipped[@]}"; do echo "  - $f"; done
fi

echo "$pkg_summary"
[[ -n "${optional_status:-}" ]] && echo "Optional tools:$optional_status"
echo "Claude Code: $claude_status"
echo "Vim plugins: $vim_plugins_status"
echo "YouCompleteMe: $ycm_status"
echo "Claude plugins: $plugins_status"
echo "Codex plugins: $codex_plugins_status"
echo ""
echo "Done."
