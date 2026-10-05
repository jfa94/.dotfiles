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

# Optional 4th arg: project dir (default $SCRATCH); 5th: dir prepended to PATH.
assert_decision() {
  local name=$1 command=$2 expected=$3 dir=${4:-$SCRATCH} bin=${5:-} output decision
  output=$(PATH="${bin:+$bin:}$PATH" CLAUDE_PROJECT_DIR="$dir" "$HOOK" \
    <<< "$(jq -cn --arg c "$command" '{tool_input:{command:$c}}')" 2>/dev/null)
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

# Fake scanners: one reports a finding only for MARKER (no regex sweep matches it),
# the other always fails.
MARKER=th-marker-7f3a
mkdir -p "$SCRATCH/.bin-marker" "$SCRATCH/.bin-fail"
printf '#!/bin/sh\ngrep -q %s "$2" && echo "{}"\nexit 0\n' "$MARKER" > "$SCRATCH/.bin-marker/trufflehog"
printf '#!/bin/sh\necho boom >&2\nexit 1\n' > "$SCRATCH/.bin-fail/trufflehog"
chmod +x "$SCRATCH/.bin-marker/trufflehog" "$SCRATCH/.bin-fail/trufflehog"
printf '.bin-*/\n' > "$SCRATCH/.git/info/exclude"

# Paths from git are repo-root relative; the hook must resolve them from a subdirectory.
mkdir -p "$SCRATCH/sub"
echo "key = $FAKE_AWS_KEY" > "$SCRATCH/sub/k.txt"
assert_decision "denies a secret added from a subdirectory" "git add k.txt && git commit -m x" deny "$SCRATCH/sub"
echo hi > "$SCRATCH/sub/k.txt"
assert_decision "allows a plain file added from a subdirectory" "git add k.txt && git commit -m x" allow "$SCRATCH/sub"
echo "const $PW_KEY = \"hunter2hunter2\"" > "$SCRATCH/sub/c.ts"
git -C "$SCRATCH" add sub/c.ts
assert_decision "denies a staged password literal from a subdirectory" "git commit -m x" deny "$SCRATCH/sub"
git -C "$SCRATCH" reset -q
echo "key = $FAKE_AWS_KEY" >> "$SCRATCH/README.md"
assert_decision "denies a root secret committed with -am from a subdirectory" "git commit -am x" deny "$SCRATCH/sub"
git -C "$SCRATCH" checkout -q -- README.md
rm -rf "$SCRATCH/sub"

# Staged and re-added: both the index and the worktree version are scanned.
echo clean > "$SCRATCH/f.txt"
git -C "$SCRATCH" add f.txt
echo "$MARKER" > "$SCRATCH/f.txt"
assert_decision "scans the worktree version of a re-added staged file" \
  "git add f.txt && git commit -m x" deny "$SCRATCH" "$SCRATCH/.bin-marker"
git -C "$SCRATCH" add f.txt
echo clean > "$SCRATCH/f.txt"
assert_decision "scans the index version when -a over-matches the message" \
  'git commit -m "fix -a thing"' deny "$SCRATCH" "$SCRATCH/.bin-marker"
git -C "$SCRATCH" reset -q
rm -f "$SCRATCH/f.txt"

echo hi > "$SCRATCH/notes.txt"
assert_decision "fails closed when the scanner errors" \
  "git add notes.txt && git commit -m x" deny "$SCRATCH" "$SCRATCH/.bin-fail"
rm -f "$SCRATCH/notes.txt"

assert_decision "fails closed when the project dir is missing" "git commit -m x" deny "$SCRATCH/missing"

# Submodule pointers and symlinks commit no scannable content.
git -C "$SCRATCH" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,nested"
assert_decision "allows a staged submodule pointer" "git commit -m x" allow
git -C "$SCRATCH" reset -q

ln -s nowhere "$SCRATCH/link"
assert_decision "allows a dangling symlink" "git add link && git commit -m x" allow
rm -f "$SCRATCH/link"

# Non-ASCII names staged beforehand reach the hook through --name-only, not the dry run.
echo hi > "$SCRATCH/café.md"
git -C "$SCRATCH" add café.md
assert_decision "allows a staged non-ASCII file name" "git commit -m x" allow
git -C "$SCRATCH" reset -q
rm -f "$SCRATCH/café.md"
echo "const $PW_KEY = \"hunter2hunter2\"" > "$SCRATCH/café.ts"
git -C "$SCRATCH" add café.ts
assert_decision "denies a password literal in a staged non-ASCII source file" "git commit -m x" deny
git -C "$SCRATCH" reset -q
rm -f "$SCRATCH/café.ts"

# Last: commits a nested repo, then advances it so -a lists the submodule.
git init -q "$SCRATCH/mod"
git -C "$SCRATCH/mod" -c user.email=t@t.com -c user.name=t commit -q --allow-empty -m one
git -C "$SCRATCH" add mod 2>/dev/null
git -C "$SCRATCH" commit -q -m mod
git -C "$SCRATCH/mod" -c user.email=t@t.com -c user.name=t commit -q --allow-empty -m two
assert_decision "allows -a over an advanced submodule" "git commit -am x" allow

echo "pre-commit-check: $PASS checks passed"
