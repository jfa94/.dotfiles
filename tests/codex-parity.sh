#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CODEX_CONFIG="$ROOT/.codex/user-config.toml"
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
aws cost explorer read|aws-readonly-check.sh|aws ce get-cost-and-usage --time-period Start=2026-07-01,End=2026-07-24|allow
aws cost explorer mutation|aws-readonly-check.sh|aws ce delete-anomaly-monitor --monitor-arn arn|deny
aws logs tail|aws-readonly-check.sh|aws logs tail /aws/lambda/fn|allow
aws configure read|aws-readonly-check.sh|aws configure list|allow
aws configure write|aws-readonly-check.sh|aws configure set region us-east-1|deny
aws secret value|aws-readonly-check.sh|aws secretsmanager get-secret-value --secret-id id|deny
aws s3 stream to stdout|aws-readonly-check.sh|aws s3 cp s3://bucket/key -|allow
aws s3 copy to disk|aws-readonly-check.sh|aws s3 cp s3://bucket/key /tmp/out|deny
aws global flags before service|aws-readonly-check.sh|aws --profile prod --region us-east-1 ce get-cost-forecast|allow
CASES

# Every AWS command Claude auto-allows must also be auto-allowed by Codex:
# the rules layer must not prompt, and the read-only hook must not deny.
if command -v codex >/dev/null 2>&1; then
  while IFS= read -r entry; do
    concrete=${entry#Bash(}
    concrete=${concrete%)}
    concrete=${concrete//-\*/-something}
    concrete=${concrete// \*/ ARG}
    concrete=${concrete//\*/X}
    # shellcheck disable=SC2086
    decision=$(codex execpolicy check --rules "$ROOT/.codex/rules/default.rules" $concrete 2>/dev/null |
      jq -r '.decision // "no-match"')
    [[ "$decision" == "allow" ]] || {
      echo "FAIL aws rules parity: '$concrete' is '$decision' in Codex but allowed in Claude" >&2
      exit 1
    }
    assert_decision "aws hook parity: $concrete" aws-readonly-check.sh "$concrete" allow
  done < <(jq -r '.permissions.allow[] | select(startswith("Bash(aws "))' "$ROOT/.claude/settings.json")
else
  echo "codex binary absent: skipped AWS rules-layer parity sweep" >&2
fi

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

EXPECTED_STATUS='status_line = ["model", "current-dir", "git-branch", "branch-changes", "context-used", "context-window-size", "five-hour-limit", "weekly-limit"]'
grep -Fxq "$EXPECTED_STATUS" "$CODEX_CONFIG"
grep -Fxq 'approvals_reviewer = "user"' "$CODEX_CONFIG"
NEWLINE_KEYS=$(sed -n '/^\[tui\.keymap\.editor\]$/,/^\[/p' "$CODEX_CONFIG")
[[ "$NEWLINE_KEYS" == *'insert_newline = ["shift-enter", "ctrl-enter"]'* ]]
FILTERED_CONFIG=$("$ROOT/.codex/strip-hooks-state.sh" < "$CODEX_CONFIG")
[[ "$FILTERED_CONFIG" == *'notify = '* && "$FILTERED_CONFIG" != *'[hooks.state'* ]]
[[ ! -e "$ROOT/.codex/config.toml" ]]
grep -q 'CODEX_USER_CONFIG=".codex/user-config.toml"' "$ROOT/setup.sh"
! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$ROOT" diff --name-only -- '.codex/plugins.txt' '.claude/hooks/superpowers-compact-reinject.sh' | grep -q .
PASS=$((PASS + 1))

FILESYSTEM_PROFILE=$(sed -n '/^\[permissions\.workspace-net\.filesystem\]$/,/^\[permissions\.workspace-net\.filesystem\./p' "$CODEX_CONFIG" | sed '$d')
[[ $(printf '%s\n' "$FILESYSTEM_PROFILE" | awk '$0 == "glob_scan_max_depth = 32" { count++ } END { print count + 0 }') -eq 1 ]]
WORKSPACE_PROFILE=$(sed -n '/^\[permissions\.workspace-net\.filesystem\.\":workspace_roots"\]$/,/^\[/p' "$CODEX_CONFIG")
[[ "$WORKSPACE_PROFILE" == *'".git" = "write"'* ]]
PASS=$((PASS + 1))

echo "codex parity: $PASS checks passed"
