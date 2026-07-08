#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
RAW=$(json_get "$INPUT" '.tool_input.sql // .tool_input.query // .tool_input.statement // empty' | tr '[:lower:]' '[:upper:]')
[[ -z "$RAW" ]] && exit 0

# Normalize before judging. Order matters: strings before line comments
# (`'a--b'; DELETE` must keep the DELETE), line comments per-line before
# flattening (`-- c\nDELETE` must keep the DELETE), block comments after
# flattening (they span lines). Kills `/* */DELETE` bypasses and
# 'DROP TABLE'-in-a-string false positives. Multi-line strings / `--` inside
# block comments degrade to leftover tokens → fail-safe deny, never a bypass.
SQL=$(printf '%s' "$RAW" \
  | sed -E "s/'[^']*'/ /g; s/--.*$//" \
  | tr '\n' ' ' \
  | sed -E 's,/\*[^*]*\*+([^/*][^*]*\*+)*/, ,g')

# Deny-by-default: every ;-separated statement must LEAD with a read verb.
while IFS= read -r stmt; do
  verb=$(printf '%s' "$stmt" | sed -E 's/^[[:space:]()]*//; s/[[:space:](].*//')
  [[ -z "$verb" ]] && continue
  case "$verb" in
    SELECT | SHOW | EXPLAIN | DESCRIBE | DESC | WITH | VALUES | TABLE) ;;
    *)
      deny "Non-read statement '$verb' blocked. execute_sql is restricted to read-only (SELECT/SHOW/EXPLAIN/DESCRIBE/WITH)."
      exit 0
      ;;
  esac
done <<EOF
$(printf '%s' "$SQL" | tr ';' '\n')
EOF

# Allowlisted leads can still smuggle writes: WITH d AS (DELETE ...) SELECT,
# EXPLAIN ANALYZE DELETE (executes!), SELECT ... FOR UPDATE. Word-bounded scan
# is safe post-strip: last_update/deleted_at columns don't word-match.
if printf '%s' "$SQL" | grep -qwE 'INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|MERGE|CALL|COPY|REFRESH|VACUUM|LOCK|DO'; then
  deny 'Write/DDL keyword inside a read-leading statement (CTE write, EXPLAIN ANALYZE write, or FOR UPDATE lock) — blocked.'
fi
