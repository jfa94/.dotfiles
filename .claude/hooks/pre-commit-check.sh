#!/bin/bash
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
printf '%s' "$CMD" | grep -qE '^git commit' || exit 0
[ -f "${CLAUDE_PROJECT_DIR:-.}/package.json" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

SECRETS=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null \
  | grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|password\s*[:=]\s*\S+|secret_?key\s*[:=]\s*\S+|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' \
  || true)
if [ -n "$SECRETS" ]; then
  jq -cn --arg r 'Potential secrets detected in staged changes.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi

TSC=0; { npx tsc --noEmit 2>&1; } | tail -10 || TSC=1
LINT=0; { npx eslint . --max-warnings 0 2>&1; } | tail -10 || LINT=1

if [ "$TSC" -ne 0 ] || [ "$LINT" -ne 0 ]; then
  jq -cn --arg r "Pre-commit gate failed: tsc($TSC) lint($LINT). Fix before committing." \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
fi
