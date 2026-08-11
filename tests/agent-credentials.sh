#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENV_DIR="$ROOT/.config/agent-env"
HELPER="$ENV_DIR/op-read-locked"
RUNNER="$ENV_DIR/agent-env-run"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'${3:+ ($3)}"
}

file="$ENV_DIR/personal.env"
[[ -f "$file" ]] || fail "missing $file"
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  case "$line" in
    *=op://*) ;;
    POSTHOG_CLI_HOST=https://eu.posthog.com) ;;
    *) fail "unsafe value in $file: ${line%%=*}" ;;
  esac
done < "$file"

for executable in "$HELPER" "$RUNNER"; do
  [[ -f "$executable" ]] || fail "missing $executable"
  [[ -x "$executable" ]] || fail "not executable: $executable"
  zsh -n "$executable"
done

grep -Fq 'readonly cache_ttl=43200' "$HELPER" || fail "cache TTL is not fixed at 12 hours"
grep -Fq 'zsystem flock -t 120' "$HELPER" || fail "helper does not use the bounded kernel lock"
grep -Fq '/usr/bin/security -q -i' "$HELPER" || fail "Keychain writes do not use security stdin mode"
if grep -Eq 'AGENT_ENV_CACHE_TTL|add-generic-password.* -[wp] ' "$HELPER"; then
  fail "helper exposes a TTL override or puts a password on security argv"
fi

for profile in outsidey almunia; do
  [[ ! -e "$ENV_DIR/$profile.env" ]] || fail "project credential profile remains in dotfiles: $profile"
done

# shellcheck disable=SC2016  # Assert literal deferred expansion in zshrc.
grep -Fqx 'export AGENT_ENV_FILE="${AGENT_ENV_FILE:-$HOME/.config/agent-env/personal.env}"' "$ROOT/.zshrc"
# shellcheck disable=SC2016
grep -Fqx '  codex() { "$HOME/.config/agent-env/agent-env-run" codex "$@"; }' "$ROOT/.zshrc"
# shellcheck disable=SC2016
grep -Fqx '  supabase() { "$HOME/.config/agent-env/agent-env-run" supabase "$@"; }' "$ROOT/.zshrc"
# shellcheck disable=SC2016
grep -Fqx '  posthog-cli() { "$HOME/.config/agent-env/agent-env-run" posthog-cli "$@"; }' "$ROOT/.zshrc"

grep -Fqx 'cask "1password-cli"' "$ROOT/Brewfile"
grep -Fqx 'brew "stripe-cli"' "$ROOT/Brewfile"
grep -q '^install_posthog_cli()' "$ROOT/setup.sh"
grep -q '^install_onepassword_cli()' "$ROOT/setup.sh"
grep -q '^install_stripe()' "$ROOT/setup.sh"
# shellcheck disable=SC2016  # Assert literal deferred expansion.
grep -Fq '"${XDG_CONFIG_HOME:-$HOME/.config}/op/plugins.sh"' "$ROOT/.zshrc"
if grep -Fq '/Users/Javier/.config/op/plugins.sh' "$ROOT/.zshrc"; then
  fail "machine-specific 1Password plugin path remains"
fi
if grep -Eq '^(stripe|posthog)@' "$ROOT/.codex/plugins.txt"; then
  fail "unscoped credential plugin remains in Codex manifest"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-credentials.XXXXXX")
cleanup() {
  if [[ -n "${keychain:-}" && -e "$keychain" ]]; then
    /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "${AGENT_TEST_UNAME:-Darwin}"
STUB
cat > "$tmp/bin/op" <<'STUB'
#!/bin/sh
if [ "$1" = run ]; then
  printf '%s\n' "$*" >> "${OP_RUN_LOG:?}"
  shift
  while [ "$1" != -- ]; do shift; done
  shift
  exec "$@"
fi
[ "$1" = read ] || exit 64
printf '%s\n' "$2" >> "${OP_COUNT_FILE:?}"
case "$2" in
  *Fail*) exit 23 ;;
  *Multi*) printf 'first line\nsecond line\n' ;;
  *Unicode*) printf 'caf\303\251\n' ;;
  *) printf 'value-%s\n' "${2##*/}" ;;
esac
STUB
cat > "$tmp/bin/capture" <<'STUB'
#!/bin/sh
printf 'A=%s\nB=%s\nC=%s\nLITERAL=%s\n' "${A-}" "${B-}" "${C-}" "${LITERAL-}"
printf 'argc=%s\n' "$#"
for arg do printf 'arg=<%s>\n' "$arg"; done
exit "${CAPTURE_EXIT:-0}"
STUB
chmod +x "$tmp/bin/uname" "$tmp/bin/op" "$tmp/bin/capture"

export PATH="$tmp/bin:$PATH"
export OP_COUNT_FILE="$tmp/op-count"
export OP_RUN_LOG="$tmp/op-run"
: > "$OP_COUNT_FILE"
: > "$OP_RUN_LOG"

