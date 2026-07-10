#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0

run_hook() {
  local hook=$1 input=$2
  HOME=${HOME} bash "$ROOT/.codex/hooks/$hook" <<< "$input"
}

assert_decision() {
  local name=$1 hook=$2 command=$3 expected=$4 output decision
  output=$(run_hook "$hook" "$(jq -cn --arg c "$command" --arg cwd "$ROOT" '{cwd:$cwd,tool_input:{command:$c}}')")
  if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  else
    decision=allow
  fi
  [[ "$decision" == "$expected" ]] || { echo "FAIL $name: expected $expected, got $decision: $output" >&2; exit 1; }
  PASS=$((PASS + 1))
}

jq empty "$ROOT/.codex/hooks.json"
jq -e '.hooks.SessionStart[] | select(.matcher == "compact")' "$ROOT/.codex/hooks.json" >/dev/null

while IFS='|' read -r name hook command expected; do
  assert_decision "$name" "$hook" "$command" "$expected"
done <<'CASES'
rm grouped rf|dangerous-patterns-check.sh|rm -rf build|deny
rm grouped fr|dangerous-patterns-check.sh|rm -fr build|deny
force arbitrary position|dangerous-patterns-check.sh|git push origin main --force-with-lease|deny
force refspec|dangerous-patterns-check.sh|git push origin +main|deny
git bypass|dangerous-patterns-check.sh|git -C /tmp/repo commit -n -m bad|deny
package publish|dangerous-patterns-check.sh|pnpm publish|deny
aws mutation|aws-readonly-check.sh|aws ec2 terminate-instances --instance-ids i-1|deny
aws read|aws-readonly-check.sh|aws ec2 describe-instances|allow
CASES

assert_sql() {
  local name=$1 sql=$2 expected=$3 output decision
  output=$(run_hook sql-readonly-check.sh "$(jq -cn --arg sql "$sql" '{tool_input:{sql:$sql}}')")
  if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  else
    decision=allow
  fi
  [[ "$decision" == "$expected" ]] || { echo "FAIL $name: expected $expected, got $decision: $output" >&2; exit 1; }
  PASS=$((PASS + 1))
}
assert_sql "sql select" "SELECT * FROM users" allow
assert_sql "sql mutating cte" "WITH changed AS (DELETE FROM users RETURNING *) SELECT * FROM changed" deny
assert_sql "sql explain delete" "EXPLAIN ANALYZE DELETE FROM users" deny

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ROLLOUT="$TMP/rollout.jsonl"
printf '%s\n' \
  '{"type":"event_msg","payload":{"type":"user_message","message":"first ask"}}' \
  '{"type":"event_msg","payload":{"type":"agent_message","message":"noise"}}' \
  '{"type":"event_msg","payload":{"type":"user_message","message":"latest ask"}}' > "$ROLLOUT"
OUT=$(run_hook sessionstart-compact-restore.sh "$(jq -cn --arg p "$ROLLOUT" '{rollout_path:$p}')")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("first ask") and contains("latest ask")' >/dev/null
PASS=$((PASS + 1))

OUT=$(run_hook sessionstart-compact-restore.sh '{"rollout_path":"/missing/rollout.jsonl"}')
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("warning")' >/dev/null
PASS=$((PASS + 1))

STATUS=$(sed -n '/^status_line = \[/,/^]/p' "$ROOT/.codex/config.toml")
[[ "$STATUS" == *'"model-with-reasoning"'* && "$STATUS" == *'"five-hour-limit"'* ]]
! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$ROOT" diff --name-only -- '.codex/plugins.txt' '.claude/hooks/superpowers-compact-reinject.sh' | grep -q .
PASS=$((PASS + 1))

echo "codex parity: $PASS checks passed"
