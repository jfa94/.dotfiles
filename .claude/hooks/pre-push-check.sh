#!/bin/bash
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
printf '%s' "$CMD" | grep -qE '^git ((-C [^ ]+ )?push)' || exit 0
[ -f "${CLAUDE_PROJECT_DIR:-.}/package.json" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

QUAL=0
if grep -q '"quality"' package.json; then
  { pnpm quality 2>&1; } | tail -30 || QUAL=1
else
  TC=0; { pnpm typecheck 2>&1; } | tail -10 || TC=1
  LN=0; { pnpm lint 2>&1; } | tail -10 || LN=1
  AU=0; { pnpm audit --audit-level high 2>&1; } | tail -10 || AU=1
  TS=0; { pnpm test 2>&1; } | tail -20 || TS=1
  QUAL=$((TC + LN + AU + TS))
fi

if [ "$QUAL" -ne 0 ]; then
  jq -cn --arg r 'Pre-push quality gate failed. Fix issues before pushing.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
fi
