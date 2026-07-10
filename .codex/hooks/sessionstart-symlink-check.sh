#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

missing=()
for path in "$HOME/.codex/config.toml" "$HOME/.codex/hooks.json" "$HOME/.codex/rules" "$HOME/.codex/hooks"; do
  [[ -L "$path" ]] || missing+=("$path")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  session_context "Codex symlink-integrity warning: expected dotfiles-managed symlink(s): ${missing[*]}"
fi
