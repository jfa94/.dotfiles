#!/bin/bash
set -euo pipefail
RAW=$(cat | jq -r '.tool_input.sql // .tool_input.query // empty' | tr '[:lower:]' '[:upper:]')
[ -z "$RAW" ] && exit 0

ask() {
  jq -cn --arg r "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
  exit 0
}

# Sole arbiter for execute_sql: the tool is deliberately NOT in permissions.allow
# (an allow rule beats a hook's ask — verified empirically + docs). Reads get an
# explicit allow here; anything ambiguous falls to ask, and if this hook errors
# out entirely the tool is unlisted so the default prompt fires. No silent path.
allow() {
  jq -cn \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Read-only SQL verified by sql-readonly-check.sh."}}'
  exit 0
}

# Fail closed on anything this lexer does not model: backslashes (E'..' strings)
# and `$` (dollar quotes, $1 params) go to ask. Standard-conforming strings,
# "identifiers", `--` and `/* */` are blanked in ONE left-to-right pass so a quote
# inside a comment (or the reverse) cannot desynchronize it. Quoted identifiers
# become __Q__ so `"fn"(…)` still reads as a call. Leftovers (unterminated
# string, nested comment) fail safe to ask.
case $RAW in
  *\\*|*'$'*) ask "SQL contains a backslash or '\$' (escape string, dollar quote, parameter) this hook cannot lex — run it anyway?" ;;
esac
SQL=$(printf '%s' "$RAW" | perl -0777 -pe '
  s{(\x27(?:[^\x27]|\x27\x27)*\x27)|("(?:[^"]|"")*")|--[^\n]*|/\*.*?\*/}{defined $2 ? " __Q__ " : " "}gse;
  s/\n/ /g;
')
case $SQL in
  *\'*|*\"*|*'/*'*|*'*/'*) ask 'Unterminated string/comment or nested comment in SQL — run it anyway?' ;;
esac

# Ask-by-default: every ;-separated statement must LEAD with a read verb.
while IFS= read -r STMT; do
  VERB=$(printf '%s' "$STMT" | sed -E 's/^[[:space:]()]*//; s/[[:space:](].*//')
  [ -z "$VERB" ] && continue
  case "$VERB" in
    SELECT | SHOW | EXPLAIN | DESCRIBE | DESC | WITH | VALUES | TABLE) ;;
    *) ask "Run this non-read SQL statement ('$VERB ...') against Supabase via execute_sql?" ;;
  esac
done <<EOF
$(printf '%s' "$SQL" | tr ';' '\n')
EOF

# Allowlisted leads can still smuggle writes: WITH d AS (DELETE ...) SELECT,
# EXPLAIN ANALYZE DELETE (executes!), SELECT ... FOR UPDATE. Word-bounded scan
# is safe post-strip: last_update/deleted_at columns don't word-match.
if printf '%s' "$SQL" | grep -qwE 'INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|MERGE|CALL|COPY|REFRESH|VACUUM|LOCK|DO|INTO'; then
  ask 'This statement has a write/DDL keyword inside a read-leading form (CTE write, EXPLAIN ANALYZE write, FOR UPDATE lock, or SELECT INTO) — run it anyway?'
fi

# Any call outside this allowlist can write, signal, read files or change settings
# (pg_terminate_backend, set_config, nextval, dblink_exec, lo_import, …). The first
# group is SQL syntax that takes parentheses; the rest are pure read-only built-ins.
SAFE_CALLS=" IN EXISTS ANY ALL SOME VALUES AS OVER FILTER WITHIN CAST FROM JOIN ON USING WHERE HAVING AND OR NOT SELECT BY LATERAL ARRAY ROW CASE WHEN THEN ELSE INTERVAL DISTINCT UNION INTERSECT EXCEPT MATERIALIZED EXPLAIN VARCHAR CHAR NUMERIC DECIMAL TIMESTAMP TIMESTAMPTZ TIME TIMETZ BIT VARBIT
 COUNT SUM AVG MIN MAX ARRAY_AGG STRING_AGG JSON_AGG JSONB_AGG BOOL_AND BOOL_OR COALESCE NULLIF GREATEST LEAST
 LOWER UPPER LENGTH SUBSTRING TRIM CONCAT REPLACE SPLIT_PART LEFT RIGHT POSITION DATE_TRUNC EXTRACT NOW TO_CHAR TO_DATE TO_TIMESTAMP AGE
 ROUND FLOOR CEIL ABS ROW_NUMBER RANK DENSE_RANK LAG LEAD JSONB_BUILD_OBJECT JSON_BUILD_OBJECT JSONB_ARRAY_LENGTH JSONB_EXTRACT_PATH_TEXT
 UNNEST GENERATE_SERIES PG_SIZE_PRETTY PG_TOTAL_RELATION_SIZE PG_RELATION_SIZE FORMAT_TYPE OBJ_DESCRIPTION COL_DESCRIPTION VERSION CURRENT_DATABASE CURRENT_SCHEMA "
while IFS= read -r CALL; do
  [ -n "$CALL" ] || continue
  case "$SAFE_CALLS" in
    *[[:space:]]"$CALL"[[:space:]]*) ;;
    *) ask "SQL calls '$CALL(…)', which is not on the read-only function allowlist — run it anyway?" ;;
  esac
done < <(printf '%s' "$SQL" | grep -oE '[A-Z_][A-Z0-9_.]*[[:space:]]*\(' | sed -E 's/[[:space:]]*\($//; s/.*\.//' | sort -u)

allow
