#!/usr/bin/env bash
# Tests for sessionstart-op-env.sh and the fetcher: gating, dependencies, value
# round trips, refresh semantics, failures, secrecy and hygiene. Fake node and
# timeout stand in for the SDK; no 1Password access is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$ROOT/.claude/hooks/sessionstart-op-env.sh"
REAL_NODE="$(command -v node)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

# Assembled at runtime so no literal secret-looking strings live in this file.
M_TOKEN="tok-$(printf 'MARKER')-1"
M_VALUE="val-$(printf 'MARKER')-2"
M_ERR="err-$(printf 'MARKER')-3"
M_NAME="nam-$(printf 'MARKER')-4"

# --- static checks and fetcher unit tests -----------------------------------

bash -n "$HOOK_SRC" || fail "bash -n"
if command -v shellcheck &>/dev/null; then
  shellcheck "$HOOK_SRC" || fail "shellcheck"
fi
out="$("$REAL_NODE" --test "$ROOT/cloud/op-env/fetch-variables.test.mjs" 2>&1)" \
  || { printf '%s\n' "$out" >&2; fail "fetcher tests"; }

# --- registration ------------------------------------------------------------

jq -e '[.hooks.SessionStart[]
        | select(.matcher == "startup|resume|clear|fork")
        | .hooks[]
        | select((.command | endswith("/sessionstart-op-env.sh")) and .timeout > 45)]
       | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
  || fail "hook not registered with matcher startup|resume|clear|fork and timeout > 45"

# --- fixtures: fake tools, restricted PATH ----------------------------------

bin="$tmp/bin"
realbin="$tmp/realbin"
mkdir -p "$bin" "$realbin"
for c in jq readlink mkdir mktemp grep mv rm cat; do
  p="$(command -v "$c")"
  [[ "$p" == /* ]] && ln -s "$p" "$realbin/$c"
done
# Fake node prints FAKE_OUT_FILE, writes FAKE_ERR to stderr, exits FAKE_STATUS.
cat > "$bin/node" <<'EOF'
#!/bin/bash
[ -z "${FAKE_ERR:-}" ] || printf '%s\n' "$FAKE_ERR" >&2
[ -z "${FAKE_OUT_FILE:-}" ] || cat "$FAKE_OUT_FILE"
exit "${FAKE_STATUS:-0}"
EOF
# Fake timeout records its duration, returns 124 on request, else runs the command.
cat > "$bin/timeout" <<'EOF'
#!/bin/bash
[ -z "${FAKE_TIMEOUT_LOG:-}" ] || printf '%s\n' "$1" > "$FAKE_TIMEOUT_LOG"
[ "${FAKE_TIMEOUT_EXPIRE:-}" != 1 ] || exit 124
shift
exec "$@"
EOF
chmod +x "$bin"/*

# A PATH lacking one tool, to simulate it being missing.
path_without() {
  local d="$tmp/path-without-$1" f
  mkdir -p "$d"
  for f in "$bin"/* "$realbin"/*; do
    [[ "${f##*/}" == "$1" ]] || ln -s "$f" "$d/"
  done
  printf '%s' "$d"
}

# --- per-case helpers --------------------------------------------------------

n=0
new_case() {
  n=$((n + 1))
  cdir="$tmp/c$n"
  home="$cdir/home"
  repo="$cdir/repo"
  state="$home/.local/state/claude-op-env"
  exports="$state/exports.sh"
  envf="$cdir/session-env/s1/hook-0.sh"
  hook="$repo/.claude/hooks/sessionstart-op-env.sh"
  mkdir -p "$home" "$repo/.claude/hooks" "$repo/cloud/op-env/node_modules/@1password/sdk" "${envf%/*}"
  cp "$HOOK_SRC" "$hook"
  chmod +x "$hook"
  echo '// placeholder' > "$repo/cloud/op-env/fetch-variables.mjs"
  unset ENVFILE
  REMOTE=true TOKEN="$M_TOKEN" ENVID=env-id HOOK_PATH="$bin:$realbin"
  FAKE_OUT_FILE="$cdir/out.json" FAKE_ERR="" FAKE_STATUS=0 FAKE_TIMEOUT_EXPIRE=0
  : > "$FAKE_OUT_FILE"
}

