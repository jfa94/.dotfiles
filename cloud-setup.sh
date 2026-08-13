#!/bin/bash
# Cloud environment bootstrap for Claude Code (claude.ai/code).
# Runs as root at environment build time, before Claude Code launches.
# Invoked by the environment setup-script shim (see docs/cloud-environments.md).
# Must ALWAYS exit 0: a nonzero exit fails the whole environment build, and a
# degraded environment beats no environment. Failures are collected + reported.

set -uo pipefail

DOTFILES_DIR="$HOME/.dotfiles"
FAILURES=()

# Everything below is mirrored to $LOG so failures survive into the session
# (the harness does not persist setup-script stdout). Verbose installer output
# goes to $LOG only, keeping the build UI readable.
LOG="${CLOUD_SETUP_LOG:-/tmp/cloud-setup.log}"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

# keep in sync with setup.sh helpers
info() { printf '\033[34m[INFO]\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$1"; }
success() { printf '\033[32m[OK]\033[0m %s\n' "$1"; }
note_fail() {
  FAILURES+=("$1")
  warn "$1"
}

info "cloud-setup: user=$(whoami) HOME=$HOME ($(uname -sm))"

# Build-time PATH for everything installed below; sessions get ~/.local/bin
# on PATH already (spike-verified), so installs target ~/.local/bin.
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.local/bin"

# =============================================================================
# Section 1: Dotfiles repo (shim normally cloned it already)
# =============================================================================

if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/jfa94/.dotfiles.git "$DOTFILES_DIR" \
    || { note_fail "dotfiles clone failed; nothing to set up"; exit 0; }
fi

# =============================================================================
# Section 2: apt packages (check-first; base image has node/npm/pnpm/uvx/gh)
# =============================================================================

apt_missing=()
for pkg in jq shellcheck; do
  command -v "$pkg" &>/dev/null || apt_missing+=("$pkg")
done
if ((${#apt_missing[@]})); then
  apt-get install -y "${apt_missing[@]}" >>"$LOG" 2>&1 \
    || note_fail "apt install failed: ${apt_missing[*]}"
fi

# =============================================================================
# Section 3: Recreate ~/.claude and ~/.codex via symlinks
# keep in sync with setup.sh section 4 (symlink loop + link_codex_user_config)
# =============================================================================

# User-level Codex config and hooks use non-discovered source names and are
# linked separately to their runtime names under ~/.codex.
CODEX_USER_CONFIG=".codex/user-config.toml"
CODEX_LEGACY_CONFIG=".codex/config.toml"
CODEX_USER_HOOKS=".codex/user-hooks.json"
CODEX_LEGACY_HOOKS=".codex/hooks.json"

link_count=0
while IFS= read -r -d '' path; do
  [[ "$path" == .codex/skills/* ]] && continue
  # Claude skill contents ride the per-skill directory links below.
  [[ "$path" == .claude/skills/*/* ]] && continue
  [[ "$path" == "$CODEX_USER_CONFIG" || "$path" == "$CODEX_LEGACY_CONFIG" ]] && continue
  [[ "$path" == "$CODEX_USER_HOOKS" || "$path" == "$CODEX_LEGACY_HOOKS" ]] && continue
  mkdir -p "$HOME/$(dirname "$path")"
  ln -sfn "$DOTFILES_DIR/$path" "$HOME/$path" && ((link_count++))
done < <(git -C "$DOTFILES_DIR" ls-files -z -- .claude .codex)

# keep in sync with setup.sh link_claude_skills (per-skill directory links)
mkdir -p "$HOME/.claude/skills"
while IFS= read -r skill_src; do
  ln -sfn "$skill_src" "$HOME/.claude/skills/$(basename "$skill_src")" && ((link_count++))
done < <(find "$DOTFILES_DIR/.claude/skills" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/SKILL.md' \; -print 2>/dev/null)

if [[ -f "$DOTFILES_DIR/$CODEX_USER_CONFIG" ]]; then
  mkdir -p "$HOME/.codex"
  ln -sfn "$DOTFILES_DIR/$CODEX_USER_CONFIG" "$HOME/.codex/config.toml"
fi

if [[ -f "$DOTFILES_DIR/$CODEX_USER_HOOKS" ]]; then
  mkdir -p "$HOME/.codex"
  ln -sfn "$DOTFILES_DIR/$CODEX_USER_HOOKS" "$HOME/.codex/hooks.json"
fi

if ((link_count == 0)); then
  note_fail "no config symlinks created"
else
  find "$HOME/.claude/hooks" -name '*.sh' -exec chmod +x {} \; 2>/dev/null
  success "Linked $link_count config files into ~/.claude and ~/.codex"
fi

# =============================================================================
# Section 4: CLI tools (all guarded; base image already has node/npm/pnpm/uvx)
# =============================================================================

if ! command -v pnpm &>/dev/null; then
  npm install -g pnpm >>"$LOG" 2>&1 || note_fail "pnpm install failed"
fi

# Pinned direct download, NOT the official installer (setup.sh install_supabase):
# the installer resolves the latest tag via anonymous api.github.com, which is
# rate-limited (403) from shared cloud egress IPs.
SUPABASE_VERSION=2.109.1
if ! command -v supabase &>/dev/null; then
  case "$(uname -m)" in
    aarch64 | arm64) sb_arch=arm64 ;;
    *) sb_arch=amd64 ;;
  esac
  curl -fsSL "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/supabase_linux_${sb_arch}.tar.gz" \
    | tar -xz -C "$HOME/.local/bin" supabase 2>>"$LOG"
  command -v supabase &>/dev/null || note_fail "supabase CLI install failed"
fi

# keep in sync with setup.sh install_trufflehog (no sudo: we are root)
if ! command -v trufflehog &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
    | sh -s -- -b /usr/local/bin >>"$LOG" 2>&1 || note_fail "trufflehog install failed"
fi

# keep in sync with setup.sh install_uv
if ! command -v uv &>/dev/null; then
  curl -fsSL https://astral.sh/uv/install.sh \
    | UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh \
    >>"$LOG" 2>&1 || note_fail "uv install failed"
fi

# semgrep via uv (setup.sh uses pipx); capped — the semgrep hook degrades gracefully
if ! command -v semgrep &>/dev/null; then
  if command -v uv &>/dev/null; then
    timeout 150 uv tool install semgrep >>"$LOG" 2>&1 || note_fail "semgrep install failed/timed out"
  else
    note_fail "semgrep skipped (no uv)"
  fi
fi

# keep in sync with setup.sh install_codex (auth is per-session: codex login --device-auth)
if ! command -v codex &>/dev/null; then
  CODEX_NON_INTERACTIVE=1 sh -c "$(curl -fsSL https://chatgpt.com/codex/install.sh)" >>"$LOG" 2>&1
  hash -r
  command -v codex &>/dev/null || note_fail "codex CLI install failed"
fi

hash -r

# =============================================================================
# Section 6: Claude Code plugins (must happen at build time: the session
# harness sets SKIP_PLUGIN_MARKETPLACE=true, which disables session-start
# install). Marketplaces + install list derive from settings.json.
# =============================================================================

if ! command -v claude &>/dev/null; then
  claude_installer="$(mktemp)"
  if curl -fsSL https://claude.ai/install.sh -o "$claude_installer"; then
    bash "$claude_installer" >>"$LOG" 2>&1 || true
  fi
  rm -f "$claude_installer"
  hash -r
fi

settings_file="$DOTFILES_DIR/.claude/settings.json"
if command -v claude &>/dev/null && command -v jq &>/dev/null && [[ -f "$settings_file" ]]; then
  # official marketplace is auto-known at session time but NOT at build time
  env -u SKIP_PLUGIN_MARKETPLACE claude plugin marketplace add anthropics/claude-plugins-official >>"$LOG" 2>&1 || true

  # plain owner/repo — the CLI rejects the github: prefix ("Invalid marketplace source format")
  while IFS= read -r repo; do
    env -u SKIP_PLUGIN_MARKETPLACE claude plugin marketplace add "$repo" >>"$LOG" 2>&1 || true
  done < <(jq -r '.extraKnownMarketplaces // {} | to_entries[] | .value.source.repo' "$settings_file")

  plugin_fail=0
  while IFS= read -r plugin; do
    if out=$(env -u SKIP_PLUGIN_MARKETPLACE claude plugin install "$plugin" --scope user 2>&1); then
      success "Plugin: $plugin"
    else
      warn "Plugin failed: $plugin"
      ((plugin_fail++))
    fi
    printf -- '--- plugin install %s ---\n%s\n' "$plugin" "$out" >> "$LOG"
  done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value) | .key' "$settings_file")
  ((plugin_fail)) && note_fail "$plugin_fail plugin install(s) failed"
  # ground truth for the session to inspect: what actually landed on disk
  { echo '--- claude plugin list ---'; env -u SKIP_PLUGIN_MARKETPLACE claude plugin list; } >> "$LOG" 2>&1
else
  note_fail "plugin install skipped (claude/jq/settings.json missing)"
fi

# =============================================================================
# Section 7: Summary (always exit 0 — build must not fail)
# =============================================================================

echo
info "Tool inventory:"
for t in node pnpm gh jq perl shellcheck supabase trufflehog uv semgrep codex claude; do
  printf '  %-11s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done

echo
if ((${#FAILURES[@]})); then
  warn "cloud-setup finished with ${#FAILURES[@]} issue(s):"
  printf '  - %s\n' "${FAILURES[@]}"
else
  success "cloud-setup finished clean"
fi

exit 0
