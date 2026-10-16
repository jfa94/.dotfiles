#!/usr/bin/env bash
# Tests for sessionstart-op-env.sh and the fetcher: gating, dependencies, the
# written .env.local, guards, refresh semantics, failures, secrecy and hygiene. Fake node and
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

MARKER="# Managed by sessionstart-op-env.sh from 1Password; rewritten at session start."

bin="$tmp/bin"
realbin="$tmp/realbin"
mkdir -p "$bin" "$realbin"
for c in jq readlink mkdir mktemp grep mv rm cat git; do
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
  proj="$cdir/proj"
  target="$proj/.env.local"
  state="$home/.local/state/claude-op-env"
  envf="$cdir/session-env/s1/hook-0.sh"
  hook="$repo/.claude/hooks/sessionstart-op-env.sh"
  mkdir -p "$home" "$repo/.claude/hooks" "$repo/cloud/op-env/node_modules/@1password/sdk" "${envf%/*}"
  cp "$HOOK_SRC" "$hook"
  chmod +x "$hook"
  echo '// placeholder' > "$repo/cloud/op-env/fetch-variables.mjs"
  git init -q "$proj"
  echo '.env.local' > "$proj/.gitignore"
  REMOTE=true TOKEN="$M_TOKEN" ENVID=env-id HOOK_PATH="$bin:$realbin" PROJ="$proj"
  FAKE_OUT_FILE="$cdir/out.json" FAKE_ERR="" FAKE_STATUS=0 FAKE_TIMEOUT_EXPIRE=0
  : > "$FAKE_OUT_FILE"
}

