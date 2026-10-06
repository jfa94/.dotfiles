#!/bin/bash
set -uo pipefail
PAYLOAD=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<< "$PAYLOAD")
# Match git push at start or after a chain operator — `git commit && git push`
# skipped a ^-anchored trigger entirely.
# git invocation at a segment start, also inside ( ) / { } or behind a command wrapper.
GIT_RE='[[:space:]({]*((env|command|exec|nice|nohup|sudo|time|xargs)([[:space:]]+[^;&|]*)?[[:space:]]+)?git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+'
grep -qE "(^|;|&|\|)${GIT_RE}push" <<< "$CMD" || exit 0

BASE=$(jq -r '.cwd // empty' <<< "$PAYLOAD")
BASE=${BASE:-${CLAUDE_PROJECT_DIR:-.}}
# Only main/develop pushes are gated. Any other result, or a missing library, gates.
if . "$(dirname "${BASH_SOURCE[0]}")/push-target.sh" 2>/dev/null; then
  [ "$(push_target_classify "$BASE" "$CMD")" = unprotected ] && exit 0
fi

# Honor git -C <dir>: gate the repo being pushed, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
case "$DIR" in
  '') TARGET=$BASE;;
  '~') TARGET=$HOME;;
  '~/'*) TARGET=$HOME/${DIR#\~/};;
  /*) TARGET=$DIR;;
  *) TARGET=$BASE/$DIR;;
esac
# The payload cwd may be a subdirectory; gate from the repo root.
TOP=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null) && TARGET=$TOP
[ -f "$TARGET/package.json" ] || exit 0
cd "$TARGET" || exit 0
command -v pnpm >/dev/null 2>&1 || { echo "pnpm not found; skipping pre-push quality gate" >&2; exit 0; }

# Tails go to stderr and, for failing steps, into the deny reason: the agent never sees stderr.
FAILED=""
step() {
  local n=$1 out rc=0
  shift
  out=$("$@" 2>&1) || rc=$?
  out=$(printf '%s\n' "$out" | tail -n "$n")
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || FAILED="${FAILED}"$'\n'"\$ $*"$'\n'"${out}"
}

if grep -q '"quality"' package.json; then
  step 30 pnpm quality
else
  grep -q '"typecheck"' package.json && step 10 pnpm typecheck
  grep -q '"lint"' package.json && step 10 pnpm lint
  grep -q '"test"' package.json && step 20 pnpm test
  grep -q '"deps:validate"' package.json && step 10 pnpm deps:validate
fi

if [ -n "$FAILED" ]; then
  jq -cn --arg r "Pre-push quality gate failed. Fix issues before pushing.${FAILED}" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
fi
