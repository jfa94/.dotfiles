#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

# Normalize newlines to ';' (multiline commands chain the same way), then strip
# quoted strings so operators inside quotes don't trigger false positives.
STRIPPED=$(printf '%s' "$CMD" | tr '\n' ';' | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
# Block cd/pushd + git/gh compound in either order, via any chaining operator (&&, ;, ||, &).
# Word boundary before cd avoids false positives on argocd/etcd/--cd-style tokens.
if printf '%s' "$STRIPPED" | grep -qE '((^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+[^[:space:]]+.*(&&|;|\|\||&).*\b(git|gh)\b|\b(git|gh)\b.*(&&|;|\|\||&).*(^|[^[:alnum:]_-])(cd|pushd)[[:space:]]+[^[:space:]]+)'; then
  deny "cd plus git/gh compound command blocked. Retry with git -C <dir> <cmd> or gh -R <owner/repo> so approval rules apply."
fi
