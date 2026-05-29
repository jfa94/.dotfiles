#!/bin/bash
set -euo pipefail
INPUT=$(cat)
SQL=$(printf '%s' "$INPUT" | jq -r '.tool_input.sql // .tool_input.query // empty' | tr '[:lower:]' '[:upper:]')
[ -z "$SQL" ] && exit 0

# Deny when any statement's LEADING keyword is a write/DDL verb. Anchoring to the
# first token of each ;-separated statement (instead of grep -w anywhere) avoids
# false positives like `SELECT col AS comment` while still catching
# `SELECT 1; DROP TABLE x`.
# NOTE: covers the execute_sql tool only; destructive SQL run via psql in Bash is
# out of scope here and would need a separate Bash matcher.
while IFS= read -r STMT; do
  VERB=$(printf '%s' "$STMT" | sed -E 's/^[[:space:]]*//; s/[[:space:]].*//')
  case "$VERB" in
    INSERT | UPDATE | DELETE | DROP | ALTER | TRUNCATE | CREATE | GRANT | REVOKE | MERGE | REPLACE | UPSERT | COMMENT)
      jq -cn --arg r 'Write SQL blocked. execute_sql is restricted to read-only (SELECT/SHOW/EXPLAIN/DESCRIBE).' \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
      exit 0
      ;;
  esac
done <<EOF
$(printf '%s' "$SQL" | tr ';' '\n')
EOF