# Runs the hook; asserts the invariants that hold for every run.
run_hook() {
  local -a e=(HOME="$home" PATH="$HOOK_PATH" FAKE_OUT_FILE="$FAKE_OUT_FILE" FAKE_ERR="$FAKE_ERR"
    FAKE_STATUS="$FAKE_STATUS" FAKE_TIMEOUT_EXPIRE="$FAKE_TIMEOUT_EXPIRE" FAKE_TIMEOUT_LOG="$cdir/timeout.log")
  [[ -z "$REMOTE" ]] || e+=(CLAUDE_CODE_REMOTE="$REMOTE")
  [[ -z "$TOKEN" ]] || e+=(OP_SERVICE_ACCOUNT_TOKEN="$TOKEN")
  [[ -z "$ENVID" ]] || e+=(OP_ENVIRONMENT_ID="$ENVID")
  [[ -z "${ENVFILE-$envf}" ]] || e+=(CLAUDE_ENV_FILE="${ENVFILE-$envf}")
  rc=0
  env -i "${e[@]}" "$hook" >"$cdir/stdout" 2>"$cdir/stderr" || rc=$?
  [[ $rc -eq 0 ]] || fail "hook exited $rc"
  [[ ! -s "$cdir/stderr" ]] || fail "hook wrote to stderr"
  if [[ -s "$cdir/stdout" ]]; then
    jq -e '.hookSpecificOutput.hookEventName == "SessionStart"
           and (.hookSpecificOutput.additionalContext | type == "string")' "$cdir/stdout" >/dev/null \
      || fail "stdout is not SessionStart hook JSON"
  fi
  for m in "$M_TOKEN" "$M_VALUE" "$M_ERR" "$M_NAME"; do
    ! grep -qF -- "$m" "$cdir/stdout" "$cdir/stderr" || fail "secret marker leaked into hook output"
  done
}

msg() { jq -r '.hookSpecificOutput.additionalContext' "$cdir/stdout"; }
assert_msg() { [[ "$(msg)" == *"$1"* ]] || fail "$2: expected '$1', got '$(msg)'"; }
assert_silent() { [[ ! -s "$cdir/stdout" ]] || fail "$1: expected no output, got '$(cat "$cdir/stdout")'"; }

source_line_count() { grep -cxF -- "$(grep -F "$exports" "$1" | head -1)" "$1" || true; }
has_source_line() { [[ -f "$1" ]] && grep -qF -- ". $exports" "$1"; }

# Source env file $1 in a clean shell; variable $2 must equal $3 byte for byte.
# shellcheck disable=SC2016  # the bash -c program must expand in the child shell
check_var() {
  printf '%s' "$3" > "$cdir/want"
  env -i PATH="$realbin" /bin/bash -c '. "$1"; printf "%s" "${!2}"' _ "$1" "$2" > "$cdir/got"
  cmp -s "$cdir/want" "$cdir/got" || fail "value mismatch for $2"
}
# shellcheck disable=SC2016  # the bash -c program must expand in the child shell
check_unset() {
  [[ -z "$(env -i PATH="$realbin" /bin/bash -c '. "$1"; printf "%s" "${!2+set}"' _ "$1" "$2")" ]] \
    || fail "$2 should be unset"
}

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
no_temp_files() { [[ -z "$(find "$state" -type f ! -name exports.sh)" ]] || fail "$1: temp files left behind"; }

seed_exports() {
  mkdir -p "$state"
  printf "export OLD_VAR='old'\n" > "$exports"
  cp "$exports" "$cdir/exports.before"
}

# --- gating ------------------------------------------------------------------

for remote in "" false; do
  new_case; REMOTE="$remote"
  echo 'export KEEP=1' > "$envf"; cp "$envf" "$cdir/env.before"
  run_hook
  assert_silent "remote='$remote'"
  [[ ! -e "$home/.local" ]] || fail "remote='$remote': state created outside cloud"
  cmp -s "$envf" "$cdir/env.before" || fail "remote='$remote': env file touched"
done

new_case; TOKEN=""; ENVID=""
run_hook
assert_silent "no inputs"
[[ ! -e "$home/.local" ]] || fail "no inputs: state created"

