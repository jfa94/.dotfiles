#!/bin/bash
set -euo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
# Strip quoted strings so semicolons inside quotes don't trigger false positives
STRIPPED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
printf '%s' "$STRIPPED" | grep -qE '&&|;\s*[a-zA-Z]' || exit 0
jq -cn --arg r 'Compound command detected. Run each as a separate Bash call so permission rules apply.' \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
