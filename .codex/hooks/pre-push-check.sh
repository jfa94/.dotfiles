#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=hook-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
# Match git push at start or after a chain operator — `git commit && git push`
# skipped a ^-anchored trigger entirely.
# git invocation at a segment start, also inside ( ) / { } or behind a command wrapper.
GIT_RE='[[:space:]({]*((env|command|exec|nice|nohup|sudo|time|xargs)([[:space:]]+[^;&|]*)?[[:space:]]+)?git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+'
grep -qE "(^|;|&|\|)${GIT_RE}push" <<< "$CMD" || exit 0
# Honor git -C <dir>: gate the repo being pushed, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
CWD=$(project_dir "$INPUT")
TARGET="${DIR:-$CWD}"
[[ -f "$TARGET/package.json" ]] || exit 0
if ! cd "$TARGET"; then deny "Pre-push gate cannot enter target repository: $TARGET"; exit 0; fi
command -v pnpm >/dev/null 2>&1 || { deny "Pre-push quality gate requires pnpm, but pnpm is unavailable."; exit 0; }

QUAL=0
if grep -q '"quality"' package.json; then
  { pnpm quality 2>&1; } | tail -30 >&2 || QUAL=1
else
  TC=0
  if grep -q '"typecheck"' package.json; then
    { pnpm typecheck 2>&1; } | tail -10 >&2 || TC=1
  fi
  LN=0
  if grep -q '"lint"' package.json; then
    { pnpm lint 2>&1; } | tail -10 >&2 || LN=1
  fi
  TS=0
  if grep -q '"test"' package.json; then
    { pnpm test 2>&1; } | tail -20 >&2 || TS=1
  fi
  DV=0
  if grep -q '"deps:validate"' package.json; then
    { pnpm deps:validate 2>&1; } | tail -10 >&2 || DV=1
  fi
  QUAL=$((TC + LN + TS + DV))
fi

if [[ "$QUAL" -ne 0 ]]; then
  deny "Pre-push quality gate failed. Fix issues before pushing."
fi
