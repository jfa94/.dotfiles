#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.claude/hooks/npm-to-pnpm.sh"
PASS=0

run() { "$HOOK" <<< "$(jq -cn --arg c "$1" '{tool_input:{command:$c}}')"; }

assert_suggestion() {
  local command=$1 suggestion=$2 output
  output=$(run "$command")
  jq -e --arg s "$suggestion" '.hookSpecificOutput.permissionDecision == "deny"
    and (.hookSpecificOutput.permissionDecisionReason | contains($s))
    and (.hookSpecificOutput.updatedInput == null)' <<< "$output" >/dev/null \
    || { echo "FAIL npm-to-pnpm '$command': $output" >&2; exit 1; }
  PASS=$((PASS + 1))
}

assert_silent() {
  local output
  output=$(run "$1")
  [[ -z "$output" ]] || { echo "FAIL npm-to-pnpm should ignore '$1': $output" >&2; exit 1; }
  PASS=$((PASS + 1))
}

assert_suggestion "npm install" "pnpm install"
assert_suggestion "npx foo" "pnpm dlx foo"
assert_suggestion "echo hi && npm test" "pnpm test"
assert_suggestion "npm ci" "pnpm install --frozen-lockfile"
assert_silent "pnpm install"
assert_silent "echo npm"

echo "npm-to-pnpm: $PASS checks passed"
