#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

missing=()
# hooks/ and rules/ are real dirs of per-file symlinks (setup.sh links files,
# not the dirs), so check a representative symlink inside each — not the dir.
for path in "$HOME/.codex/config.toml" "$HOME/.codex/hooks.json" \
            "$HOME/.codex/rules/default.rules" "$HOME/.codex/hooks/hook-lib.sh"; do
  [[ -L "$path" ]] || missing+=("$path")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  session_context "Codex symlink-integrity warning: expected dotfiles-managed symlink(s): ${missing[*]}"
fi
