#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -n "$CMD" ]] || exit 0

# Match: gh [-R owner/repo] pr create|ready — at start or after a chain operator
# (`git push && gh pr create` skipped a ^-anchored trigger).
printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*gh([[:space:]]+(-R|--repo)[[:space:]]+[^[:space:]]+)*[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$)' || exit 0

# Drafts are not merge-ready; mutation fires on gh pr ready instead
if printf '%s' "$CMD" | grep -qE 'pr[[:space:]]+create' && printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(--draft|-d)([[:space:]]|$)'; then
  exit 0
fi

CWD=$(project_dir "$INPUT")
[[ -f "$CWD/package.json" ]] || exit 0
if ! cd "$CWD"; then deny "Mutation gate cannot enter target repository: $CWD"; exit 0; fi

grep -qE '"@stryker-mutator/core"' package.json || exit 0
command -v pnpm >/dev/null 2>&1 || { deny "Mutation gate requires pnpm, but pnpm is unavailable."; exit 0; }

BASE_REF=$(printf '%s' "$CMD" | grep -oE '(--base[= ]|-B )[^ ]+' | head -1 | sed 's/^--base[= ]//;s/^-B //')
if [[ -z "$BASE_REF" ]]; then
  BASE_REF=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
fi
BASE_REF="${BASE_REF:-main}"

git fetch origin "$BASE_REF" --depth=50 2>/dev/null || {
  deny "Mutation gate could not fetch origin/$BASE_REF; refusing to skip required comparison."
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
