#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables are consumed by eval-loaded setup helpers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/setup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Exercise production helpers without running package installation.
eval "$(sed -n '/^link_file() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^link_skills_for_codex() {/,/^}/p' "$SETUP")"

info() { :; }
success() { :; }
warn() { :; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

reset_tracking() { linked=(); replaced=(); skipped=(); }

DOTFILES_DIR="$tmp/fixture"
mkdir -p \
  "$DOTFILES_DIR/.claude/skills/shared/references" \
  "$DOTFILES_DIR/.claude/skills/comprehensive-code-review" \
  "$DOTFILES_DIR/.claude/skills/focused-code-review" \
  "$DOTFILES_DIR/.codex/skills/code-review"
touch \
  "$DOTFILES_DIR/.claude/skills/shared/SKILL.md" \
  "$DOTFILES_DIR/.claude/skills/shared/references/guide.md" \
  "$DOTFILES_DIR/.claude/skills/comprehensive-code-review/SKILL.md" \
  "$DOTFILES_DIR/.claude/skills/focused-code-review/SKILL.md" \
  "$DOTFILES_DIR/.codex/skills/code-review/SKILL.md"

# Fresh install creates a real root with individual links and exclusions.
HOME="$tmp/fresh-home"
MODE=replace
reset_tracking
link_skills_for_codex
[[ -d "$HOME/.agents/skills" && ! -L "$HOME/.agents/skills" ]] || fail 'skill root is not a real directory'
[[ "$(readlink "$HOME/.agents/skills/shared")" == "$DOTFILES_DIR/.claude/skills/shared" ]] || fail 'shared skill link is wrong'
[[ -f "$HOME/.agents/skills/shared/references/guide.md" ]] || fail 'nested shared resource is unavailable'
[[ "$(readlink "$HOME/.agents/skills/code-review")" == "$DOTFILES_DIR/.codex/skills/code-review" ]] || fail 'Codex-only skill link is wrong'
[[ ! -e "$HOME/.agents/skills/comprehensive-code-review" ]] || fail 'comprehensive Claude skill was exposed'
[[ ! -e "$HOME/.agents/skills/focused-code-review" ]] || fail 'focused Claude skill was exposed'

# Re-running is idempotent.
link_skills_for_codex
[[ ${#linked[@]} -eq 2 ]] || fail 'idempotent rerun recreated links'

# A setup-owned legacy whole-tree link migrates without losing skill access.
HOME="$tmp/legacy-home"
mkdir -p "$HOME/.agents"
ln -s "$DOTFILES_DIR/.claude/skills" "$HOME/.agents/skills"
reset_tracking
link_skills_for_codex
[[ -d "$HOME/.agents/skills" && ! -L "$HOME/.agents/skills" ]] || fail 'legacy root link was not migrated'
[[ -L "$HOME/.agents/skills/shared" ]] || fail 'migration omitted shared skill'
[[ -L "$HOME/.agents/skills/code-review" ]] || fail 'migration omitted Codex skill'

# Existing real directories and unrelated contents are preserved.
HOME="$tmp/preserve-home"
mkdir -p "$HOME/.agents/skills/unowned"
touch "$HOME/.agents/skills/unowned/keep"
reset_tracking
link_skills_for_codex
[[ -f "$HOME/.agents/skills/unowned/keep" ]] || fail 'unowned content was removed'

# Replace handles per-skill conflicts while preserving the prior entry.
HOME="$tmp/replace-home"
mkdir -p "$HOME/.agents/skills/shared"
touch "$HOME/.agents/skills/shared/existing"
MODE=replace
reset_tracking
link_skills_for_codex
[[ -L "$HOME/.agents/skills/shared" ]] || fail 'replace did not install shared link'
[[ -f "$HOME/.agents/skills/shared.bak/existing" ]] || fail 'replace did not back up conflict'

# Skip leaves a per-skill conflict untouched but installs other links.
HOME="$tmp/skip-home"
mkdir -p "$HOME/.agents/skills/shared"
touch "$HOME/.agents/skills/shared/existing"
MODE=skip
reset_tracking
link_skills_for_codex
[[ ! -L "$HOME/.agents/skills/shared" && -f "$HOME/.agents/skills/shared/existing" ]] || fail 'skip replaced shared conflict'
[[ -L "$HOME/.agents/skills/code-review" ]] || fail 'skip prevented unrelated Codex skill link'

# Only setup-owned stale/excluded links are pruned.
HOME="$tmp/prune-home"
mkdir -p "$HOME/.agents/skills" "$tmp/unowned"
ln -s "$DOTFILES_DIR/.claude/skills/comprehensive-code-review" "$HOME/.agents/skills/comprehensive-code-review"
ln -s "$DOTFILES_DIR/.claude/skills/deleted" "$HOME/.agents/skills/deleted"
ln -s "$tmp/unowned" "$HOME/.agents/skills/unowned"
MODE=replace
reset_tracking
link_skills_for_codex
[[ ! -e "$HOME/.agents/skills/comprehensive-code-review" ]] || fail 'excluded owned link was retained'
[[ ! -e "$HOME/.agents/skills/deleted" ]] || fail 'stale owned link was retained'
[[ -L "$HOME/.agents/skills/unowned" ]] || fail 'unowned link was pruned'

[[ ! -e "$ROOT/.agents/skills" ]] || fail 'repo contains a duplicate .agents skill tree'
[[ "$(grep -c '^link_skills_for_codex$' "$SETUP")" -eq 1 ]] || fail 'setup does not invoke skill linking exactly once'
if grep -Eq '(cp|rsync).*(\.claude/skills|\.codex/skills|\.agents/skills)' "$SETUP"; then
  fail 'setup copies skills'
fi

printf 'OK\n'
