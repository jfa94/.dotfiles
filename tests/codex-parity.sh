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
  local name=$1 hook=$2 command=$3 expected=$4 workdir=${5:-} cwd=${6:-$ROOT} output decision payload
  if [[ -n "$workdir" ]]; then
    payload=$(jq -cn --arg c "$command" --arg cwd "$cwd" --arg w "$workdir" '{cwd:$cwd,tool_input:{command:$c,workdir:$w}}')
  else
    payload=$(jq -cn --arg c "$command" --arg cwd "$cwd" '{cwd:$cwd,tool_input:{command:$c}}')
  fi
  output=$(run_hook "$hook" "$payload")
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
aws secret value|aws-readonly-check.sh|aws secretsmanager get-secret-value --secret-id id|deny
aws secret value batch|aws-readonly-check.sh|aws secretsmanager batch-get-secret-value --secret-id-list id|deny
aws secret value with flags|aws-readonly-check.sh|aws --profile prod secretsmanager get-secret-value --secret-id id|deny
aws secret metadata passes hook|aws-readonly-check.sh|aws secretsmanager list-secrets|allow
aws write passes hook to rules prompt|aws-readonly-check.sh|aws ec2 terminate-instances --instance-ids i-1|allow
CASES

# --- pre-commit gate: per-command workdir, not stale session cwd ---------
# Codex passes each command's working directory as tool_input.workdir and
# tells the model to always set it; sessions are commonly started outside
# the target repo, so the session-level cwd alone is the wrong signal.
# Regression for: "Pre-commit gate could not inspect staged files" when a
# session's cwd isn't a git repo but the command's workdir is.
assert_decision "pre-commit uses command workdir over stale session cwd" \
  pre-commit-check.sh "git commit -m x" allow "$ROOT" "$HOME"
assert_decision "pre-commit falls back to session cwd when workdir absent" \
  pre-commit-check.sh "git commit -m x" allow "" "$ROOT"

# --- pre-commit gate: secrets staged by this same command ----------------
# The gate runs BEFORE the command executes, so `git add secret && git
# commit` has nothing staged yet at hook time. These exercise the pending-add
# resolution (git add --dry-run) that closes that hole.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
git -C "$SCRATCH" init -q
git -C "$SCRATCH" config user.email t@t.com
git -C "$SCRATCH" config user.name t
echo readme > "$SCRATCH/README.md"
git -C "$SCRATCH" add README.md
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com \
  git -C "$SCRATCH" commit -q -m init

echo secret > "$SCRATCH/fake.pem"
assert_decision "pre-commit denies secret added in the same command" \
  pre-commit-check.sh "git add fake.pem && git commit -m x" deny "$SCRATCH"
rm -f "$SCRATCH/fake.pem"

echo hi > "$SCRATCH/notes.txt"
assert_decision "pre-commit allows a plain file added in the same command" \
  pre-commit-check.sh "git add . && git commit -m x" allow "$SCRATCH"
rm -f "$SCRATCH/notes.txt"

mkdir -p "$SCRATCH/sub"
echo secret > "$SCRATCH/sub/id_rsa"
assert_decision "pre-commit denies a secret pulled in by 'git add .'" \
  pre-commit-check.sh "git add . && git commit -m x" deny "$SCRATCH"
rm -rf "$SCRATCH/sub"

assert_decision "pre-commit fails closed on unresolvable git add args" \
  pre-commit-check.sh 'git add $(cat list) && git commit -m x' deny "$SCRATCH"

# --- pre-commit gate: SECRET_PATH_RE regression cases ---------------------
# The bug this whole block exists for: id_rsa/id_ed25519 were anchored with a
# required leading '/', so a repo-ROOT key (git's own relative path has no
# leading slash) was never matched. sub/id_rsa above already covered the
# nested case and passed even with the bug present.
echo secret > "$SCRATCH/id_rsa"
assert_decision "pre-commit denies id_rsa at repo root" \
  pre-commit-check.sh "git add id_rsa && git commit -m x" deny "$SCRATCH"
rm -f "$SCRATCH/id_rsa"

