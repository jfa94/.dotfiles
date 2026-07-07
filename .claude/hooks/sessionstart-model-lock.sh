#!/bin/bash
# SessionStart(startup) hook. /model persists its live pick into
# ~/.claude/settings.json (known Claude Code bug: anthropics/claude-code#22659,
# #49076 — closed as duplicates, not fixed), drifting the global default away
# from opusplan. Reset it here so every new session starts from the intended
# default. Write through the symlink: `mv` onto the path itself would replace
# the setup.sh symlink with a plain copy and silently detach live settings
# from the dotfiles repo (this happened; see git history).
set -uo pipefail
LINK="$HOME/.claude/settings.json"
FILE=$(readlink -f "$LINK" 2>/dev/null || echo "$LINK")
if [ "$(jq -r '.model // empty' "$FILE" 2>/dev/null)" != "opusplan" ]; then
  TMP=$(mktemp) && jq '.model = "opusplan"' "$FILE" > "$TMP" && mv "$TMP" "$FILE"
fi
if [ ! -L "$LINK" ]; then
  jq -cn '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:"WARNING: ~/.claude/settings.json is not a symlink into ~/.dotfiles — live settings are detached from the repo source of truth. Reconcile the two files and re-run setup.sh."}}'
fi
exit 0
