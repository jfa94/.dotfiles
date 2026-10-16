#!/bin/bash
# SessionStart(startup|resume|clear|fork), cloud only. Writes the project's
# 1Password Environment to a git-ignored, hook-owned $CLAUDE_PROJECT_DIR/.env.local
# (as the local desktop destination does); nothing is exported to the shell.
set -uo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || [ -n "${OP_ENVIRONMENT_ID:-}" ] || exit 0
umask 077

STATE_DIR="$HOME/.local/state/claude-op-env"
TARGET="${CLAUDE_PROJECT_DIR:-}/.env.local"
MARKER="# Managed by sessionstart-op-env.sh from 1Password; rewritten at session start."

# Prints the number of rejected entries, or "all" when the output is not an array.
# shellcheck disable=SC2016  # jq variables, not shell expansions
VALIDATE='
  def ok: type == "object" and (.name | type) == "string" and (.value | type) == "string"
    and (.name | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    and (.name | test("^(OP_|CLAUDE_)") | not)
    and (.name | IN("HOME", "PATH", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS") | not)
    # NUL, LF, CR, $ and quote: Next expands $ even in single quotes, so none round-trip.
    and (.value | explode | any(IN(0, 10, 13, 36, 39)) | not);
  if type != "array" then "all"
  else length - ([.[] | select(ok) | .name] | unique | length)
  end
'

fail=""
count=0
out=""
stage=""
trap '[ -z "$out" ] || rm -f "$out"; [ -z "$stage" ] || rm -f "$stage"' EXIT
trap 'exit 0' INT TERM HUP

refresh() {
  if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || [ -z "${OP_ENVIRONMENT_ID:-}" ]; then
    fail="1Password configuration incomplete: set both OP_SERVICE_ACCOUNT_TOKEN and OP_ENVIRONMENT_ID"
    return 1
  fi
  for tool in jq timeout node git; do
    command -v "$tool" >/dev/null 2>&1 || { fail="1Password dependency missing ($tool)"; return 1; }
  done
  self=$(readlink -f "$0" 2>/dev/null) || self=""
  fetcher="${self%/.claude/hooks/*}/cloud/op-env/fetch-variables.mjs"
  [ -f "$fetcher" ] || { fail="1Password dependency missing (fetcher)"; return 1; }
  [ -d "${fetcher%/*}/node_modules/@1password/sdk" ] || { fail="1Password dependency missing (SDK install)"; return 1; }
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || { fail="1Password: no project directory"; return 1; }
  git -C "$CLAUDE_PROJECT_DIR" check-ignore -q .env.local 2>/dev/null \
    || { fail="1Password: .env.local is not git-ignored; not written"; return 1; }
  if { [ -e "$TARGET" ] || [ -L "$TARGET" ]; } && ! managed; then
    fail="1Password: existing .env.local is not managed by this hook; left unchanged"
    return 1
  fi

  if ! { mkdir -p "$STATE_DIR" \
    && out=$(mktemp "$STATE_DIR/fetch.XXXXXX") \
    && stage=$(mktemp "$STATE_DIR/stage.XXXXXX"); } 2>/dev/null; then
    fail="1Password variables could not be published"
    return 1
  fi

  timeout 45 node "$fetcher" >"$out" 2>/dev/null
  case $? in
    0) ;;
    124) fail="1Password read timed out"; return 1 ;;
    *) fail="1Password read failed"; return 1 ;;
  esac

  bad=$(jq -r "$VALIDATE" "$out" 2>/dev/null) || bad=all
  case "$bad" in
    0) ;;
    '' | *[!0-9]*) fail="1Password data invalid"; return 1 ;;
    *) fail="1Password data invalid ($bad entries rejected)"; return 1 ;;
  esac

  if count=$(jq length "$out") \
    && { printf '%s\n' "$MARKER" && jq -r '.[] | "\(.name)=\u0027\(.value)\u0027"' "$out"; } >"$stage" \
    && mv -f "$stage" "$TARGET"; then
    rm -f "$STATE_DIR/exports.sh"
    return 0
  fi
  fail="1Password variables could not be published"
  return 1
}

# A regular file (not a symlink) whose first line is the marker.
managed() {
  [ -f "$TARGET" ] && [ ! -L "$TARGET" ] && IFS= read -r first <"$TARGET" && [ "$first" = "$MARKER" ]
}

refresh

if [ -z "$fail" ]; then
  msg="Wrote $count project variables from 1Password to .env.local (git-ignored). They are not exported to the shell: only tools that read .env.local see them. Never print or commit this file."
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && managed; then
  msg="$fail - using .env.local written earlier on this VM; it may be stale."
else
  msg="$fail - no project variables are loaded."
fi
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
exit 0
