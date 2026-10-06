#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/repo"
cat > "$STUB_DIR/pnpm" <<'EOF'
#!/bin/bash
echo "noisy pnpm output: $*"
exit "${FAKE_PNPM_RC:-0}"
EOF
chmod +x "$STUB_DIR/pnpm"
echo '{"scripts":{"quality":"x"}}' > "$TMP/repo/package.json"

# Real repos: a feature branch (gate skipped) and main with a subdirectory cwd.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
for b in feat main; do
  git init -q -b "$b" "$TMP/on-$b"
  git -C "$TMP/on-$b" config user.email t@t.com
  git -C "$TMP/on-$b" config user.name t
  echo '{"scripts":{"quality":"x"}}' > "$TMP/on-$b/package.json"
  mkdir -p "$TMP/on-$b/sub"
done

# Prints raw stdout; the hook must emit exactly one JSON object or nothing.
run_hook() {
  local runtime=$1 cmd=${2:-git push} dir=${3:-$TMP/repo}
  if [[ "$runtime" == claude ]]; then
    CLAUDE_PROJECT_DIR="$TMP/repo" PATH="$STUB_DIR:$PATH" bash "$ROOT/.claude/hooks/pre-push-check.sh" \
      <<< "$(jq -cn --arg cwd "$dir" --arg c "$cmd" '{cwd:$cwd,tool_input:{command:$c}}')" 2>/dev/null
  else
    PATH="$STUB_DIR:$PATH" bash "$ROOT/.codex/hooks/pre-push-check.sh" \
      <<< "$(jq -cn --arg cwd "$dir" --arg c "$cmd" '{cwd:$cwd,tool_input:{command:$c}}')" 2>/dev/null
  fi
}

for rt in claude codex; do
  output=$(FAKE_PNPM_RC=1 run_hook $rt)
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" >/dev/null \
    || { echo "FAIL $rt: failing quality gate must emit one deny JSON object, got: $output" >&2; exit 1; }
  output=$(FAKE_PNPM_RC=0 run_hook $rt)
  [[ -z "$output" ]] || { echo "FAIL $rt: passing quality gate must print nothing, got: $output" >&2; exit 1; }
  PASS=$((PASS + 2))
  for cmd in "(git push)" "{ git push; }" "env A=1 git push" "command git push origin"; do
    output=$(FAKE_PNPM_RC=1 run_hook $rt "$cmd")
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" >/dev/null \
      || { echo "FAIL $rt: '$cmd' must trigger the gate, got: $output" >&2; exit 1; }
    PASS=$((PASS + 1))
  done
  output=$(FAKE_PNPM_RC=1 run_hook $rt 'grep -n "git push" notes.md')
  [[ -z "$output" ]] || { echo "FAIL $rt: a quoted mention must not trigger the gate, got: $output" >&2; exit 1; }
  PASS=$((PASS + 1))
  # Branch scoping: only main/develop pushes are gated.
  output=$(FAKE_PNPM_RC=1 run_hook $rt "git push -u origin feat" "$TMP/on-feat")
  [[ -z "$output" ]] || { echo "FAIL $rt: feature-branch push must skip the gate, got: $output" >&2; exit 1; }
  output=$(FAKE_PNPM_RC=1 run_hook $rt "git push" "$TMP/on-feat")
  [[ -z "$output" ]] || { echo "FAIL $rt: implicit feature push must skip the gate, got: $output" >&2; exit 1; }
  for cmd in "git push origin main" "git push origin HEAD:develop" "git push"; do
    output=$(FAKE_PNPM_RC=1 run_hook $rt "$cmd" "$TMP/on-main")
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" >/dev/null \
      || { echo "FAIL $rt: '$cmd' on main must be gated, got: $output" >&2; exit 1; }
    PASS=$((PASS + 1))
  done
  # The agent only sees the deny reason, so it must carry the gate's output.
  output=$(FAKE_PNPM_RC=1 run_hook $rt "git push origin main" "$TMP/on-main")
  jq -e '.hookSpecificOutput.permissionDecisionReason | contains("noisy pnpm output: quality")' <<< "$output" >/dev/null \
    || { echo "FAIL $rt: deny reason must include the failing output, got: $output" >&2; exit 1; }
  # A subdirectory cwd still finds the repo root and its package.json.
  output=$(FAKE_PNPM_RC=1 run_hook $rt "git push origin main" "$TMP/on-main/sub")
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" >/dev/null \
    || { echo "FAIL $rt: subdirectory cwd must still be gated, got: $output" >&2; exit 1; }
  output=$(FAKE_PNPM_RC=0 run_hook $rt "git push origin main" "$TMP/on-main")
  [[ -z "$output" ]] || { echo "FAIL $rt: passing gate on main must print nothing, got: $output" >&2; exit 1; }
  PASS=$((PASS + 5))
done

echo "pre-push-check: $PASS checks passed"
