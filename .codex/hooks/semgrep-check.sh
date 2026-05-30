#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
printf '%s' "$CMD" | grep -qE '^[[:space:]]*git( -C [^ ]+)? push([[:space:]]|$)' || exit 0

if ! command -v semgrep >/dev/null 2>&1; then
  echo "semgrep not found; skipping SAST scan" >&2
  exit 0
fi

CWD=$(project_dir "$INPUT")
cd "$CWD" || exit 0

DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
[[ -n "$DEFAULT" ]] || DEFAULT="main"

CHANGED=$(git diff --name-only "origin/${DEFAULT}...HEAD" 2>/dev/null || true)
[[ -n "$CHANGED" ]] || exit 0

HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
CACHE_FILE=""
if [[ -n "$HEAD_SHA" ]]; then
  CACHE_FILE="/tmp/semgrep-cache-${HEAD_SHA}.json"
  find /tmp -maxdepth 1 -name 'semgrep-cache-*.json' ! -name "semgrep-cache-${HEAD_SHA}.json" -delete 2>/dev/null || true
fi

if [[ -n "$CACHE_FILE" && -f "$CACHE_FILE" ]]; then
  SEMGREP_OUT=$(cat "$CACHE_FILE")
else
  args=()
  while IFS= read -r f; do [[ -n "$f" ]] && args+=("$f"); done <<< "$CHANGED"
  SEMGREP_OUT=$(semgrep --config auto --error --severity ERROR --severity WARNING --json "${args[@]}" 2>/dev/null || true)
  if [[ -n "$CACHE_FILE" ]] && printf '%s' "$SEMGREP_OUT" | jq -e '.results' >/dev/null 2>&1; then
    printf '%s' "$SEMGREP_OUT" > "$CACHE_FILE"
  fi
fi

if ! printf '%s' "$SEMGREP_OUT" | jq -e '.results' >/dev/null 2>&1; then
  echo "semgrep returned no valid results; SAST scan incomplete, not blocking" >&2
  exit 0
fi

FINDING_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '.results | length' 2>/dev/null || echo 0)
if [[ -z "$FINDING_COUNT" || "$FINDING_COUNT" -eq 0 ]]; then
  exit 0
fi

FILE_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '[.results[].path] | unique | length' 2>/dev/null || echo "?")
deny "Semgrep found ${FINDING_COUNT} finding(s) in ${FILE_COUNT} file(s). Fix before pushing."