for only in token envid; do
  new_case
  if [[ $only == token ]]; then ENVID=""; else TOKEN=""; fi
  run_hook
  assert_msg "configuration incomplete" "only $only"
  assert_msg "no project variables are loaded" "only $only, no earlier values"
  ! has_source_line "$envf" || fail "only $only: source line added without exports"
  seed_exports
  run_hook
  assert_msg "may be stale" "only $only, earlier values"
  has_source_line "$envf" || fail "only $only: earlier values not delivered"
  cmp -s "$exports" "$cdir/exports.before" || fail "only $only: exports changed"
done

# --- dependencies ------------------------------------------------------------

for tool in jq timeout node; do
  new_case; seed_exports; HOOK_PATH="$(path_without "$tool")"
  run_hook
  assert_msg "dependency missing ($tool)" "missing $tool"
  assert_msg "may be stale" "missing $tool"
  cmp -s "$exports" "$cdir/exports.before" || fail "missing $tool: exports changed"
done

new_case; seed_exports; rm "$repo/cloud/op-env/fetch-variables.mjs"
run_hook
assert_msg "dependency missing (fetcher)" "missing fetcher"
cmp -s "$exports" "$cdir/exports.before" || fail "missing fetcher: exports changed"

new_case; seed_exports; rmdir "$repo/cloud/op-env/node_modules/@1password/sdk"
run_hook
assert_msg "dependency missing (SDK install)" "missing SDK"
cmp -s "$exports" "$cdir/exports.before" || fail "missing SDK: exports changed"

new_case; seed_exports; echo file > "$cdir/blocker"; ENVFILE="$cdir/blocker/env.sh"
run_hook
assert_msg "dependency missing (session env file)" "unusable env file"
assert_msg "no project variables are loaded" "unusable env file"
cmp -s "$exports" "$cdir/exports.before" || fail "unusable env file: exports changed"

new_case; seed_exports; ENVFILE=""
run_hook
assert_msg "dependency missing (session env file)" "unset env file"

# --- values ------------------------------------------------------------------

new_case
jq -n --arg a '' --arg b 'masked-1' --arg c $'line1\nline2' --arg d $'trail\n' \
  --arg e "it's" --arg f 'say "hi"' --arg g 'a\b' --arg h '$(echo hi) and `uname`' \
  --arg i 'a=b=c' --arg j 'héllo ✓' --arg k '  padded  ' \
  '[{name:"G2_EMPTY",value:$a},{name:"G2_MASKED",value:$b},{name:"G2_NEWLINE",value:$c},
    {name:"G2_TRAILING",value:$d},{name:"G2_SQUOTE",value:$e},{name:"G2_DQUOTE",value:$f},
    {name:"G2_BACKSLASH",value:$g},{name:"G2_SUBST",value:$h},{name:"G2_EQUALS",value:$i},
    {name:"G2_UNICODE",value:$j},{name:"G2_SPACES",value:$k}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Loaded 11 project variables from 1Password." "edge values"
check_var "$envf" G2_EMPTY ''
check_var "$envf" G2_MASKED 'masked-1'
check_var "$envf" G2_NEWLINE $'line1\nline2'
check_var "$envf" G2_TRAILING $'trail\n'
check_var "$envf" G2_SQUOTE "it's"
check_var "$envf" G2_DQUOTE 'say "hi"'
check_var "$envf" G2_BACKSLASH 'a\b'
# shellcheck disable=SC2016  # literal $( and backticks are the fixture
check_var "$envf" G2_SUBST '$(echo hi) and `uname`'
check_var "$envf" G2_EQUALS 'a=b=c'
check_var "$envf" G2_UNICODE 'héllo ✓'
check_var "$envf" G2_SPACES '  padded  '
[[ "$(cat "$cdir/timeout.log")" == 45 ]] || fail "read timeout is not 45 s"

# --- refresh -----------------------------------------------------------------

new_case
echo 'export KEEP=1' > "$envf"
printf '[{"name":"A","value":"1"},{"name":"B","value":"2"}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Loaded 2 project variables" "first refresh"
check_var "$envf" A 1
check_var "$envf" B 2
check_var "$envf" KEEP 1
printf '[{"name":"A","value":"9"}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Loaded 1 project variables" "second refresh"
check_var "$envf" A 9
check_unset "$envf" B
check_var "$envf" KEEP 1
[[ "$(source_line_count "$envf")" == 1 ]] || fail "source line not exactly once after repeated runs"
# A second session's env file resolves to the same latest values.
envf2="$cdir/session-env/s2/hook-0.sh"
mkdir -p "${envf2%/*}"
ENVFILE="$envf2"
run_hook
check_var "$envf2" A 9
check_unset "$envf2" B
check_var "$envf" A 9
[[ "$(source_line_count "$envf2")" == 1 ]] || fail "second env file source line count"

