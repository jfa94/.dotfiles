#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables are consumed by eval-loaded setup helpers.
# Tests for the ~/.claude/hooks directory link: fresh install, new-hook
# visibility, idempotency, per-file layout migration, and conflict policy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/setup.sh"
CLOUD="$ROOT/cloud-setup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

eval "$(sed -n '/^link_file() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^claude_hooks_dir_is_legacy() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^link_claude_hooks() {/,/^}/p' "$SETUP")"

info() { :; }
success() { :; }
warn() { :; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

reset_tracking() { linked=(); replaced=(); skipped=(); }

DOTFILES_DIR="$tmp/fixture"
SRC="$DOTFILES_DIR/.claude/hooks"
mkdir -p "$SRC"
echo 'echo a' > "$SRC/a.sh"
echo 'echo b' > "$SRC/b.sh"
echo 'x' > "$SRC/keep-awake.ps1"

# Fresh install links the directory itself.
HOME="$tmp/fresh"
MODE=replace
mkdir -p "$HOME/.claude"
reset_tracking
link_claude_hooks
[[ -L "$HOME/.claude/hooks" && "$(readlink "$HOME/.claude/hooks")" == "$SRC" ]] \
  || fail "fresh install did not link the directory"
[[ -r "$HOME/.claude/hooks/a.sh" ]] || fail "hook unreadable through the link"

# A hook added later is visible without re-running setup.
echo 'echo c' > "$SRC/c.sh"
[[ -r "$HOME/.claude/hooks/c.sh" ]] || fail "new hook not visible through the link"

# Re-run is idempotent.
reset_tracking
link_claude_hooks
[[ ${#linked[@]} -eq 0 && ${#replaced[@]} -eq 0 && ${#skipped[@]} -eq 1 ]] \
  || fail "re-run was not a no-op: linked=${#linked[@]} replaced=${#replaced[@]} skipped=${#skipped[@]}"
[[ "$(readlink "$HOME/.claude/hooks")" == "$SRC" ]] || fail "re-run changed the link"

# The previous per-file layout (valid, dangling and non-.sh links) migrates
# without a backup.
HOME="$tmp/legacy"
mkdir -p "$HOME/.claude/hooks"
ln -s "$SRC/a.sh" "$HOME/.claude/hooks/a.sh"
ln -s "$SRC/keep-awake.ps1" "$HOME/.claude/hooks/keep-awake.ps1"
ln -s "$SRC/removed.sh" "$HOME/.claude/hooks/removed.sh"
reset_tracking
claude_hooks_dir_is_legacy || fail "per-file layout not recognised as legacy"
link_claude_hooks
[[ -L "$HOME/.claude/hooks" && "$(readlink "$HOME/.claude/hooks")" == "$SRC" ]] \
  || fail "legacy layout not migrated to a directory link"
[[ ! -e "$HOME/.claude/hooks.bak" ]] || fail "legacy migration left a backup"
[[ "${replaced[*]}" == *"migrated to directory link"* ]] || fail "migration not reported"
[[ -f "$SRC/a.sh" && ! -L "$SRC/a.sh" ]] || fail "migration touched repo hooks"

# An empty directory counts as legacy.
HOME="$tmp/empty"
mkdir -p "$HOME/.claude/hooks"
claude_hooks_dir_is_legacy || fail "empty directory not recognised as legacy"

# A directory holding a regular file is not owned: replace mode backs it up.
HOME="$tmp/regular"
mkdir -p "$HOME/.claude/hooks"
ln -s "$SRC/a.sh" "$HOME/.claude/hooks/a.sh"
echo 'mine' > "$HOME/.claude/hooks/custom.sh"
reset_tracking
! claude_hooks_dir_is_legacy || fail "directory with a regular file treated as legacy"
link_claude_hooks
[[ -L "$HOME/.claude/hooks" ]] || fail "replace mode did not link the directory"
[[ -f "$HOME/.claude/hooks.bak/custom.sh" ]] || fail "regular file not preserved in .bak"

# A link pointing outside this repo's hooks is not owned either.
HOME="$tmp/foreign"
mkdir -p "$HOME/.claude/hooks" "$tmp/elsewhere"
echo 'x' > "$tmp/elsewhere/other.sh"
ln -s "$tmp/elsewhere/other.sh" "$HOME/.claude/hooks/other.sh"
reset_tracking
! claude_hooks_dir_is_legacy || fail "foreign link treated as legacy"
link_claude_hooks
[[ -L "$HOME/.claude/hooks.bak/other.sh" ]] || fail "foreign link not preserved in .bak"

# Skip mode leaves an unowned directory alone.
HOME="$tmp/skip"
MODE=skip
mkdir -p "$HOME/.claude/hooks"
echo 'mine' > "$HOME/.claude/hooks/custom.sh"
reset_tracking
link_claude_hooks
[[ -d "$HOME/.claude/hooks" && ! -L "$HOME/.claude/hooks" ]] || fail "skip mode replaced the directory"
[[ ${#skipped[@]} -eq 1 ]] || fail "skip mode did not record the conflict"

# The per-file loops must keep excluding hooks: with the directory linked,
# they would otherwise rewrite the repo's own files.
count_exclusions() {
  # shellcheck disable=SC2016  # the pattern is literal source text
  sed 's/^[[:space:]]*//' "$1" | grep -cxF '[[ "$path" == .claude/hooks/* ]] && continue' || true
}
[[ "$(count_exclusions "$SETUP")" -eq 2 ]] || fail "setup.sh must exclude .claude/hooks/* in exactly two loops"
[[ "$(count_exclusions "$CLOUD")" -eq 1 ]] || fail "cloud-setup.sh must exclude .claude/hooks/* in its loop"
[[ "$(grep -c '^link_claude_hooks$' "$SETUP")" -eq 1 ]] || fail "link_claude_hooks must be called exactly once"

echo "OK"
