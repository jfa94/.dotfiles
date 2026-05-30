#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -n "$CMD" ]] || exit 0

printf '%s' "$CMD" | grep -qE '^[[:space:]]*gh([[:space:]]+(-R|--repo)[[:space:]]+[^[:space:]]+)*[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$)' || exit 0

if printf '%s' "$CMD" | grep -qE 'pr[[:space:]]+create' && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])--draft([[:space:]]|$)'; then
  exit 0
fi

CWD=$(project_dir "$INPUT")
[[ -f "$CWD/package.json" ]] || exit 0
cd "$CWD" || exit 0

grep -qE '"@stryker-mutator/core"' package.json || exit 0

BASE_REF=$(printf '%s' "$CMD" | grep -oE '(--base[= ]|-B )[^ ]+' | head -1 | sed 's/^--base[= ]//;s/^-B //')
if [[ -z "$BASE_REF" ]]; then
  BASE_REF=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
fi
BASE_REF="${BASE_REF:-main}"

git fetch origin "$BASE_REF" --depth=50 2>/dev/null || {
  echo "pre-pr: failed to fetch origin/$BASE_REF; skipping mutation gate" >&2
  exit 0
}

SCOPE=$(git diff --name-only --diff-filter=AM "origin/${BASE_REF}...HEAD" -- ':(glob)src/**/*.ts' |
  grep -Ev '\.(test|spec|d)\.ts$|/types/|/data/|/index\.ts$' ||
  true)
[[ -n "$SCOPE" ]] || exit 0

SCOPE_CSV=$(printf '%s' "$SCOPE" | tr '\n' ',' | sed 's/,$//')
if ! { pnpm exec stryker run --mutate "$SCOPE_CSV" 2>&1; } | tail -40; then
  deny "Mutation gate failed on: $(printf '%s' "$SCOPE" | tr '\n' ' ')"
fi
