#!/bin/bash
set -euo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
# Strip quoted strings so operators inside quotes don't trigger false positives
STRIPPED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
# Only block: cd + git compound in either order (bypasses git permission rules)
printf '%s' "$STRIPPED" | grep -qE '(cd\s+\S+.*&&.*\bgit\b|\bgit\b.*&&.*\bcd\s+\S+)' || exit 0
jq -cn --arg r 'cd + git compound detected. Use git -C <dir> <cmd> instead so permission rules apply.' \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
