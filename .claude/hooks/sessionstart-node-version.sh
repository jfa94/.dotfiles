#!/bin/bash
# SessionStart(startup|resume|clear|fork), cloud only. The image puts Node 22 on
# PATH and ignores .nvmrc; this installs the project's .nvmrc version with the
# image's nvm and prepends its bin directory to PATH for Bash via CLAUDE_ENV_FILE.
set -uo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.nvmrc" ] || exit 0

NVM_SH="${NVM_DIR:-/opt/nvm}/nvm.sh"
# Only for messages; nvm parses .nvmrc itself. Stripped to keep the JSON valid.
spec=$(head -n 1 "$CLAUDE_PROJECT_DIR/.nvmrc" 2>/dev/null | tr -cd 'A-Za-z0-9._/*-')
fail=""
version=""

activate() {
  [ -f "$NVM_SH" ] || { fail="nvm not found"; return 1; }
  { : >> "${CLAUDE_ENV_FILE:-}"; } 2>/dev/null || { fail="session env file not writable"; return 1; }

  # Child shell: nvm is not nounset-safe, needs --no-use next to an .nvmrc, and
  # prints progress to stdout, so only the final `nvm which` line is kept.
  local out rc bindir line
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
    fail="nvm returned no usable node"
    return 1
  fi

  line="export PATH=$(printf '%q' "$bindir"):\"\$PATH\""
  grep -qxF -- "$line" "$CLAUDE_ENV_FILE" 2>/dev/null && return 0
  { printf '%s\n' "$line" >> "$CLAUDE_ENV_FILE"; } 2>/dev/null || { fail="session env file not writable"; return 1; }
}

if activate; then
  msg="Using Node $version from .nvmrc."
else
  default=$(node -v 2>/dev/null | tr -cd 'A-Za-z0-9.') || true
  msg="Node from .nvmrc ($spec) could not be activated: $fail. Sessions use the image default Node ${default:-unknown}. Run the gate on the .nvmrc version before trusting results."
fi
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
exit 0