echo secret > "$SCRATCH/id_ed25519"
assert_decision "pre-commit denies id_ed25519 at repo root" \
  pre-commit-check.sh "git add id_ed25519 && git commit -m x" deny "$SCRATCH"
rm -f "$SCRATCH/id_ed25519"

echo secret > "$SCRATCH/id_ecdsa"
assert_decision "pre-commit denies id_ecdsa (new coverage)" \
  pre-commit-check.sh "git add id_ecdsa && git commit -m x" deny "$SCRATCH"
rm -f "$SCRATCH/id_ecdsa"

echo 'export SECRET=x' > "$SCRATCH/.envrc"
assert_decision "pre-commit denies .envrc" \
  pre-commit-check.sh "git add .envrc && git commit -m x" deny "$SCRATCH"
rm -f "$SCRATCH/.envrc"

mkdir -p "$SCRATCH/secrets"
echo secret > "$SCRATCH/secrets/a.txt"
assert_decision "pre-commit denies a bare secrets/ dir" \
  pre-commit-check.sh "git add secrets && git commit -m x" deny "$SCRATCH"
rm -rf "$SCRATCH/secrets"

echo 'FOO=bar' > "$SCRATCH/.env.example"
assert_decision "pre-commit allows .env.example (false positive fixed)" \
  pre-commit-check.sh "git add .env.example && git commit -m x" allow "$SCRATCH"
rm -f "$SCRATCH/.env.example"

echo 'ssh-ed25519 AAAA...' > "$SCRATCH/id_ed25519.pub"
assert_decision "pre-commit allows a public key" \
  pre-commit-check.sh "git add id_ed25519.pub && git commit -m x" allow "$SCRATCH"
rm -f "$SCRATCH/id_ed25519.pub"

rm -rf "$SCRATCH"
trap - EXIT

# AWS approval routing: reads for actively used services auto-allow via the
# generated aws-read.rules; writes and unlisted services fall to Codex's
# prompt. Claude entries for services outside aws-read.rules intentionally
# prompt, as does `aws s3 cp s3://* -` (prefix rules can't see the '-' target).
if command -v codex >/dev/null 2>&1; then
  RULES=(--rules "$ROOT/.codex/rules/default.rules" --rules "$ROOT/.codex/rules/aws-read.rules")
  rules_decision() {
    # shellcheck disable=SC2086
    codex execpolicy check "${RULES[@]}" $1 2>/dev/null | jq -r '.decision // "prompt"'
  }
  USED_SERVICES=$(grep -oE 'pattern = \["aws", "[a-z0-9-]+"' "$ROOT/.codex/rules/aws-read.rules" | grep -oE '"[a-z0-9-]+"$' | tr -d '"')
  service_ops() {
    local var
    var="AWS_$(echo "$1" | tr '[:lower:]-' '[:upper:]_')_READ_OPS"
    awk -v v="$var = [" '$0 == v {f=1; next} f && /^\]/ {exit} f {gsub(/[", ]/, ""); print}' "$ROOT/.codex/rules/aws-read.rules"
  }

  while IFS= read -r entry; do
    cmd=${entry#Bash(}
    cmd=${cmd%)}
    service=$(printf '%s' "$cmd" | awk '{print $2}')
    op=$(printf '%s' "$cmd" | awk '{print $3}')
    grep -qx "$service" <<< "$USED_SERVICES" || continue
    [[ "$cmd" == "aws s3 cp"* ]] && continue
    if [[ "$op" == *-\* ]]; then
      # Wildcard verb: every real op with that prefix must be enumerated.
      candidates=$(service_ops "$service" | grep -E "^${op%\*}" || true)
      [[ -n "$candidates" ]] || {
        echo "FAIL aws read parity: no enumerated ops match Claude entry '$entry'" >&2
        exit 1
      }
    else
      candidates=$op
    fi
    while IFS= read -r candidate; do
      concrete="aws $service $candidate"
      decision=$(rules_decision "$concrete")
      [[ "$decision" == "allow" ]] || {
        echo "FAIL aws read parity: '$concrete' is '$decision' in Codex but allowed in Claude ($entry)" >&2
        exit 1
      }
      assert_decision "aws hook passes read: $concrete" aws-readonly-check.sh "$concrete" allow
    done <<< "$candidates"
  done < <(jq -r '.permissions.allow[] | select(startswith("Bash(aws "))' "$ROOT/.claude/settings.json")

  while IFS='|' read -r name command; do
    decision=$(rules_decision "$command")
    [[ "$decision" != "allow" ]] || {
      echo "FAIL aws write must prompt: '$command' is auto-allowed" >&2
      exit 1
    }
    PASS=$((PASS + 1))
  done <<'WRITES'
