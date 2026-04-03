#!/bin/bash
set -euo pipefail
INPUT=$(cat)
SQL=$(printf '%s' "$INPUT" | jq -r '.tool_input.sql // .tool_input.query // empty' | tr '[:lower:]' '[:upper:]')
[ -z "$SQL" ] && exit 0

for KW in INSERT UPDATE DELETE DROP ALTER TRUNCATE CREATE GRANT REVOKE COMMENT; do
  if printf '%s' "$SQL" | grep -qw "$KW"; then
    jq -cn --arg r 'Write SQL blocked. execute_sql is restricted to read-only (SELECT/SHOW/EXPLAIN/DESCRIBE).' \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"block","permissionDecisionReason":$r}}'
    exit 0
  fi
done
