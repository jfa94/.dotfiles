#!/usr/bin/env bash
# shellcheck disable=SC2016 # Command fixtures intentionally contain expansions.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.claude/hooks/pre-commit-check.sh"
PASS=0

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
git -C "$SCRATCH" init -q
git -C "$SCRATCH" config user.email t@t.com
git -C "$SCRATCH" config user.name t
echo readme > "$SCRATCH/README.md"
git -C "$SCRATCH" add README.md
git -C "$SCRATCH" commit -q -m init

assert_decision() {
  local name=$1 command=$2 expected=$3 output decision
  output=$(CLAUDE_PROJECT_DIR="$SCRATCH" "$HOOK" <<< "$(jq -cn --arg c "$command" '{tool_input:{command:$c}}')" 2>/dev/null)
  if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  else
    decision=allow
  fi
  [[ "$decision" == "$expected" ]] || { echo "FAIL $name: expected $expected, got $decision: $output" >&2; exit 1; }
  PASS=$((PASS + 1))
}

# Assembled at runtime so this file doesn't trip the secret scan itself.
FAKE_AWS_KEY="AKIA$(printf 'IOSFODNN7EXAMPLE')"
PW_KEY="pass$(printf 'word')"

assert_decision "not a commit" "git status" allow

echo 'X=1' > "$SCRATCH/.env"
assert_decision "denies .env added in the same command" "git add .env && git commit -m x" deny
rm -f "$SCRATCH/.env"

echo hi > "$SCRATCH/notes.txt"
assert_decision "allows a plain file added in the same command" "git add . && git commit -m x" allow
rm -f "$SCRATCH/notes.txt"

assert_decision "fails closed on unresolvable git add args" 'git add $(cat l) && git commit -m x' deny

mkdir -p "$SCRATCH/sub"
echo secret > "$SCRATCH/sub/id_rsa"
assert_decision "denies a key pulled in by git add ." "git add . && git commit -m x" deny
rm -rf "$SCRATCH/sub"

echo 'FOO=bar' > "$SCRATCH/.env.example"
assert_decision "allows .env.example" "git add .env.example && git commit -m x" allow
rm -f "$SCRATCH/.env.example"

echo "key = $FAKE_AWS_KEY" > "$SCRATCH/leak.txt"
assert_decision "denies an untracked secret value added in the same command" "git add leak.txt && git commit -m x" deny
rm -f "$SCRATCH/leak.txt"

echo "key = $FAKE_AWS_KEY" >> "$SCRATCH/README.md"
assert_decision "denies a secret in a tracked file committed with -am" "git commit -am x" deny
assert_decision "denies a secret committed with --all" "git commit --all -m x" deny
assert_decision "ignores unstaged changes without -a" "git commit -m x" allow
assert_decision "does not treat --amend as -a" "git commit --amend -m x" allow
git -C "$SCRATCH" checkout -q -- README.md

# Generic password patterns skip test files but not source files.
mkdir -p "$SCRATCH/tests"
echo "const $PW_KEY = \"hunter2hunter2\"" > "$SCRATCH/tests/a.test.ts"
assert_decision "allows a password fixture in a test file" "git add tests && git commit -m x" allow
echo "const $PW_KEY = \"hunter2hunter2\"" > "$SCRATCH/config.ts"
assert_decision "denies a password literal in source" "git add config.ts && git commit -m x" deny
rm -rf "$SCRATCH/tests" "$SCRATCH/config.ts"

echo "pre-commit-check: $PASS checks passed"
