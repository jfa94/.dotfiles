#!/bin/bash
set -euo pipefail
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty')
[ -z "$FP" ] && exit 0

# .env only as a basename prefix (not foo.env.ts), with committed-safe
# example/sample/template variants exempt.
if printf '%s' "$FP" | grep -qE '(^|/)\.env[^/]*$|/secrets/' \
  && ! printf '%s' "$FP" | grep -qE '\.env\.(example|sample|template)$'; then
  jq -cn --arg r 'Protected file: requires human review.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi

if printf '%s' "$FP" | grep -qE '/migrations/'; then
  ROOT=$(cd "${CLAUDE_PROJECT_DIR:-.}" && git rev-parse --show-toplevel 2>/dev/null) || exit 0
  [ -z "$ROOT" ] && exit 0
  REL="${FP#"$ROOT"/}"
  DEFAULT=$(git -C "$ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||' || true)
  DEFAULT="${DEFAULT:-main}"
  git -C "$ROOT" cat-file -e "${DEFAULT}:${REL}" 2>/dev/null || exit 0
  jq -cn --arg r "Applied migration (exists on ${DEFAULT}): confirm edit." \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
fi