# Runs the hook; asserts the invariants that hold for every run.
run_hook() {
  local -a e=(HOME="$home" PATH="$HOOK_PATH" CLAUDE_ENV_FILE="$envf" FAKE_OUT_FILE="$FAKE_OUT_FILE"
    FAKE_ERR="$FAKE_ERR" FAKE_STATUS="$FAKE_STATUS" FAKE_TIMEOUT_EXPIRE="$FAKE_TIMEOUT_EXPIRE"
    FAKE_TIMEOUT_LOG="$cdir/timeout.log")
  [[ -z "$REMOTE" ]] || e+=(CLAUDE_CODE_REMOTE="$REMOTE")
  [[ -z "$TOKEN" ]] || e+=(OP_SERVICE_ACCOUNT_TOKEN="$TOKEN")
  [[ -z "$ENVID" ]] || e+=(OP_ENVIRONMENT_ID="$ENVID")
  [[ -z "$PROJ" ]] || e+=(CLAUDE_PROJECT_DIR="$PROJ")
  rc=0
  env -i "${e[@]}" "$hook" >"$cdir/stdout" 2>"$cdir/stderr" || rc=$?
  [[ $rc -eq 0 ]] || fail "hook exited $rc"
  [[ ! -s "$cdir/stderr" ]] || fail "hook wrote to stderr"
  [[ ! -e "$envf" ]] || fail "hook wrote to CLAUDE_ENV_FILE"
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

# The target must be exactly the marker followed by lines $2...
assert_target() {
  local label="$1"; shift
  printf '%s\n' "$MARKER" "$@" > "$cdir/want"
  cmp -s "$cdir/want" "$target" || fail "$label: .env.local content mismatch"
}

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
no_temp_files() { [[ ! -d "$state" || -z "$(find "$state" -type f)" ]] || fail "$1: temp files left behind"; }

seed_managed() {
  printf '%s\n' "$MARKER" "OLD_VAR='old'" > "$target"
  cp "$target" "$cdir/target.before"
}

# --- gating ------------------------------------------------------------------

for remote in "" false; do
  new_case; REMOTE="$remote"
  run_hook
  assert_silent "remote='$remote'"
  [[ ! -e "$home/.local" ]] || fail "remote='$remote': state created outside cloud"
  [[ ! -e "$target" ]] || fail "remote='$remote': .env.local written outside cloud"
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
  [[ ! -e "$target" ]] || fail "only $only: .env.local created"
  seed_managed
  run_hook
  assert_msg "may be stale" "only $only, earlier values"
  cmp -s "$target" "$cdir/target.before" || fail "only $only: .env.local changed"
done

# --- dependencies ------------------------------------------------------------

for tool in jq timeout node git; do
  new_case; seed_managed; HOOK_PATH="$(path_without "$tool")"
  run_hook
  assert_msg "dependency missing ($tool)" "missing $tool"
  assert_msg "may be stale" "missing $tool"
  cmp -s "$target" "$cdir/target.before" || fail "missing $tool: .env.local changed"
done

new_case; seed_managed; rm "$repo/cloud/op-env/fetch-variables.mjs"
run_hook
assert_msg "dependency missing (fetcher)" "missing fetcher"
cmp -s "$target" "$cdir/target.before" || fail "missing fetcher: .env.local changed"

new_case; seed_managed; rmdir "$repo/cloud/op-env/node_modules/@1password/sdk"
run_hook
assert_msg "dependency missing (SDK install)" "missing SDK"
cmp -s "$target" "$cdir/target.before" || fail "missing SDK: .env.local changed"

# --- target guards -----------------------------------------------------------

new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"; PROJ=""
run_hook
assert_msg "no project directory" "no project dir"
assert_msg "no project variables are loaded" "no project dir"

new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"; rm "$proj/.gitignore"
run_hook
assert_msg ".env.local is not git-ignored; not written" "not ignored"
assert_msg "no project variables are loaded" "not ignored"
[[ ! -e "$target" ]] || fail "not ignored: .env.local created"
no_temp_files "not ignored"

new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"
PROJ="$cdir/plain"; mkdir -p "$PROJ"; echo '.env.local' > "$PROJ/.gitignore"
run_hook
assert_msg ".env.local is not git-ignored; not written" "not a git repo"
[[ ! -e "$PROJ/.env.local" ]] || fail "not a git repo: .env.local created"

new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"
echo 'MINE=1' > "$target"; cp "$target" "$cdir/target.before"
run_hook
assert_msg "existing .env.local is not managed by this hook; left unchanged" "unmanaged file"
assert_msg "no project variables are loaded" "unmanaged file"
cmp -s "$target" "$cdir/target.before" || fail "unmanaged file: changed"
no_temp_files "unmanaged file"

# A symlink is unmanaged even when the file it points at starts with the marker.
new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"
printf '%s\n' "$MARKER" "MINE=1" > "$cdir/elsewhere"; cp "$cdir/elsewhere" "$cdir/elsewhere.before"
ln -s "$cdir/elsewhere" "$target"
run_hook
assert_msg "not managed by this hook" "symlink"
assert_msg "no project variables are loaded" "symlink"
[[ -L "$target" ]] || fail "symlink: replaced"
cmp -s "$cdir/elsewhere" "$cdir/elsewhere.before" || fail "symlink: target file changed"

# --- values ------------------------------------------------------------------

new_case
# shellcheck disable=SC2016  # literal backticks are the fixture
jq -n --arg a '' --arg b 'masked-1' --arg f 'say "hi"' --arg g 'a\b' --arg h 'run `uname` # not a comment' \
  --arg i 'a=b=c' --arg j 'héllo ✓' --arg k '  padded  ' \
  '[{name:"G2_EMPTY",value:$a},{name:"G2_MASKED",value:$b},{name:"G2_DQUOTE",value:$f},
    {name:"G2_BACKSLASH",value:$g},{name:"G2_TICKS",value:$h},{name:"G2_EQUALS",value:$i},
    {name:"G2_UNICODE",value:$j},{name:"G2_SPACES",value:$k}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Wrote 8 project variables from 1Password to .env.local" "edge values"
assert_msg "not exported to the shell" "edge values"
# shellcheck disable=SC2016  # literal backticks are the fixture
assert_target "edge values" "G2_EMPTY=''" "G2_MASKED='masked-1'" "G2_DQUOTE='say \"hi\"'" \
  "G2_BACKSLASH='a\\b'" 'G2_TICKS='"'"'run `uname` # not a comment'"'" "G2_EQUALS='a=b=c'" \
  "G2_UNICODE='héllo ✓'" "G2_SPACES='  padded  '"
[[ "$(cat "$cdir/timeout.log")" == 45 ]] || fail "read timeout is not 45 s"

# --- refresh -----------------------------------------------------------------

new_case
printf '[{"name":"A","value":"1"},{"name":"B","value":"2"}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Wrote 2 project variables" "first refresh"
assert_target "first refresh" "A='1'" "B='2'"
printf '[{"name":"A","value":"9"}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Wrote 1 project variables" "second refresh"
assert_target "second refresh" "A='9'"
printf '[]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Wrote 0 project variables" "empty environment"
assert_target "empty environment"

# --- failures ----------------------------------------------------------------

# expect_failure LABEL EXPECTED_TEXT: stale when a managed file exists, none otherwise.
expect_failure() {
  local label="$1" text="$2"
  seed_managed
  run_hook
  assert_msg "$text" "$label"
  assert_msg "may be stale" "$label"
  cmp -s "$target" "$cdir/target.before" || fail "$label: .env.local changed"
  no_temp_files "$label"
  rm -f "$target"; rm -rf "$state"
  run_hook
  assert_msg "$text" "$label (fresh VM)"
  assert_msg "no project variables are loaded" "$label (fresh VM)"
  [[ ! -e "$target" ]] || fail "$label: .env.local created despite failure"
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

new_case; printf '[{"name":"A","value":5},{"name":"B","value":"1"},{"name":"B","value":"2"}]' > "$FAKE_OUT_FILE"
expect_failure "invalid plus duplicate" "1Password data invalid (2 entries rejected)"

for name in OP_TOKEN OP_ANYTHING CLAUDE_CODE_X HOME PATH BASH_ENV ENV SHELLOPTS BASHOPTS; do
  new_case; jq -n --arg n "$name" '[{name:$n,value:"1"}]' > "$FAKE_OUT_FILE"
  expect_failure "reserved name $name" "1Password data invalid (1 entries rejected)"
done

new_case; printf '[{"name":"A","value":"a\\u0000b"}]' > "$FAKE_OUT_FILE"
expect_failure "NUL in value" "1Password data invalid (1 entries rejected)"

# Values neither Next's loader nor ads-gaql.py can read back; the whole load fails.
for v in "it's" 'a$b' $'a\nb' $'a\rb'; do
  new_case; jq -n --arg v "$M_VALUE$v" '[{name:"A",value:"ok"},{name:"B",value:$v}]' > "$FAKE_OUT_FILE"
  expect_failure "unrepresentable value $(printf '%q' "$v")" "1Password data invalid (1 entries rejected)"
done

# An unusable state directory fails to publish and writes nothing.
new_case; printf '[{"name":"A","value":"1"}]' > "$FAKE_OUT_FILE"
mkdir -p "$home/.local/state"; echo file > "$state"
run_hook
assert_msg "1Password variables could not be published" "unusable state dir"
assert_msg "no project variables are loaded" "unusable state dir"
[[ ! -e "$target" ]] || fail "unusable state dir: .env.local created"

# --- secrecy and hygiene -----------------------------------------------------

new_case; FAKE_ERR="$M_ERR"
mkdir -p "$state"; chmod 700 "$state"; echo "export OLD='1'" > "$state/exports.sh"
jq -n --arg v "$M_VALUE" '[{name:"S",value:$v}]' > "$FAKE_OUT_FILE"
run_hook
assert_msg "Wrote 1 project variables" "secrecy"
[[ "$(mode "$state")" == 700 ]] || fail "state dir mode is $(mode "$state"), want 700"
[[ "$(mode "$target")" == 600 ]] || fail ".env.local mode is $(mode "$target"), want 600"
[[ ! -e "$state/exports.sh" ]] || fail "leftover exports.sh not removed"
no_temp_files "success"
assert_target "secrecy" "S='$M_VALUE'"

echo 'PASS: cloud-op-env tests'