# Linux/WSL keeps serialized direct reads and delegates the runner to op run.
output=$(AGENT_TEST_UNAME=Linux "$HELPER" 'op://Test/Linux/value')
assert_eq "$output" value-value "Linux helper fallback"
linux_env="$tmp/linux.env"
printf 'A=op://Test/Linux/value\n' > "$linux_env"
AGENT_TEST_UNAME=Linux AGENT_ENV_FILE="$linux_env" "$RUNNER" "$tmp/bin/capture" fallback >/dev/null
grep -Fq 'run --no-masking --env-file' "$OP_RUN_LOG" || fail "runner did not delegate to op run on Linux"

# Parser behavior that does not require Keychain access.
empty_output=$(AGENT_ENV_FILE=/dev/null "$RUNNER" "$tmp/bin/capture" 'two words' '*')
grep -Fqx 'argc=2' <<< "$empty_output" || fail "runner changed argument count"
grep -Fqx 'arg=<two words>' <<< "$empty_output" || fail "runner changed spaced argument"
grep -Fqx 'arg=<*>' <<< "$empty_output" || fail "runner expanded argument glob"

missing="$tmp/missing.env"
if AGENT_ENV_FILE="$missing" "$RUNNER" true 2>"$tmp/missing.err"; then
  fail "runner accepted a missing env file"
fi
grep -Fq 'missing or unreadable' "$tmp/missing.err" || fail "missing-file error was unclear"

for malformed in 'NOT_AN_ASSIGNMENT' 'BAD-NAME=value' ' export X=value'; do
  printf '%s\n' "$malformed" > "$tmp/malformed.env"
  if AGENT_ENV_FILE="$tmp/malformed.env" "$RUNNER" true 2>"$tmp/malformed.err"; then
    fail "runner accepted malformed env line: $malformed"
  fi
done

literal_env="$tmp/literal.env"
printf '# comment\n\nLITERAL=hello=world\n' > "$literal_env"
literal_output=$(AGENT_ENV_FILE="$literal_env" "$RUNNER" "$tmp/bin/capture")
grep -Fqx 'LITERAL=hello=world' <<< "$literal_output" || fail "runner changed a literal value"

set +e
AGENT_ENV_FILE=/dev/null CAPTURE_EXIT=37 "$RUNNER" "$tmp/bin/capture" >/dev/null
runner_status=$?
set -e
assert_eq "$runner_status" 37 "runner exit status"

