#!/bin/bash
# SessionStart hook. /model persists its live pick into ~/.claude/settings.json
# (known Claude Code bug: anthropics/claude-code#22659, #49076 — closed as
# duplicates, not fixed), drifting the global default away from opusplan.
# Reset it here so every new session starts from the intended default
# regardless of what the previous session left behind.
set -uo pipefail
FILE="$HOME/.claude/settings.json"
jq '.model = "opusplan"' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
exit 0
