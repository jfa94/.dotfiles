#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/..." in labels/messages is display text, not a path
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
    if [[ -L "$dest" ]]; then
      rm -f "$dest"
      replaced+=("$label")
    else
      rm -rf "${dest}.bak"
      mv "$dest" "${dest}.bak"
      replaced+=("$label (prior saved to $label.bak)")
    fi
  fi

  ln -s "$src" "$dest"
  linked+=("$label")
  success "$label linked"
}

link_claude_skills_for_codex() {
  mkdir -p "$HOME/.agents"
  link_file "$DOTFILES_DIR/.claude/skills" "$HOME/.agents/skills" "~/.agents/skills"
}

# --- Linux package lists (native, in-repo packages only) ---
# Name deltas: python3<->python, golang-go<->go, default-jdk<->jdk-openjdk.
# gh and nodejs need apt-repo bootstraps on Ubuntu (stale/absent by default),
# so they're excluded from APT_PACKAGES and handled by install_gh_apt/install_node_apt.
# Keep this list, PACMAN_PACKAGES below, and Brewfile in sync when adding a tool.
APT_PACKAGES=(zsh git vim python3 cmake tmux golang-go default-jdk build-essential python3-dev pipx unzip jq graphviz)
PACMAN_PACKAGES=(zsh git vim python cmake tmux go jdk-openjdk base-devel nodejs npm github-cli python-pipx unzip jq graphviz)

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
# ponytail: these, the gh keyring above, and the Homebrew/Claude/Codex installers in
# Sections 6-7 pull unpinned scripts/keys straight from upstream with no
# checksum/signature check - accepted risk for a personal dotfiles repo.
# Pin/verify if this ever runs somewhere that matters more.

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

