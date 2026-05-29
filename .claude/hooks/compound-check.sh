#!/bin/bash
set -euo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
# Strip quoted strings so operators inside quotes don't trigger false positives
STRIPPED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
# Block cd + git/gh compound in either order, via any chaining operator (&&, ;, ||, &).
# Covers git (permission rules) and gh (the gh-based PR hooks), and is not limited to &&.
printf '%s' "$STRIPPED" | grep -qE '(cd[[:space:]]+[^[:space:]]+.*(&&|;|\|\||&).*\b(git|gh)\b|\b(git|gh)\b.*(&&|;|\|\||&).*cd[[:space:]]+[^[:space:]]+)' || exit 0
jq -cn --arg r 'cd + git/gh compound detected. Use git -C <dir> <cmd> (or gh -R <repo>) instead so permission rules apply.' \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
