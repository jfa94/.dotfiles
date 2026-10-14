#!/usr/bin/env bash
# Tests for sessionstart-node-version.sh: gating, PATH delivery, idempotency and
# failure warnings. A fake nvm.sh and timeout stand in for nvm; no network needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/sessionstart-node-version.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

bash -n "$HOOK" || fail "bash -n"
if command -v shellcheck &>/dev/null; then
  shellcheck "$HOOK" || fail "shellcheck"
fi

jq -e '[.hooks.SessionStart[]
        | select(.matcher == "startup|resume|clear|fork")
        | .hooks[]
        | select((.command | endswith("/sessionstart-node-version.sh")) and .timeout > 90)]
       | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
  || fail "hook not registered with matcher startup|resume|clear|fork and timeout > 90"

# Fake timeout returns 124 on request, else runs the command.
bin="$tmp/bin"
mkdir -p "$bin"
cat > "$bin/timeout" <<'EOF'
#!/bin/bash
[ "${FAKE_TIMEOUT_EXPIRE:-}" != 1 ] || exit 124
shift
exec "$@"
EOF
chmod +x "$bin/timeout"

# Fake nvm: `install` creates a node printing v26.0.0 (or fails on request) and
# prints noise; `which current` prints the node path.
nvm_dir="$tmp/nvm"
mkdir -p "$nvm_dir"
cat > "$nvm_dir/nvm.sh" <<'EOF'
[ "${1:-}" = --no-use ] || return 3
nvm() {
  local d="$NVM_DIR/versions/node/v26.0.0/bin"
  case "$1" in
    install)
      echo "Downloading and installing node v26.0.0..."
      [ "${FAKE_INSTALL_FAIL:-}" != 1 ] || return 1
      mkdir -p "$d" && printf '#!/bin/sh\necho v26.0.0\n' > "$d/node" && chmod +x "$d/node" ;;
    which) echo "$d/node" ;;
  esac
}
EOF

n=0
new_case() {
  n=$((n + 1))
  cdir="$tmp/c$n"
  proj="$cdir/proj"
  envf="$cdir/env/hook-0.sh"
  mkdir -p "$proj" "${envf%/*}"
  echo 26 > "$proj/.nvmrc"
  : > "$envf"
  rm -rf "$nvm_dir/versions"
  REMOTE=true NVMDIR="$nvm_dir" FAKE_TIMEOUT_EXPIRE=0 FAKE_INSTALL_FAIL=0
}

run_hook() {
  local -a e=(PATH="$bin:$PATH" CLAUDE_PROJECT_DIR="$proj" CLAUDE_ENV_FILE="$envf" NVM_DIR="$NVMDIR"
    FAKE_TIMEOUT_EXPIRE="$FAKE_TIMEOUT_EXPIRE" FAKE_INSTALL_FAIL="$FAKE_INSTALL_FAIL")
  [[ -z "$REMOTE" ]] || e+=(CLAUDE_CODE_REMOTE="$REMOTE")
  rc=0
  env -i "${e[@]}" "$HOOK" >"$cdir/stdout" 2>"$cdir/stderr" || rc=$?
  [[ $rc -eq 0 ]] || fail "case $n: hook exited $rc"
  [[ ! -s "$cdir/stderr" ]] || fail "case $n: hook wrote to stderr"
}

msg() { jq -r '.hookSpecificOutput.additionalContext' "$cdir/stdout"; }
path_lines() { grep -c '^export PATH=' "$envf" || true; }

# Not remote: silent no-op.
new_case; REMOTE=""
run_hook
[[ ! -s "$cdir/stdout" && ! -s "$envf" ]] || fail "acted outside cloud"

# No .nvmrc: silent no-op.
new_case; rm "$proj/.nvmrc"
run_hook
[[ ! -s "$cdir/stdout" && ! -s "$envf" ]] || fail "acted without .nvmrc"

# Success: one PATH line that activates the installed node; idempotent on rerun.
new_case
run_hook
[[ "$(msg)" == "Using Node v26.0.0 from .nvmrc." ]] || fail "success message: $(msg)"
[[ "$(path_lines)" == 1 ]] || fail "expected one PATH line"
[[ "$(env -i PATH=/usr/bin:/bin bash -c ". '$envf'; node -v")" == v26.0.0 ]] || fail "PATH line does not activate node"
run_hook
[[ "$(path_lines)" == 1 ]] || fail "PATH line duplicated on rerun"

# Failures: warning naming the cause, no PATH line.
check_failure() {
  run_hook
  msg | grep -qF "Node from .nvmrc (26) could not be activated: $1." || fail "expected '$1' warning, got: $(msg)"
  [[ "$(path_lines)" == 0 ]] || fail "PATH line written on failure ($1)"
}
new_case; FAKE_INSTALL_FAIL=1; check_failure "nvm install failed"
new_case; FAKE_TIMEOUT_EXPIRE=1; check_failure "install timed out"
new_case; NVMDIR="$cdir/missing"; check_failure "nvm not found"

echo "cloud-node-version: all tests passed"
