#!/bin/bash
# SessionStart(startup|resume|clear|fork), cloud only. Loads the project's
# 1Password Environment into Bash through one per-VM exports file; CLAUDE_ENV_FILE
# only gets a fixed line that sources it, so hook ordering cannot matter.
set -uo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || [ -n "${OP_ENVIRONMENT_ID:-}" ] || exit 0
umask 077

STATE_DIR="$HOME/.local/state/claude-op-env"
EXPORTS="$STATE_DIR/exports.sh"
EXPORTS_Q=$(printf '%q' "$EXPORTS")
SOURCE_LINE="[ -r $EXPORTS_Q ] && . $EXPORTS_Q || true"

# Prints the number of rejected entries, or "all" when the output is not an array.
# shellcheck disable=SC2016  # jq variables, not shell expansions
VALIDATE='
  def ok: type == "object" and (.name | type) == "string" and (.value | type) == "string"
    and (.name | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    and (.name | test("^(OP_|CLAUDE_)") | not)
    and (.name | IN("HOME", "PATH", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS") | not)
    and (.value | explode | any(. == 0) | not);
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
  for tool in jq timeout node; do
    command -v "$tool" >/dev/null 2>&1 || { fail="1Password dependency missing ($tool)"; return 1; }
  done
  self=$(readlink -f "$0" 2>/dev/null) || self=""
  fetcher="${self%/.claude/hooks/*}/cloud/op-env/fetch-variables.mjs"
  [ -f "$fetcher" ] || { fail="1Password dependency missing (fetcher)"; return 1; }
  [ -d "${fetcher%/*}/node_modules/@1password/sdk" ] || { fail="1Password dependency missing (SDK install)"; return 1; }
  { : >> "${CLAUDE_ENV_FILE:-}"; } 2>/dev/null || { fail="1Password dependency missing (session env file)"; return 1; }

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
    && jq -r '.[] | "export \(.name)=\(.value | @sh)"' "$out" >"$stage" \
    && mv -f "$stage" "$EXPORTS"; then
    return 0
  fi
  fail="1Password variables could not be published"
  return 1
}

# True once CLAUDE_ENV_FILE holds the source line and exports.sh exists.
deliver() {
  [ -f "$EXPORTS" ] && [ -n "${CLAUDE_ENV_FILE:-}" ] || return 1
  grep -qxF -- "$SOURCE_LINE" "$CLAUDE_ENV_FILE" 2>/dev/null && return 0
  { printf '%s\n' "$SOURCE_LINE" >> "$CLAUDE_ENV_FILE"; } 2>/dev/null
}

refresh
if deliver; then
  delivered=1
else
  delivered=0
  [ -n "$fail" ] || fail="1Password variables could not be added to the session"
fi

if [ -z "$fail" ]; then
  msg="Loaded $count project variables from 1Password."
elif [ "$delivered" = 1 ]; then
  msg="$fail - using values loaded earlier on this VM; they may be stale."
else
  msg="$fail - no project variables are loaded."
fi
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
exit 0
