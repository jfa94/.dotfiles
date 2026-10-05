#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.claude/hooks/protected-files-check.sh"
PASS=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

decision_for() {
  local path=$1 output
  output=$(CLAUDE_PROJECT_DIR="${2:-$ROOT}" "$HOOK" <<< "$(jq -cn --arg p "$path" '{tool_input:{file_path:$p}}')")
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision'
  else
    printf 'pass\n'
  fi
}

assert_decision() {
  local name=$1 path=$2 expected=$3 actual
  actual=$(decision_for "$path" "${4:-$ROOT}")
  [[ "$actual" == "$expected" ]] || { echo "FAIL $name ($path): expected $expected, got $actual" >&2; exit 1; }
  PASS=$((PASS + 1))
}

# --- secret paths -----------------------------------------------------------
for p in /x/.env /x/.env.local /x/secrets/a /x/server.pem /x/tls.key /h/.ssh/id_ed25519 /h/.ssh/id_rsa \
  /h/.aws/credentials /h/.git-credentials /x/credentials.json /x/CERT.PEM; do
  assert_decision "denies $p" "$p" deny
done
for p in /x/.env.example /x/id_rsa.pub /x/src/credentials.ts /x/foo.env.ts /x/keyboard.tsx /x/aws-credentials-helper.ts /x/src/a.ts; do
  assert_decision "does not deny $p" "$p" pass
done

# --- applied migrations -----------------------------------------------------
git init -q --bare -b main "$TMP/origin.git"
R1="$TMP/repo1"
git init -q -b main "$R1"
git -C "$R1" config user.email t@t.com
git -C "$R1" config user.name t
git -C "$R1" remote add origin "$TMP/origin.git"
echo r > "$R1/README.md"
git -C "$R1" add README.md
git -C "$R1" commit -q -m init
mkdir -p "$R1/supabase/migrations"
echo 'select 1;' > "$R1/supabase/migrations/001.sql"
git -C "$R1" add supabase
git -C "$R1" commit -q -m migration
git -C "$R1" push -q origin main

assert_decision "asks for a migration applied on local main" "$R1/supabase/migrations/001.sql" ask "$R1"

# Local main no longer has it; origin/main still does and must win.
git -C "$R1" reset -q --hard HEAD~1
assert_decision "asks when only origin/main has the migration" "$R1/supabase/migrations/001.sql" ask "$R1"

assert_decision "passes a new migration" "$R1/supabase/migrations/002.sql" pass "$R1"
assert_decision "passes a migration in a not-yet-created directory" "$R1/new/migrations/001.sql" pass "$R1"

# The session project is a different repo from the file's repo.
R2="$TMP/repo2"
git init -q -b main "$R2"
git -C "$R2" config user.email t@t.com
git -C "$R2" config user.name t
mkdir -p "$R2/db/migrations"
echo 'select 1;' > "$R2/db/migrations/001.sql"
git -C "$R2" add db
git -C "$R2" commit -q -m init
assert_decision "asks for a migration in another repo" "$R2/db/migrations/001.sql" ask "$R1"

# No ref to compare against: cannot verify, so confirm.
R3="$TMP/repo3"
git init -q -b main "$R3"
mkdir -p "$R3/migrations"
assert_decision "asks when no default-branch ref resolves" "$R3/migrations/001.sql" ask "$R1"

# Outside any repository there is nothing applied to protect.
mkdir -p "$TMP/plain/migrations"
assert_decision "passes outside a repo" "$TMP/plain/migrations/001.sql" pass "$R1"
assert_decision "passes outside a repo, directory missing" "$TMP/plain/a/b/migrations/001.sql" pass "$R1"

echo "protected-files: $PASS checks passed"