install_codex() {
  local codex_path="" resolved_path=""
  local managed_root="$HOME/.codex/packages/standalone"

  codex_path="$(command -v codex 2>/dev/null || true)"
  if [[ -n "$codex_path" ]]; then
    managed_root="$(realpath "$managed_root" 2>/dev/null || printf '%s' "$managed_root")"
    resolved_path="$(realpath "$codex_path" 2>/dev/null || true)"
    if [[ "$codex_path" == "$HOME/.local/bin/codex" \
      && "$resolved_path" == "$managed_root/releases/"*/bin/codex \
      && -x "$resolved_path" ]]; then
      codex_status="already installed"
      success "Codex CLI already installed (standalone), skipping"
      return 0
    fi

    error "Codex CLI is managed outside OpenAI's standalone installer: $codex_path"
    error "Remove it first (Homebrew: 'brew uninstall --cask codex'; npm: 'npm uninstall -g @openai/codex'), then re-run setup."
    return 1
  fi

  info "Installing Codex CLI..."
  CODEX_NON_INTERACTIVE=1 sh -c "$(curl -fsSL https://chatgpt.com/codex/install.sh)"
  codex_path="$(command -v codex 2>/dev/null || true)"
  managed_root="$(realpath "$managed_root" 2>/dev/null || printf '%s' "$managed_root")"
  resolved_path="$(realpath "$codex_path" 2>/dev/null || true)"
  if [[ "$codex_path" != "$HOME/.local/bin/codex" \
    || "$resolved_path" != "$managed_root/releases/"*/bin/codex \
    || ! -x "$resolved_path" ]]; then
    error "Codex standalone installer completed without a valid managed CLI."
    return 1
  fi
  codex_status="freshly installed"
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

if ! command -v git &>/dev/null; then
  error "git not found; required to enumerate the repo's tracked config files."
  exit 1
fi

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

# Tracked files only (git ls-files): runtime junk that Claude Code/Codex drop
# inside these dirs (worktrees/, auth.json, ...) is gitignored, so git already
# knows what belongs to the repo — no hand-maintained exclusion lists.
for prefix in .claude .codex .config; do
  while IFS= read -r -d '' path; do
    rel="${path#"$prefix"/}"
    dest="$HOME/$prefix/$rel"
    if [[ -L "$dest" && "$(readlink "$dest")" == "$DOTFILES_DIR/$path" ]]; then
      continue
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
      conflicts+=("~/$prefix/$rel")
    fi
  done < <(git -C "$DOTFILES_DIR" ls-files -z -- "$prefix")
done

# Codex discovers user-authored skills under ~/.agents/skills. Keep Claude's
# directory as the source of truth and expose the entire tree without copies.
shared_skills_src="$DOTFILES_DIR/.claude/skills"
shared_skills_dest="$HOME/.agents/skills"
if [[ ! -L "$shared_skills_dest" || "$(readlink "$shared_skills_dest")" != "$shared_skills_src" ]]; then
  if [[ -e "$shared_skills_dest" || -L "$shared_skills_dest" ]]; then
    conflicts+=("~/.agents/skills")
  fi
fi

# DOTFILES_MODE=replace|skip|prompt skips the interactive conflict prompt
# (headless/CI runs have no /dev/tty).
MODE="${DOTFILES_MODE:-replace}"
if [[ ! "$MODE" =~ ^(replace|skip|prompt)$ ]]; then
  error "Invalid DOTFILES_MODE '$MODE' (expected replace, skip, or prompt)."
  exit 1
fi
if [[ ${#conflicts[@]} -gt 0 && -z "${DOTFILES_MODE:-}" ]]; then
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
# Section 4: Claude Code / Codex / XDG Config Symlinks
# =============================================================================

# Tracked files only — see the Section 2 comment.
for prefix in .claude .codex .config; do
  info "Creating ~/$prefix symlinks..."
  while IFS= read -r -d '' path; do
    rel="${path#"$prefix"/}"
    dest="$HOME/$prefix/$rel"
    mkdir -p "$(dirname "$dest")"
    link_file "$DOTFILES_DIR/$path" "$dest" "~/$prefix/$rel"
  done < <(git -C "$DOTFILES_DIR" ls-files -z -- "$prefix")
done

link_claude_skills_for_codex

# Ensure hook scripts are executable (git may not preserve +x on all systems)
find "$HOME/.claude/hooks" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Prune symlinks whose repo target no longer exists (file deleted/renamed in
# dotfiles) — otherwise dead agents/hooks linger in ~/.claude forever.
while IFS= read -r link; do
  target=$(readlink "$link")
  if [[ "$target" == "$DOTFILES_DIR/.claude/"* && ! -e "$target" ]]; then
    rm "$link"
    info "Pruned dangling symlink: ${link/#$HOME/~}"
  fi
done < <(find "$HOME/.claude" -maxdepth 3 -type l -not -path "*/plugins/*" 2>/dev/null)

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
# Section 5: Create Required Directories
# =============================================================================

mkdir -p ~/.vim/undodir
mkdir -p ~/.vim/plugged

# =============================================================================
# Section 6: Install Packages
# =============================================================================

# Each tool's install dir, put on PATH now so presence checks later in this
# run see it (mirrors what .zprofile does for future login shells:
# pipx/Claude/Codex->~/.local/bin, deno->~/.deno/bin, pnpm->~/.local/share/pnpm,
# supabase->~/.supabase/bin; trufflehog installs straight to /usr/local/bin,
# already on PATH).
export PATH="$HOME/.local/bin:$HOME/.deno/bin:$HOME/.local/share/pnpm:$HOME/.supabase/bin:$PATH"

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
  if brew bundle --file="$DOTFILES_DIR/Brewfile"; then
    pkg_summary="Homebrew: $brew_status"
  else
    warn "brew bundle failed; continuing with remaining sections"
    pkg_summary="Homebrew: $brew_status (bundle FAILED — re-run 'brew bundle' manually)"
  fi
else
  install_packages_linux
  pkg_summary="Packages ($PKG): installed"
fi

# Codex must use OpenAI's managed standalone layout. Install after package
# setup (curl is now available) and before Codex plugin installation.
codex_status="not installed"
install_codex

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
  claude plugin marketplace add github:openai/codex-plugin-cc 2>/dev/null || true
  claude plugin marketplace add github:jfa94/factory 2>/dev/null || true
  claude plugin marketplace add github:DietrichGebert/ponytail 2>/dev/null || true

  info "Installing Claude Code plugins..."
  plugins_status="installed"

  # plugin install flips enabledPlugins to true through the settings.json
  # symlink; snapshot before and merge-restore after so existing values win
  # while newly installed plugins keep the key the installer wrote
  settings_file="$DOTFILES_DIR/.claude/settings.json"
  plugins_snapshot=""
  if command -v jq &>/dev/null && [[ -f "$settings_file" ]]; then
    plugins_snapshot=$(jq '.enabledPlugins // {}' "$settings_file")
  else
    warn "jq or settings.json missing; enabledPlugins may get flipped by plugin installs"
  fi

  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if claude plugin install "$line" --scope user 2>/dev/null; then
      success "Plugin: $line"
    else
      warn "Plugin already installed or failed: $line"
    fi
  done < "$DOTFILES_DIR/.claude/plugins.txt"

  if [[ -n "$plugins_snapshot" ]]; then
    # write via the repo path, never the ~/.claude symlink (mv would replace it)
    jq --argjson snap "$plugins_snapshot" \
      '.enabledPlugins = ((.enabledPlugins // {}) + $snap)' \
      "$settings_file" > "$settings_file.tmp" && mv "$settings_file.tmp" "$settings_file"
  fi
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
echo "Codex CLI: $codex_status"
echo "Vim plugins: $vim_plugins_status"
echo "YouCompleteMe: $ycm_status"
echo "Claude plugins: $plugins_status"
echo "Codex plugins: $codex_plugins_status"
echo ""
echo "Done."