ce write|aws ce delete-anomaly-monitor --monitor-arn arn
iam write|aws iam create-user --user-name x
logs write|aws logs delete-log-group --log-group-name x
configure write|aws configure set region us-east-1
sts session token mints credentials|aws sts get-session-token
sts federation token mints credentials|aws sts get-federation-token
s3 upload|aws s3 cp local.txt s3://bucket/key
amplify write|aws amplify delete-app --app-id x
WRITES
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
grep -Fxq 'approvals_reviewer = "auto_review"' "$CODEX_CONFIG"
NEWLINE_KEYS=$(sed -n '/^\[tui\.keymap\.editor\]$/,/^\[/p' "$CODEX_CONFIG")
[[ "$NEWLINE_KEYS" == *'insert_newline = ["shift-enter", "ctrl-enter"]'* ]]
FILTERED_CONFIG=$("$ROOT/.codex/strip-hooks-state.sh" < "$CODEX_CONFIG")
[[ "$FILTERED_CONFIG" == *'notify = '* && "$FILTERED_CONFIG" != *'[hooks.state'* ]]
[[ ! -e "$ROOT/.codex/config.toml" ]]
grep -q 'CODEX_USER_CONFIG=".codex/user-config.toml"' "$ROOT/setup.sh"
grep -Fxq 'aws-core@agent-toolkit-for-aws' "$ROOT/.codex/plugins.txt"
grep -Fxq 'javier-plugins jfa94/web-designer' "$ROOT/.codex/plugin-marketplaces.txt"
grep -Fxq 'web-designer@javier-plugins' "$ROOT/.codex/plugins.txt"
if grep -Eq '^(superpowers|codex-security|ponytail)@' "$ROOT/.codex/plugins.txt"; then
  exit 1
fi
for plugin in \
  stripe@openai-curated \
  posthog@openai-curated \
  aws-core@agent-toolkit-for-aws \
  visualize@openai-bundled \
  computer-use@openai-bundled \
  sites@openai-bundled \
  browser@openai-bundled \
  web-designer@javier-plugins
do
  [[ $(grep -A1 "^\[plugins\\.\"$plugin\"\]$" "$CODEX_CONFIG" | tail -1) == "enabled = true" ]]
done
for plugin in \
  superpowers@openai-curated \
  codex-security@openai-curated \
  ponytail@ponytail \
  documents@openai-primary-runtime \
  pdf@openai-primary-runtime \
  spreadsheets@openai-primary-runtime \
  presentations@openai-primary-runtime \
  template-creator@openai-primary-runtime \
  github@openai-curated-remote
do
  if grep -qF "[plugins.\"$plugin\"]" "$CODEX_CONFIG"; then
    exit 1
  fi
done
[[ -f "$ROOT/.claude/hooks/superpowers-compact-reinject.sh" ]]
PASS=$((PASS + 1))

FILESYSTEM_PROFILE=$(sed -n '/^\[permissions\.workspace-net\.filesystem\]$/,/^\[permissions\.workspace-net\.filesystem\./p' "$CODEX_CONFIG" | sed '$d')
[[ $(printf '%s\n' "$FILESYSTEM_PROFILE" | awk '$0 == "glob_scan_max_depth = 32" { count++ } END { print count + 0 }') -eq 1 ]]
WORKSPACE_PROFILE=$(sed -n '/^\[permissions\.workspace-net\.filesystem\.\":workspace_roots"\]$/,/^\[/p' "$CODEX_CONFIG")
[[ "$WORKSPACE_PROFILE" == *'".git" = "write"'* ]]
PASS=$((PASS + 1))

echo "codex parity: $PASS checks passed"
