#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
SQL=$(printf '%s' "$INPUT" | jq -r '.tool_input.sql // .tool_input.query // .tool_input.statement // empty' 2>/dev/null | tr '[:lower:]' '[:upper:]')
[[ -z "$SQL" ]] && exit 0

while IFS= read -r stmt; do
  verb=$(printf '%s' "$stmt" | sed -E 's/^[[:space:]]*//; s/[[:space:]].*//')
  case "$verb" in
    INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|MERGE|REPLACE|UPSERT|COMMENT)
      deny "Write SQL blocked. execute_sql is restricted to SELECT, SHOW, EXPLAIN, and DESCRIBE."
      exit 0
      ;;
  esac
done < <(printf '%s\n' "$SQL" | tr ';' '\n')
