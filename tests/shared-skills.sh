#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/setup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Exercise the production helpers without running package installation or other
# setup sections.
eval "$(sed -n '/^link_file() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^link_claude_skills_for_codex() {/,/^}/p' "$SETUP")"

info() { :; }
success() { :; }
warn() { :; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

linked=()
replaced=()
skipped=()
MODE=replace

# The real authored tree is exposed wholesale, including nested resources.
DOTFILES_DIR="$ROOT"
HOME="$tmp/real-home"
link_claude_skills_for_codex
[[ -L "$HOME/.agents/skills" ]] || fail 'shared skill root is not a symlink'
[[ "$(readlink "$HOME/.agents/skills")" == "$ROOT/.claude/skills" ]] || fail 'shared skill root targets the wrong directory'

while IFS= read -r skill; do
  rel="${skill#"$ROOT/.claude/skills/"}"
  [[ -f "$HOME/.agents/skills/$rel" ]] || fail "shared tree missing $rel"
done < <(find "$ROOT/.claude/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -type f | sort)

# Re-running is idempotent.
link_claude_skills_for_codex
[[ ${#linked[@]} -eq 1 ]] || fail 'idempotent rerun recreated the symlink'

# A whole-tree link exposes later additions without setup reconciliation.
DOTFILES_DIR="$tmp/fixture"
HOME="$tmp/fixture-home"
mkdir -p "$DOTFILES_DIR/.claude/skills/first"
touch "$DOTFILES_DIR/.claude/skills/first/SKILL.md"
link_claude_skills_for_codex
mkdir -p "$DOTFILES_DIR/.claude/skills/later/references"
touch "$DOTFILES_DIR/.claude/skills/later/SKILL.md"
touch "$DOTFILES_DIR/.claude/skills/later/references/guide.md"
[[ -f "$HOME/.agents/skills/later/SKILL.md" ]] || fail 'new skill is not visible through shared root'
[[ -f "$HOME/.agents/skills/later/references/guide.md" ]] || fail 'nested skill resource is not visible'

# Replace also repairs a symlink that points at another skill source.
HOME="$tmp/wrong-link-home"
mkdir -p "$HOME/.agents" "$tmp/other-skills"
ln -s "$tmp/other-skills" "$HOME/.agents/skills"
MODE=replace
link_claude_skills_for_codex
[[ "$(readlink "$HOME/.agents/skills")" == "$DOTFILES_DIR/.claude/skills" ]] || fail 'replace mode did not repair a wrong symlink'

# Replace preserves an existing real directory as the standard backup.
HOME="$tmp/replace-home"
mkdir -p "$HOME/.agents/skills"
touch "$HOME/.agents/skills/existing"
MODE=replace
link_claude_skills_for_codex
[[ -L "$HOME/.agents/skills" ]] || fail 'replace mode did not install the shared link'
[[ -f "$HOME/.agents/skills.bak/existing" ]] || fail 'replace mode did not preserve prior content'

# Skip leaves an existing real directory untouched.
HOME="$tmp/skip-home"
mkdir -p "$HOME/.agents/skills"
touch "$HOME/.agents/skills/existing"
MODE=skip
link_claude_skills_for_codex
[[ ! -L "$HOME/.agents/skills" ]] || fail 'skip mode replaced existing content'
[[ -f "$HOME/.agents/skills/existing" ]] || fail 'skip mode removed existing content'

[[ ! -e "$ROOT/.agents/skills" ]] || fail 'repo contains a duplicate .agents skill tree'
[[ "$(grep -c '^link_claude_skills_for_codex$' "$SETUP")" -eq 1 ]] || fail 'setup does not invoke shared skill linking exactly once'
if grep -Eq '(cp|rsync).*(\.claude/skills|\.agents/skills)' "$SETUP"; then
  fail 'setup copies skills instead of sharing the directory'
fi

printf 'OK\n'
