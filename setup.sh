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

# This tracked file is user-level Codex config, not project-local config.
# Its non-standard source name prevents Codex loading it twice in this repo.
CODEX_USER_CONFIG=".codex/user-config.toml"
CODEX_LEGACY_CONFIG=".codex/config.toml"

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

link_codex_user_config() {
  local src="$DOTFILES_DIR/$CODEX_USER_CONFIG"
  local dest="$HOME/.codex/config.toml"
  local legacy_src="$DOTFILES_DIR/$CODEX_LEGACY_CONFIG"

  mkdir -p "$(dirname "$dest")"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$legacy_src" ]]; then
    rm -f "$dest"
    ln -s "$src" "$dest"
    replaced+=("~/.codex/config.toml (legacy link migrated)")
    success "~/.codex/config.toml legacy link migrated"
    return
  fi
  link_file "$src" "$dest" "~/.codex/config.toml"
}

link_skills_for_codex() {
  local skills_dest="$HOME/.agents/skills"
  local legacy_src="$DOTFILES_DIR/.claude/skills"
  local codex_src="$DOTFILES_DIR/.codex/skills/code-review"
  local skill src name target answer

  mkdir -p "$HOME/.agents"

  # Migrate the previously managed whole-tree link without treating it as a
  # user conflict. Other root conflicts retain setup's normal policy.
  if [[ -L "$skills_dest" && "$(readlink "$skills_dest")" == "$legacy_src" ]]; then
    rm "$skills_dest"
    mkdir -p "$skills_dest"
    replaced+=("~/.agents/skills (migrated to per-skill links)")
  elif [[ ! -d "$skills_dest" ]]; then
    if [[ -e "$skills_dest" || -L "$skills_dest" ]]; then
      if [[ "$MODE" == "skip" ]]; then
        skipped+=("~/.agents/skills")
        success "~/.agents/skills skipped (conflict)"
        return
      elif [[ "$MODE" == "prompt" ]]; then
        read -rp "  ~/.agents/skills already exists. Replace? [y/n]: " answer < /dev/tty
        if [[ "$answer" != "y" ]]; then
          skipped+=("~/.agents/skills")
          success "~/.agents/skills skipped (user chose)"
          return
        fi
      fi
      if [[ -L "$skills_dest" ]]; then
        rm "$skills_dest"
        replaced+=("~/.agents/skills")
      else
        rm -rf "${skills_dest}.bak"
        mv "$skills_dest" "${skills_dest}.bak"
        replaced+=("~/.agents/skills (prior saved to ~/.agents/skills.bak)")
      fi
    fi
    mkdir -p "$skills_dest"
  fi

  # Remove only links previously owned by this setup. This cleans deleted
  # skills and removes the two Claude Workflow skills from Codex discovery.
  while IFS= read -r skill; do
    target="$(readlink "$skill")"
    name="$(basename "$skill")"
    if [[ "$target" == "$legacy_src/"* || "$target" == "$DOTFILES_DIR/.codex/skills/"* ]]; then
      if [[ ! -e "$target" || "$name" == "comprehensive-code-review" || "$name" == "focused-code-review" ]]; then
        rm "$skill"
        info "Pruned Codex skill link: ${skill/#$HOME/~}"
      fi
    fi
  done < <(find "$skills_dest" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)

  while IFS= read -r src; do
    name="$(basename "$src")"
    [[ "$name" == "comprehensive-code-review" || "$name" == "focused-code-review" ]] && continue
    link_file "$src" "$skills_dest/$name" "~/.agents/skills/$name"
  done < <(find "$legacy_src" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/SKILL.md' \; -print | sort)

  link_file "$codex_src" "$skills_dest/code-review" "~/.agents/skills/code-review"
}

# --- Linux package lists (native, in-repo packages only) ---
# Name deltas: python3<->python, golang-go<->go, default-jdk<->jdk-openjdk.
# gh and nodejs need apt-repo bootstraps on Ubuntu (stale/absent by default),
# so they're excluded from APT_PACKAGES and handled by install_gh_apt/install_node_apt.
# Keep this list, PACMAN_PACKAGES below, and Brewfile in sync when adding a tool.
APT_PACKAGES=(zsh git vim python3 cmake tmux direnv golang-go default-jdk build-essential python3-dev pipx unzip jq graphviz)
PACMAN_PACKAGES=(zsh git vim python cmake tmux direnv go jdk-openjdk base-devel nodejs npm github-cli python-pipx unzip jq graphviz)

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

version_at_least() {
  local actual="$1" minimum="$2"
  awk -v actual="$actual" -v minimum="$minimum" '
    BEGIN {
      actual_count = split(actual, a, ".")
      minimum_count = split(minimum, m, ".")
      count = actual_count > minimum_count ? actual_count : minimum_count
      for (i = 1; i <= count; i++) {
        av = (i <= actual_count ? a[i] : 0) + 0
        mv = (i <= minimum_count ? m[i] : 0) + 0
        if (av > mv) exit 0
        if (av < mv) exit 1
      }
      exit 0
    }
  '
}

install_aws() {
  local minimum="2.35.0" actual="" installer=""
  if command -v aws &>/dev/null; then
    actual=$(aws --version 2>&1 | sed -nE 's#aws-cli/([0-9]+\.[0-9]+\.[0-9]+).*#\1#p' | head -1)
    if [[ -n "$actual" ]] && version_at_least "$actual" "$minimum"; then
      success "AWS CLI $actual satisfies >= $minimum"
      return 0
    fi
    info "AWS CLI ${actual:-unknown} is below $minimum; upgrading..."
  else
    info "Installing AWS CLI >= $minimum..."
  fi

  installer=$(mktemp)
  if ! curl -fsSL https://awscli.amazonaws.com/v2/install.sh -o "$installer"; then
    rm -f "$installer"
    error "AWS CLI installer download failed"
    return 1
  fi
  if ! bash "$installer"; then
    rm -f "$installer"
    error "AWS CLI installer failed"
    return 1
  fi
  rm -f "$installer"
  hash -r

  actual=$(aws --version 2>&1 | sed -nE 's#aws-cli/([0-9]+\.[0-9]+\.[0-9]+).*#\1#p' | head -1)
  if [[ -z "$actual" ]] || ! version_at_least "$actual" "$minimum"; then
    error "AWS CLI verification failed; expected >= $minimum, got ${actual:-missing}"
    return 1
  fi
  success "AWS CLI $actual installed"
}

install_uv() {
  local installer=""
  if command -v uvx &>/dev/null; then
    success "uvx already installed"
    return 0
  fi

  info "Installing uv/uvx..."
  installer=$(mktemp)
  if ! curl -fsSL https://astral.sh/uv/install.sh -o "$installer"; then
    rm -f "$installer"
    error "uv installer download failed"
    return 1
  fi
  if ! UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh "$installer"; then
    rm -f "$installer"
    error "uv installer failed"
    return 1
  fi
  rm -f "$installer"
  hash -r
  command -v uvx &>/dev/null || {
    error "uvx verification failed"
    return 1
  }
  success "uv/uvx installed"
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

install_docker() {
  command -v docker &>/dev/null && return
  info "Installing Docker..."
  if [[ "$PKG" == "apt" ]]; then
    # Docker's official apt repo (download.docker.com), same keyring pattern as
    # install_gh_apt/install_node_apt above. Distro id/codename from /etc/os-release.
    local distro codename
    distro="$(. /etc/os-release && echo "${ID}")"
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    if sudo install -m 0755 -d /etc/apt/keyrings \
      && curl -fsSL "https://download.docker.com/linux/${distro}/gpg" | sudo tee /etc/apt/keyrings/docker.asc >/dev/null \
      && sudo chmod a+r /etc/apt/keyrings/docker.asc \
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null \
      && sudo apt-get update \
      && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
      :
    else
      warn "Docker apt repo setup failed; cleaning up partial state"
      sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
      return 1
    fi
  else
    sudo pacman -S --needed --noconfirm docker   # Docker has no Arch repo
  fi
  command -v docker &>/dev/null || { warn "docker install failed"; return 1; }
  sudo usermod -aG docker "$(id -un)" || warn "usermod -aG docker failed"
  # systemd running (normal distros, Arch, WSL2+systemd) -> systemctl; else SysV (WSL2 no systemd).
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl enable --now docker || warn "systemctl enable docker failed"
  else
    sudo service docker start || warn "service docker start failed"
  fi
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

  install_docker || warn "docker install failed"

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
    # Codex-only skills are exposed through ~/.agents/skills, not duplicated
    # under ~/.codex/skills by the path-for-path config linker.
    [[ "$path" == .codex/skills/* ]] && continue
    [[ "$path" == "$CODEX_USER_CONFIG" || "$path" == "$CODEX_LEGACY_CONFIG" ]] && continue
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

codex_config_src="$DOTFILES_DIR/$CODEX_USER_CONFIG"
codex_config_dest="$HOME/.codex/config.toml"
codex_legacy_config_src="$DOTFILES_DIR/$CODEX_LEGACY_CONFIG"
if [[ ! -L "$codex_config_dest" || "$(readlink "$codex_config_dest")" != "$codex_config_src" ]]; then
  if [[ ! -L "$codex_config_dest" || "$(readlink "$codex_config_dest")" != "$codex_legacy_config_src" ]]; then
    if [[ -e "$codex_config_dest" || -L "$codex_config_dest" ]]; then
      conflicts+=("~/.codex/config.toml")
    fi
  fi
fi

# Codex discovers user-authored skills under ~/.agents/skills. Setup owns its
# individual links while preserving unrelated entries in the real directory.
shared_skills_src="$DOTFILES_DIR/.claude/skills"
shared_skills_dest="$HOME/.agents/skills"
if [[ -L "$shared_skills_dest" && "$(readlink "$shared_skills_dest")" == "$shared_skills_src" ]]; then
  : # Legacy setup-owned link; migrate automatically.
elif [[ -e "$shared_skills_dest" && ! -d "$shared_skills_dest" || -L "$shared_skills_dest" ]]; then
  conflicts+=("~/.agents/skills")
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
    [[ "$path" == .codex/skills/* ]] && continue
    [[ "$path" == "$CODEX_USER_CONFIG" || "$path" == "$CODEX_LEGACY_CONFIG" ]] && continue
    rel="${path#"$prefix"/}"
    dest="$HOME/$prefix/$rel"
    mkdir -p "$(dirname "$dest")"
    link_file "$DOTFILES_DIR/$path" "$dest" "~/$prefix/$rel"
  done < <(git -C "$DOTFILES_DIR" ls-files -z -- "$prefix")
done

link_codex_user_config

link_skills_for_codex

# Ensure hook scripts are executable (git may not preserve +x on all systems)
find "$HOME/.claude/hooks" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Prune symlinks whose repo target no longer exists (file deleted/renamed in
# dotfiles) — otherwise dead agents/hooks linger forever. Covers the same
# prefixes we link above.
for prefix in .claude .codex .config; do
  while IFS= read -r link; do
    target=$(readlink "$link")
    if [[ "$target" == "$DOTFILES_DIR/$prefix/"* && ! -e "$target" ]]; then
      rm "$link"
      info "Pruned dangling symlink: ${link/#$HOME/~}"
    fi
  done < <(find "$HOME/$prefix" -maxdepth 3 -type l -not -path "*/plugins/*" 2>/dev/null)
done

find "$HOME/.codex/hooks" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Register the git clean filter that strips Codex-managed [hooks.state] from
# .codex/user-config.toml on commit. The working file (symlinked to
# ~/.codex/config.toml) keeps
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
# pipx/Claude/Codex->~/.local/bin, deno->~/.deno/bin, pnpm->~/.local/share/pnpm/bin
# (v11 shim layout), supabase->~/.supabase/bin; trufflehog installs straight to
# /usr/local/bin, already on PATH).
export PATH="$HOME/.local/bin:$HOME/.deno/bin:$HOME/.local/share/pnpm/bin:$HOME/.supabase/bin:$PATH"

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

aws_status="installed"
if ! install_aws; then
  aws_status="FAILED"
  setup_failed=1
fi

uv_status="installed"
if ! install_uv; then
  uv_status="FAILED"
  setup_failed=1
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
  claude plugin marketplace add github:aws/agent-toolkit-for-aws 2>/dev/null || true

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

# Plugin selection is declarative: .codex/plugins.txt is authoritative.
codex_plugins_status="skipped (codex CLI not found)"

if command -v codex &>/dev/null && [[ -f "$DOTFILES_DIR/.codex/plugins.txt" ]]; then
  info "Installing and verifying Codex plugins..."
  if bash "$DOTFILES_DIR/.codex/install-plugins.sh" "$DOTFILES_DIR"; then
    codex_plugins_status="installed"
    info "Stripe, Supabase, and PostHog may require interactive connector OAuth."
  else
    codex_plugins_status="FAILED"
    setup_failed=1
  fi
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
echo "AWS CLI: $aws_status"
echo "uv/uvx: $uv_status"
echo "Vim plugins: $vim_plugins_status"
echo "YouCompleteMe: $ycm_status"
echo "Claude plugins: $plugins_status"
echo "Codex plugins: $codex_plugins_status"
echo ""
if [[ "$aws_status" == "installed" ]]; then
  echo "AWS authentication remains manual. For Outsidey:"
  echo "  aws login --profile Outsidey --region eu-west-1"
  echo "  AWS_PROFILE=Outsidey aws sts get-caller-identity"
fi
if [[ "$codex_plugins_status" == "installed" ]]; then
  echo "Open Codex /plugins to complete Stripe, Supabase, and PostHog OAuth."
  echo "Set PostHog permissions to 'Any changes' and select Outsidey project 107700."
fi
echo "Open Codex /hooks to review the new AWS MCP read-only hook by exact hash."
echo "Done."

exit "${setup_failed:-0}"
