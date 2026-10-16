#!/usr/bin/env bash
# Tests for sessionstart-node-project.sh: gating, PATH delivery, idempotency,
# dependency install and failure warnings. Fake nvm.sh, timeout, node and pnpm on
# a sandboxed PATH; no network needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/sessionstart-node-project.sh"

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
        | select((.command | endswith("/sessionstart-node-project.sh")) and .timeout > 330)]
       | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
  || fail "hook not registered with matcher startup|resume|clear|fork and timeout > 330"

# Sandboxed PATH: system tools the hook and fakes need, so the host's real
# node/pnpm cannot leak in. Fake timeout returns 124 on request (1 = always,
# pnpm = only for pnpm), else runs the command. Default node prints v22.0.0.
bin="$tmp/bin"
mkdir -p "$bin"
for c in bash sh env head tr grep mkdir chmod cat; do
  ln -s "$(command -v "$c")" "$bin/$c"
done
cat > "$bin/timeout" <<'EOF'
#!/bin/bash
case "${FAKE_TIMEOUT_EXPIRE:-}" in 1) exit 124 ;; pnpm) [ "$2" != pnpm ] || exit 124 ;; esac
shift
exec "$@"
EOF
printf '#!/bin/sh\necho v22.0.0\n' > "$bin/node"
# Fake pnpm logs its args, cwd and the node it resolves; fails on request.
pnpm_bin="$tmp/pnpm-bin"
mkdir -p "$pnpm_bin"
cat > "$pnpm_bin/pnpm" <<'EOF'
#!/bin/bash
echo "$* | $PWD | $(node -v)" >> "$PNPM_LOG"
[ "${FAKE_PNPM_FAIL:-}" != 1 ]
EOF
chmod +x "$bin"/* "$pnpm_bin/pnpm"

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
  REMOTE=true NVMDIR="$nvm_dir" FAKE_TIMEOUT_EXPIRE=0 FAKE_INSTALL_FAIL=0 FAKE_PNPM_FAIL=0 PNPMBIN="$pnpm_bin"
  plog="$cdir/pnpm.log"
}

run_hook() {
  local -a e=(PATH="$bin:$PNPMBIN" CLAUDE_PROJECT_DIR="$proj" CLAUDE_ENV_FILE="$envf" NVM_DIR="$NVMDIR"
    FAKE_TIMEOUT_EXPIRE="$FAKE_TIMEOUT_EXPIRE" FAKE_INSTALL_FAIL="$FAKE_INSTALL_FAIL"
    FAKE_PNPM_FAIL="$FAKE_PNPM_FAIL" PNPM_LOG="$plog")
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

# Neither .nvmrc nor lockfile: silent no-op.
new_case; rm "$proj/.nvmrc"
run_hook
[[ ! -s "$cdir/stdout" && ! -s "$envf" ]] || fail "acted without .nvmrc or lockfile"

# Not remote with a lockfile: silent no-op, no install.
new_case; REMOTE=""; : > "$proj/pnpm-lock.yaml"
run_hook
[[ ! -s "$cdir/stdout" && ! -e "$plog" ]] || fail "installed outside cloud"

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

# Lockfile without .nvmrc: frozen install in the project with the default node.
new_case; rm "$proj/.nvmrc"; : > "$proj/pnpm-lock.yaml"
run_hook
[[ "$(msg)" == "Dependencies installed (pnpm install --frozen-lockfile)." ]] || fail "lockfile-only message: $(msg)"
[[ "$(cat "$plog")" == "install --frozen-lockfile | $proj | v22.0.0" ]] || fail "lockfile-only install: $(cat "$plog")"
[[ "$(path_lines)" == 0 ]] || fail "PATH line written without .nvmrc"

# .nvmrc plus lockfile: install runs under the activated node.
new_case; : > "$proj/pnpm-lock.yaml"
run_hook
[[ "$(msg)" == "Using Node v26.0.0 from .nvmrc. Dependencies installed (pnpm install --frozen-lockfile)." ]] \
  || fail "combined message: $(msg)"
[[ "$(cat "$plog")" == "install --frozen-lockfile | $proj | v26.0.0" ]] || fail "combined install: $(cat "$plog")"
[[ "$(path_lines)" == 1 ]] || fail "expected one PATH line with lockfile"

# Install failures: Node still activated, warning names the cause.
check_deps_failure() {
  run_hook
  msg | grep -qF "Using Node v26.0.0 from .nvmrc. Dependencies not installed: $1. Run pnpm install --frozen-lockfile" \
    || fail "expected '$1' deps warning, got: $(msg)"
  [[ "$(path_lines)" == 1 ]] || fail "PATH line missing on deps failure ($1)"
}
new_case; : > "$proj/pnpm-lock.yaml"; FAKE_PNPM_FAIL=1; check_deps_failure "pnpm install failed"
new_case; : > "$proj/pnpm-lock.yaml"; FAKE_TIMEOUT_EXPIRE=pnpm; check_deps_failure "pnpm install timed out"
new_case; : > "$proj/pnpm-lock.yaml"; PNPMBIN="$cdir/none"; check_deps_failure "pnpm not found"

# Activation fails with a lockfile: install skipped rather than run on the wrong node.
new_case; : > "$proj/pnpm-lock.yaml"; FAKE_INSTALL_FAIL=1
run_hook
msg | grep -qF "could not be activated: nvm install failed." || fail "activation warning missing: $(msg)"
msg | grep -qF "Dependencies not installed: skipped: Node from .nvmrc not active." || fail "skip warning missing: $(msg)"
[[ ! -e "$plog" ]] || fail "installed despite failed activation"

echo "cloud-node-project: all tests passed"
