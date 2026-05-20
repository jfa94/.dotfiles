#!/bin/bash
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
printf '%s' "$CMD" | grep -qE '^git ((-C [^ ]+ )?push)' || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# --- Graceful degradation: skip if semgrep not installed ---
if ! command -v semgrep >/dev/null 2>&1; then
  echo "semgrep not found; skipping SAST scan" >&2
  exit 0
fi

# --- Detect default branch ---
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
[ -n "$DEFAULT" ] || DEFAULT="main"

# --- Compute changed files vs default branch ---
CHANGED=$(git diff --name-only "origin/${DEFAULT}...HEAD" 2>/dev/null || true)
if [ -z "$CHANGED" ]; then
  exit 0
fi

# --- Caching: skip scan if we already have results for this HEAD ---
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
CACHE_FILE="/tmp/semgrep-cache-${HEAD_SHA}.json"

# Clean up stale cache files (any that don't match current HEAD)
find /tmp -maxdepth 1 -name 'semgrep-cache-*.json' ! -name "semgrep-cache-${HEAD_SHA}.json" -delete 2>/dev/null || true

if [ -f "$CACHE_FILE" ]; then
  SEMGREP_OUT=$(cat "$CACHE_FILE")
else
  # Run semgrep on changed files only
  # shellcheck disable=SC2086
  SEMGREP_OUT=$(printf '%s\n' "$CHANGED" | xargs semgrep --config auto --error \
    --severity ERROR --severity WARNING --json 2>/dev/null || true)
  printf '%s' "$SEMGREP_OUT" > "$CACHE_FILE"
fi

# --- Parse findings ---
FINDING_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '.results | length' 2>/dev/null || echo 0)
if [ -z "$FINDING_COUNT" ] || [ "$FINDING_COUNT" -eq 0 ]; then
  exit 0
fi

FILE_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '[.results[].path] | unique | length' 2>/dev/null || echo "?")

jq -cn --arg r "Semgrep found ${FINDING_COUNT} finding(s) in ${FILE_COUNT} file(s). Fix before pushing." \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
exit 0
