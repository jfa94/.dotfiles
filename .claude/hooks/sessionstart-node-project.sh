#!/bin/bash
# SessionStart(startup|resume|clear|fork), cloud only. The image puts Node 22 on
# PATH and ignores .nvmrc; this installs the project's .nvmrc version with the
# image's nvm, prepends its bin directory to PATH for Bash via CLAUDE_ENV_FILE,
# then runs a frozen pnpm install. One script: hooks run in parallel.
set -uo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || exit 0
[ -f "$CLAUDE_PROJECT_DIR/.nvmrc" ] || [ -f "$CLAUDE_PROJECT_DIR/pnpm-lock.yaml" ] || exit 0

NVM_SH="${NVM_DIR:-/opt/nvm}/nvm.sh"
# Only for messages; nvm parses .nvmrc itself. Stripped to keep the JSON valid.
spec=$(head -n 1 "$CLAUDE_PROJECT_DIR/.nvmrc" 2>/dev/null | tr -cd 'A-Za-z0-9._/*-')
fail=""
version=""
bindir=""

activate() {
  [ -f "$NVM_SH" ] || { fail="nvm not found"; return 1; }
  { : >> "${CLAUDE_ENV_FILE:-}"; } 2>/dev/null || { fail="session env file not writable"; return 1; }

  # Child shell: nvm is not nounset-safe, needs --no-use next to an .nvmrc, and
  # prints progress to stdout, so only the final `nvm which` line is kept.
  local out rc line
  # shellcheck disable=SC2016  # expanded by the child shell
  out=$(cd "$CLAUDE_PROJECT_DIR" \
    && timeout 90 bash -c '. "$1" --no-use >/dev/null 2>&1 && nvm install >/dev/null 2>&1 && nvm which current' \
      _ "$NVM_SH" 2>/dev/null)
  rc=$?
  case $rc in
    0) ;;
    124) fail="install timed out"; return 1 ;;
    *) fail="nvm install failed"; return 1 ;;
  esac

  bindir="${out##*$'\n'}"
  bindir="${bindir%/*}"
  if [ -z "$bindir" ] || [ ! -x "$bindir/node" ] || ! version=$("$bindir/node" -v 2>/dev/null); then
    bindir=""
    fail="nvm returned no usable node"
    return 1
  fi

  line="export PATH=$(printf '%q' "$bindir"):\"\$PATH\""
  grep -qxF -- "$line" "$CLAUDE_ENV_FILE" 2>/dev/null && return 0
  { printf '%s\n' "$line" >> "$CLAUDE_ENV_FILE"; } 2>/dev/null || { fail="session env file not writable"; return 1; }
}

node_ok=1
msg=""
if [ -f "$CLAUDE_PROJECT_DIR/.nvmrc" ]; then
  if activate; then
    msg="Using Node $version from .nvmrc."
  else
    node_ok=0
    default=$(node -v 2>/dev/null | tr -cd 'A-Za-z0-9.') || true
    msg="Node from .nvmrc ($spec) could not be activated: $fail. Sessions use the image default Node ${default:-unknown}. Run the gate on the .nvmrc version before trusting results."
  fi
fi

if [ -f "$CLAUDE_PROJECT_DIR/pnpm-lock.yaml" ]; then
  deps=""
  if [ "$node_ok" = 0 ]; then
    deps="skipped: Node from .nvmrc not active"
  elif ! PATH="${bindir:+$bindir:}$PATH" command -v pnpm >/dev/null 2>&1; then
    deps="pnpm not found"
  else
    (cd "$CLAUDE_PROJECT_DIR" && PATH="${bindir:+$bindir:}$PATH" timeout 240 pnpm install --frozen-lockfile >/dev/null 2>&1)
    case $? in
      0) ;;
      124) deps="pnpm install timed out" ;;
      *) deps="pnpm install failed" ;;
    esac
  fi
  if [ -z "$deps" ]; then
    msg="${msg:+$msg }Dependencies installed (pnpm install --frozen-lockfile)."
  else
    msg="${msg:+$msg }Dependencies not installed: $deps. Run pnpm install --frozen-lockfile before running tests."
  fi
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
exit 0
