#!/bin/bash
set -euo pipefail
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FP" ] && exit 0

if printf '%s' "$FP" | grep -qE '(\.env[^/]*$|/secrets/)'; then
  jq -cn --arg r 'Protected file: requires human review.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi

if printf '%s' "$FP" | grep -qE '/migrations/'; then
  ROOT=$(cd "${CLAUDE_PROJECT_DIR:-.}" && git rev-parse --show-toplevel 2>/dev/null) || exit 0
  [ -z "$ROOT" ] && exit 0
  REL="${FP#"$ROOT"/}"
  git -C "$ROOT" cat-file -e "main:$REL" 2>/dev/null || exit 0
  jq -cn --arg r 'Applied migration (exists on main): confirm edit.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
fi