if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
  keychain="$tmp/cache.keychain-db"
  keychain_password=test-password
  /usr/bin/security create-keychain -p "$keychain_password" "$keychain"
  /usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
  /usr/bin/security set-keychain-settings -lut 21600 "$keychain"
  export AGENT_ENV_CACHE_KEYCHAIN="$keychain"

  clear_cache() {
    "$HELPER" --clear
    : > "$OP_COUNT_FILE"
  }

  put_record() {
    local ref=$1 record=$2 hex
    hex=$(printf '%s' "$record" | od -An -tx1 | tr -d ' \n')
    printf 'add-generic-password -U -s "agent-env-cache" -a "%s" -X %s "%s"\n' "$ref" "$hex" "$keychain" \
      | /usr/bin/security -q -i >/dev/null
  }

  clear_cache
  ref='op://Test/Cache/value'
  first=$("$HELPER" "$ref" 2>"$tmp/miss.err")
  second=$("$HELPER" "$ref")
  assert_eq "$first" value-value "cold miss"
  assert_eq "$second" value-value "warm hit"
  assert_eq "$(wc -l < "$OP_COUNT_FILE" | tr -d ' ')" 1 "warm hit op count"
  [[ ! -s "$tmp/miss.err" ]] || fail "ordinary Keychain miss produced a warning"

  now=$(date +%s)
  for timestamp in "$((now - 43200))" "$((now + 60))" malformed; do
    put_record "$ref" "$timestamp"$'\t'cached-stale
    before=$(wc -l < "$OP_COUNT_FILE" | tr -d ' ')
    output=$("$HELPER" "$ref")
    after=$(wc -l < "$OP_COUNT_FILE" | tr -d ' ')
    assert_eq "$output" value-value "invalid timestamp fallback"
    assert_eq "$after" "$((before + 1))" "invalid timestamp op count"
  done

  if "$HELPER" 'op://Test/Fail/value' >/dev/null 2>"$tmp/op-fail.err"; then
    fail "helper swallowed op read failure"
  else
    status=$?
    assert_eq "$status" 23 "op read failure status"
  fi

  bad_keychain="$tmp/does-not-exist.keychain-db"
  output=$(AGENT_ENV_CACHE_KEYCHAIN="$bad_keychain" "$HELPER" 'op://Test/Write/value' 2>"$tmp/keychain-error.err")
  assert_eq "$output" value-value "Keychain failure fallback"
  grep -Fq 'Keychain read failed' "$tmp/keychain-error.err" || fail "Keychain operational read error was not warned"
  grep -Fq 'could not write' "$tmp/keychain-error.err" || fail "Keychain write failure was not warned"

  : > "$OP_RUN_LOG"
  AGENT_ENV_CACHE_KEYCHAIN="$bad_keychain" AGENT_ENV_FILE=/dev/null "$RUNNER" "$tmp/bin/capture" unavailable >/dev/null
  grep -Fq 'run --no-masking --env-file' "$OP_RUN_LOG" || fail "runner did not delegate when Keychain was unavailable"

  for suffix in Multi Unicode; do
    clear_cache
    ref="op://Test/$suffix/value"
    "$HELPER" "$ref" >/dev/null 2>"$tmp/uncacheable.err"
    "$HELPER" "$ref" >/dev/null 2>>"$tmp/uncacheable.err"
    assert_eq "$(wc -l < "$OP_COUNT_FILE" | tr -d ' ')" 2 "uncacheable $suffix op count"
    grep -Fq 'not safe to cache' "$tmp/uncacheable.err" || fail "uncacheable $suffix did not warn"
  done

  clear_cache
  unsafe_ref='op://Test/"Unsafe"/value'
  "$HELPER" "$unsafe_ref" >/dev/null 2>"$tmp/unsafe-ref.err"
  "$HELPER" "$unsafe_ref" >/dev/null 2>>"$tmp/unsafe-ref.err"
  assert_eq "$(wc -l < "$OP_COUNT_FILE" | tr -d ' ')" 2 "unsafe reference op count"
  grep -Fq 'not safe to cache' "$tmp/unsafe-ref.err" || fail "unsafe reference did not warn"

  clear_cache
  : > "$OP_COUNT_FILE"
  "$HELPER" 'op://Test/ClearOne/value' >/dev/null
  "$HELPER" 'op://Test/ClearTwo/value' >/dev/null
  "$HELPER" --clear
  "$HELPER" --clear
  for clear_ref in 'op://Test/ClearOne/value' 'op://Test/ClearTwo/value'; do
    set +e
    /usr/bin/security -q find-generic-password -s agent-env-cache -a "$clear_ref" -w "$keychain" >/dev/null 2>&1
    status=$?
    set -e
    assert_eq "$status" 44 "multi-item clear"
  done

  set +e
  AGENT_ENV_CACHE_KEYCHAIN="$bad_keychain" "$HELPER" --clear >"$tmp/clear-error.out" 2>"$tmp/clear-error.err"
  status=$?
  set -e
  (( status != 0 )) || fail "clear treated an unavailable Keychain as success"
  grep -Fq 'could not clear Keychain cache' "$tmp/clear-error.err" || fail "clear operational error was not surfaced"

  clear_cache
  "$HELPER" 'op://Test/Concurrent/value' >"$tmp/concurrent.1" &
  pid1=$!
  "$HELPER" 'op://Test/Concurrent/value' >"$tmp/concurrent.2" &
  pid2=$!
  wait "$pid1"
  wait "$pid2"
  assert_eq "$(wc -l < "$OP_COUNT_FILE" | tr -d ' ')" 1 "concurrent miss deduplication"
  assert_eq "$(<"$tmp/concurrent.1")" value-value "concurrent result one"
  assert_eq "$(<"$tmp/concurrent.2")" value-value "concurrent result two"

  clear_cache
  batch_env="$tmp/project.agent-env"
  cat > "$batch_env" <<'ENV'
# project-selected file
A=op://Test/First/value
B=op://Test/First/value
C=op://Test/Second/value
LITERAL=project=107700
STALE=op://Test/Stale/value
STALE=literal-wins
ENV
  unset A B C LITERAL || true
  batch_output=$(AGENT_ENV_FILE="$batch_env" "$RUNNER" "$tmp/bin/capture" 'arg one' '--literal=*')
  grep -Fqx 'A=value-value' <<< "$batch_output" || fail "first referenced value missing"
  grep -Fqx 'B=value-value' <<< "$batch_output" || fail "duplicate referenced value missing"
  grep -Fqx 'C=value-value' <<< "$batch_output" || fail "second referenced value missing"
  grep -Fqx 'LITERAL=project=107700' <<< "$batch_output" || fail "project literal missing"
  grep -Fqx 'arg=<arg one>' <<< "$batch_output" || fail "batch runner changed arguments"
  grep -Fqx 'arg=<--literal=*>' <<< "$batch_output" || fail "batch runner expanded an argument"
  assert_eq "$(wc -l < "$OP_COUNT_FILE" | tr -d ' ')" 2 "one op read per unique reference"
  [[ -z "${A+x}${B+x}${C+x}${LITERAL+x}" ]] || fail "resolved variables leaked into parent shell"
fi

echo "agent credential checks passed"
