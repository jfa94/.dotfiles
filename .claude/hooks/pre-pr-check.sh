#!/bin/bash
# pre-pr-check.sh — incremental Stryker mutation gate for gh pr create (non-draft) and gh pr ready
# Unhandled: GH_HOST= prefix, gh alias indirection, compound "cd X && gh pr create"
# (blocked by compound-check.sh), non-standard layouts (app/, lib/, packages/*/src) — empty scope skips cleanly.
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# Match: gh [-R owner/repo] pr create|ready
printf '%s' "$CMD" | grep -qE '^[[:space:]]*gh([[:space:]]+(-R|--repo)[[:space:]]+[^[:space:]]+)*[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$)' || exit 0

# Drafts are not merge-ready; mutation fires on gh pr ready instead
if printf '%s' "$CMD" | grep -qE 'pr[[:space:]]+create' && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])--draft([[:space:]]|$)'; then
  exit 0
fi

[ -f "${CLAUDE_PROJECT_DIR:-.}/package.json" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

grep -qE '"@stryker-mutator/core"' package.json || exit 0

# Resolve base ref: --base X | --base=X | -B X -> gh repo view -> main
BASE_REF=$(printf '%s' "$CMD" | grep -oE '(--base[= ]|-B )[^ ]+' | head -1 | sed 's/^--base[= ]//;s/^-B //')
if [ -z "$BASE_REF" ]; then
  BASE_REF=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
fi
BASE_REF="${BASE_REF:-main}"

git fetch origin "$BASE_REF" --depth=50 2>/dev/null \
  || { echo "pre-pr: failed to fetch origin/$BASE_REF; skipping mutation gate" >&2; exit 0; }

# Incremental scope (mirrors factory CI quality-gate.yml)
SCOPE=$(git diff --name-only --diff-filter=AM "origin/${BASE_REF}...HEAD" -- ':(glob)src/**/*.ts' \
  | grep -Ev '\.(test|spec|d)\.ts$|/types/|/data/|/index\.ts$' || true)
[ -z "$SCOPE" ] && exit 0

SCOPE_CSV=$(printf '%s' "$SCOPE" | tr '\n' ',' | sed 's/,$//')

if ! { pnpm exec stryker run --mutate "$SCOPE_CSV" 2>&1; } | tail -40; then
  jq -cn --arg r "Mutation gate failed on: $(printf '%s' "$SCOPE" | tr '\n' ' ')" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
fi
