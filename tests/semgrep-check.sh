#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/semgrep" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_DIR/args"
printf '%s' "${FAKE_SEMGREP_JSON:-}"
exit "${FAKE_SEMGREP_RC:-0}"
EOF
chmod +x "$STUB_DIR/semgrep"

new_repo() {
  local dir=$1 branch=$2
  git init -q -b "$branch" "$dir"
  git -C "$dir" config user.email t@t.com
  git -C "$dir" config user.name t
  echo base > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m init
}

# Feature commit: add a.ts, delete README.md.
add_feature_commit() {
  echo code > "$1/a.ts"
  git -C "$1" add a.ts
  git -C "$1" rm -q README.md
  git -C "$1" commit -q -m feature
}

# Prints "<decision>" and leaves the stub's argv in $STUB_DIR/args.
run_hook() {
  local runtime=$1 repo=$2 cmd=${3:-git push} output
  rm -f "$STUB_DIR/args" /tmp/semgrep-cache-*.json
  if [[ "$runtime" == claude ]]; then
    output=$(CLAUDE_PROJECT_DIR="$repo" PATH="$STUB_DIR:$PATH" bash "$ROOT/.claude/hooks/semgrep-check.sh" \
      <<< "$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')" 2>/dev/null)
  else
    output=$(PATH="$STUB_DIR:$PATH" bash "$ROOT/.codex/hooks/semgrep-check.sh" \
      <<< "$(jq -cn --arg cwd "$repo" --arg c "$cmd" '{cwd:$cwd,tool_input:{command:$c}}')" 2>/dev/null)
  fi
  if [[ -n "$output" ]]; then
    jq -r '.hookSpecificOutput.permissionDecision' <<< "$output"
  else
    echo allow
  fi
}

check() {
  local name=$1 actual=$2 expected=$3
  [[ "$actual" == "$expected" ]] || { echo "FAIL $name: expected $expected, got $actual" >&2; exit 1; }
  PASS=$((PASS + 1))
}

cache_for() { echo "/tmp/semgrep-cache-v2-$(git -C "$1" rev-parse HEAD).json"; }

# origin/main base, one deleted and one added file.
git init -q --bare -b main "$TMP/origin.git"
new_repo "$TMP/r1" main
git -C "$TMP/r1" remote add origin "$TMP/origin.git"
git -C "$TMP/r1" push -q origin main
add_feature_commit "$TMP/r1"

# Remote default is master, no origin/main.
git init -q --bare -b master "$TMP/origin-master.git"
new_repo "$TMP/r2" master
echo keep > "$TMP/r2/keep.ts"
git -C "$TMP/r2" add keep.ts
git -C "$TMP/r2" commit -q -m keep
git -C "$TMP/r2" remote add origin "$TMP/origin-master.git"
git -C "$TMP/r2" push -q origin master
add_feature_commit "$TMP/r2"

# No remote at all.
new_repo "$TMP/r3" main
add_feature_commit "$TMP/r3"
echo extra > "$TMP/r3/b.ts"
git -C "$TMP/r3" add b.ts
git -C "$TMP/r3" commit -q -m more

CLEAN='{"results":[]}'
FOUND='{"results":[{"path":"a.ts"}]}'

for rt in claude codex; do
  export FAKE_SEMGREP_RC=0 FAKE_SEMGREP_JSON="$CLEAN"
  check "$rt clean scan allows" "$(run_hook $rt "$TMP/r1")" allow
  grep -qx 'a.ts' "$STUB_DIR/args" || { echo "FAIL $rt: a.ts not scanned" >&2; exit 1; }
  ! grep -qx 'README.md' "$STUB_DIR/args" || { echo "FAIL $rt: deleted file passed to semgrep" >&2; exit 1; }
  ! grep -qx -- '--error' "$STUB_DIR/args" || { echo "FAIL $rt: --error still passed" >&2; exit 1; }
  [[ -f "$(cache_for "$TMP/r1")" ]] || { echo "FAIL $rt: clean result not cached" >&2; exit 1; }
  PASS=$((PASS + 3))

  export FAKE_SEMGREP_RC=0 FAKE_SEMGREP_JSON="$FOUND"
  check "$rt findings deny" "$(run_hook $rt "$TMP/r1")" deny
  check "$rt subshell push triggers" "$(run_hook $rt "$TMP/r1" "(git push)")" deny
  check "$rt wrapped push triggers" "$(run_hook $rt "$TMP/r1" "env A=1 git push")" deny

  export FAKE_SEMGREP_RC=2 FAKE_SEMGREP_JSON="$CLEAN"
  if [[ "$rt" == claude ]]; then expected=allow; else expected=deny; fi
  check "$rt scan failure" "$(run_hook $rt "$TMP/r1")" "$expected"
  [[ ! -e "$(cache_for "$TMP/r1")" ]] || { echo "FAIL $rt: failed scan was cached" >&2; exit 1; }
  PASS=$((PASS + 1))

  export FAKE_SEMGREP_RC=0 FAKE_SEMGREP_JSON="$CLEAN"
  run_hook $rt "$TMP/r2" >/dev/null
  grep -qx 'a.ts' "$STUB_DIR/args" || { echo "FAIL $rt: changed file not scanned" >&2; exit 1; }
  ! grep -qx 'keep.ts' "$STUB_DIR/args" || { echo "FAIL $rt: origin/master base not used" >&2; exit 1; }
  PASS=$((PASS + 1))

  run_hook $rt "$TMP/r3" >/dev/null
  for f in a.ts b.ts; do
    grep -qx "$f" "$STUB_DIR/args" || { echo "FAIL $rt: no-remote repo did not scan $f" >&2; exit 1; }
  done
  PASS=$((PASS + 1))
done

echo "semgrep-check: $PASS checks passed"
