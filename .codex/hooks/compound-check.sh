#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

STRIPPED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
if printf '%s' "$STRIPPED" | grep -qE '(cd[[:space:]]+[^[:space:]]+.*(&&|;|\|\||&).*\b(git|gh)\b|\b(git|gh)\b.*(&&|;|\|\||&).*cd[[:space:]]+[^[:space:]]+)'; then
  deny "cd plus git/gh compound command blocked. Retry with git -C <dir> <cmd> or gh -R <owner/repo> so approval rules apply."
fi
