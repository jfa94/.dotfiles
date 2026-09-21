#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

missing=()
# hooks/ and rules/ are real dirs of per-file symlinks (setup.sh links files,
# not the dirs), so check a representative symlink inside each — not the dir.
for path in "$HOME/.codex/AGENTS.md" "$HOME/.codex/config.toml" "$HOME/.codex/hooks.json" \
            "$HOME/.codex/rules/default.rules" "$HOME/.codex/hooks/hook-lib.sh"; do
  [[ -L "$path" && -e "$path" ]] || missing+=("$path")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  session_context "Codex symlink-integrity warning: expected dotfiles-managed symlink(s): ${missing[*]}"
fi

# Codex persists session state back into config.toml. Surface drift at start;
# the TUI mode picker's built-in presets can silently discard workspace-net
# (network off, .git read-only).
drifted=()
for line in 'approvals_reviewer = "auto_review"' 'default_permissions = "workspace-net"'; do
  grep -Fxq "$line" "$HOME/.codex/config.toml" 2>/dev/null || drifted+=("$line")
done

if [[ ${#drifted[@]} -gt 0 ]]; then
  session_context "Codex config-drift warning: expected in config.toml: ${drifted[*]}. Codex rewrites this file; restore it from git (dotfiles .codex/user-config.toml) instead of using the TUI mode picker — the picker replaces workspace-net with a built-in preset that disables network and makes .git read-only."
fi
