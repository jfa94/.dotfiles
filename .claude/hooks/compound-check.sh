#!/bin/bash
set -euo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
# Normalize newlines to ';' (multiline commands chain the same way), then strip
# quoted strings so operators inside quotes don't trigger false positives.
STRIPPED=$(printf '%s' "$CMD" | tr '\n' ';' | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
# Block cd/pushd + git/gh compound in either order, via any chaining operator (&&, ;, ||, &).
# Word boundary before cd avoids false positives on argocd/etcd/--cd-style tokens.
printf '%s' "$STRIPPED" | grep -qE '((^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+[^[:space:]]+.*(&&|;|\|\||&).*\b(git|gh)\b|\b(git|gh)\b.*(&&|;|\|\||&).*(^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+[^[:space:]]+)' || exit 0
jq -cn --arg r 'cd + git/gh compound detected. Use git -C <dir> <cmd> (or gh -R <repo>) instead so permission rules apply.' \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