new_case
printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"
run_hook
printf '[]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Loaded 0 project variables" "empty environment"
[[ ! -s "$exports" ]] || fail "empty environment: exports not emptied"
check_unset "$envf" A

# --- failures ----------------------------------------------------------------

# expect_failure LABEL EXPECTED_TEXT: stale when earlier values exist, none otherwise.
expect_failure() {
  local label="$1" text="$2" before
  seed_exports; before="$cdir/exports.before"
  run_hook
  assert_msg "$text" "$label"
  assert_msg "may be stale" "$label"
  cmp -s "$exports" "$before" || fail "$label: exports changed"
  has_source_line "$envf" || fail "$label: earlier values not delivered"
  no_temp_files "$label"
  rm -r "$state"; rm -f "$envf"
  run_hook
  assert_msg "$text" "$label (fresh VM)"
  assert_msg "no project variables are loaded" "$label (fresh VM)"
  [[ ! -e "$exports" ]] || fail "$label: exports created despite failure"
  ! has_source_line "$envf" || fail "$label: source line added without values"
  no_temp_files "$label (fresh VM)"
}

new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"; FAKE_STATUS=1; FAKE_ERR="$M_ERR"
expect_failure "nonzero exit" "1Password read failed"

new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"; FAKE_TIMEOUT_EXPIRE=1
expect_failure "timeout" "1Password read timed out"

new_case; printf 'not json' > "$FAKE_OUT_FILE"
expect_failure "malformed JSON" "1Password data invalid"

new_case; printf '{"A":"1"}' > "$FAKE_OUT_FILE"
expect_failure "non-array" "1Password data invalid"

new_case; printf '[{"name":"A","value":5}]' > "$FAKE_OUT_FILE"
expect_failure "non-string value" "1Password data invalid (1 entries rejected)"

new_case; printf '[{"name":"%s","value":"1"},{"name":"B","value":"2"}]' "$M_NAME" > "$FAKE_OUT_FILE"
expect_failure "invalid name" "1Password data invalid (1 entries rejected)"

for name in my-var 1ABC 'A B' ''; do
  new_case; jq -n --arg n "$name" '[{name:$n,value:"1"}]' > "$FAKE_OUT_FILE"
  expect_failure "invalid name '$name'" "1Password data invalid (1 entries rejected)"
done

new_case; printf '[{"name":"A","value":"1"},{"name":"A","value":"2"}]' > "$FAKE_OUT_FILE"
expect_failure "duplicate name" "1Password data invalid (1 entries rejected)"

for name in OP_TOKEN OP_ANYTHING CLAUDE_CODE_X HOME PATH BASH_ENV ENV SHELLOPTS BASHOPTS; do
  new_case; jq -n --arg n "$name" '[{name:$n,value:"1"}]' > "$FAKE_OUT_FILE"
  expect_failure "reserved name $name" "1Password data invalid (1 entries rejected)"
done

new_case; printf '[{"name":"A","value":"a\\u0000b"}]' > "$FAKE_OUT_FILE"
expect_failure "NUL in value" "1Password data invalid (1 entries rejected)"

# An unusable state directory fails to publish and leaves the session untouched.
new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"
mkdir -p "$home/.local/state"; echo file > "$state"
run_hook
assert_msg "1Password variables could not be published" "unusable state dir"
assert_msg "no project variables are loaded" "unusable state dir"
! has_source_line "$envf" || fail "unusable state dir: source line added"

# --- secrecy and hygiene -----------------------------------------------------

new_case; FAKE_ERR="$M_ERR"
jq -n --arg v "$M_VALUE" '[{name:"S",value:$v}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Loaded 1 project variables" "secrecy"
[[ "$(mode "$state")" == 700 ]] || fail "state dir mode is $(mode "$state"), want 700"
[[ "$(mode "$exports")" == 600 ]] || fail "exports mode is $(mode "$exports"), want 600"
no_temp_files "success"
check_var "$envf" S "$M_VALUE"

echo 'PASS: cloud-op-env tests'
