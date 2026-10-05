#!/usr/bin/env bash
# shellcheck disable=SC2016 # SQL fixtures intentionally contain $ and backslashes.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.claude/hooks/sql-readonly-check.sh"
PASS=0

decision_for() {
  local output
  output=$("$HOOK" <<< "$(jq -cn --arg q "$1" '{tool_input:{query:$q}}')")
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision'
  else
    printf 'pass\n'
  fi
}

assert_sql() {
  local name=$1 sql=$2 expected=$3 actual
  actual=$(decision_for "$sql")
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL sql-readonly / $name: expected $expected, got $actual" >&2
    echo "  sql: $sql" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

# --- reads are allowed -------------------------------------------------------
assert_sql "select 1" "SELECT 1" allow
assert_sql "cte read" "WITH a AS (SELECT id FROM t) SELECT * FROM a" allow
assert_sql "count with IN" "SELECT count(*) FROM t WHERE x IN (1,2)" allow
assert_sql "coalesce with line comment" $'SELECT COALESCE(a,\'x\') FROM t -- note' allow
assert_sql "semicolon-delete inside a string" "SELECT 'a;DELETE FROM t' FROM t" allow
assert_sql "quote inside a comment" "SELECT 1 -- it's fine" allow
assert_sql "explain select" "EXPLAIN SELECT * FROM t" allow
assert_sql "information_schema" "SELECT * FROM information_schema.tables" allow
assert_sql "quoted identifier" 'SELECT "Name" FROM "Users"' allow
assert_sql "doubled quote in string" "SELECT 'it''s' FROM t" allow
assert_sql "window function" "SELECT row_number() OVER (PARTITION BY a ORDER BY b) FROM t" allow
assert_sql "schema-qualified safe call" "SELECT pg_catalog.count(*) FROM t" allow
assert_sql "cast with type modifier" "SELECT x::numeric(10,2) FROM t" allow

# --- reproduced bypasses must ask -------------------------------------------
assert_sql "E-string hides a statement" "SELECT E'\\'; DELETE FROM t; --'" ask
assert_sql "dollar-quoted body" 'SELECT $$; DELETE FROM t; --$$' ask
assert_sql "parameter" 'SELECT * FROM t WHERE id = $1' ask
assert_sql "select into" "SELECT * INTO x FROM t" ask
assert_sql "pg_terminate_backend" "SELECT pg_terminate_backend(1)" ask
assert_sql "set_config" "SELECT set_config('a','b',false)" ask
assert_sql "nextval" "SELECT nextval('s')" ask
assert_sql "dblink_exec" "SELECT dblink_exec('x','y')" ask
assert_sql "lo_import" "SELECT lo_import('/etc/passwd')" ask
assert_sql "pg_read_file" "SELECT pg_read_file('/etc/passwd')" ask
assert_sql "schema-qualified unsafe call" "SELECT pg_catalog.set_config('a','b',false)" ask
assert_sql "quoted function name" 'SELECT "pg_terminate_backend"(1)' ask
assert_sql "unterminated string" "SELECT 'abc" ask
assert_sql "unterminated block comment" "SELECT 1 /* x" ask
assert_sql "nested block comment" "SELECT 1 /* a /* b */ ; DELETE FROM t */" ask
assert_sql "block comment before delete" "/* ; */ DELETE FROM t" ask
assert_sql "multi-statement drop" "SELECT 1; DROP TABLE t" ask
assert_sql "explain analyze delete" "EXPLAIN ANALYZE DELETE FROM t" ask
assert_sql "for update" "SELECT * FROM t FOR UPDATE" ask
assert_sql "cte write" "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d" ask
assert_sql "set statement" "SET statement_timeout = 0" ask

# --- every write keyword, spliced into an otherwise-read query, never allows --
for kw in INSERT UPDATE DELETE DROP ALTER TRUNCATE CREATE GRANT REVOKE MERGE CALL COPY REFRESH VACUUM LOCK "DO" INTO; do
  assert_sql "keyword $kw after select" "SELECT 1; $kw x" ask
  assert_sql "keyword $kw inside cte" "WITH a AS ($kw x) SELECT 1" ask
done

echo "sql-readonly: $PASS checks passed"
