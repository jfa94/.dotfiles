#!/bin/bash
set -euo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

for PAT in 'rm -r /' 'DROP TABLE' 'DROP DATABASE' 'chmod 777' 'curl.*\|.*sh' 'wget.*\|.*sh'; do
  if printf '%s' "$CMD" | grep -qiE "$PAT"; then
    jq -cn --arg r "Blocked dangerous command pattern: $PAT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
done

if printf '%s' "$CMD" | grep -qiE 'rm -rf'; then
  jq -cn --arg r 'rm -rf detected — confirm before running' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
fi
