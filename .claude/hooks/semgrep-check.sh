#!/bin/bash
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
# Match git push at start or after a chain operator — `git commit && git push`
# skipped a ^-anchored trigger entirely.
printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push' || exit 0

# --- Graceful degradation: skip if semgrep not installed ---
# NOTE: --config auto requires network access on first use to fetch rules.
if ! command -v semgrep >/dev/null 2>&1; then
  echo "semgrep not found; skipping SAST scan" >&2
  exit 0
fi

# Honor git -C <dir>: scan the repo being pushed, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
cd "${DIR:-${CLAUDE_PROJECT_DIR:-.}}" || exit 0

# --- Detect default branch ---
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
[ -n "$DEFAULT" ] || DEFAULT="main"

# --- Compute changed files vs default branch ---
CHANGED=$(git diff --name-only "origin/${DEFAULT}...HEAD" 2>/dev/null || true)
if [ -z "$CHANGED" ]; then
  exit 0
fi

# --- Caching: skip scan if we already have results for this HEAD ---
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
if [[ -z "$HEAD_SHA" ]]; then
  # No HEAD — can't cache; proceed with fresh scan
  CACHE_FILE=""
else
  CACHE_FILE="/tmp/semgrep-cache-${HEAD_SHA}.json"
  # Clean up stale cache files (any that don't match current HEAD)
  find /tmp -maxdepth 1 -name 'semgrep-cache-*.json' ! -name "semgrep-cache-${HEAD_SHA}.json" -delete 2>/dev/null || true
fi

if [[ -n "$CACHE_FILE" ]] && [ -f "$CACHE_FILE" ]; then
  SEMGREP_OUT=$(cat "$CACHE_FILE")
else
  # Run semgrep on changed files only; use array to handle paths with spaces.
  # Pre-filter against .semgrepignore: when semgrep receives explicit file paths
  # it bypasses .semgrepignore, so we enforce it here manually.
  exclude_patterns=()
  if [[ -f .semgrepignore ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      exclude_patterns+=("${line%/}")  # strip trailing slash for prefix matching
    done < .semgrepignore
  fi
  args=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    skip=false
    for pat in "${exclude_patterns[@]+"${exclude_patterns[@]}"}"; do
      if [[ "$f" == "$pat" || "$f" == "$pat/"* ]]; then
        skip=true; break
      fi
    done
    $skip || args+=("$f")
  done <<< "$CHANGED"
  [[ ${#args[@]} -eq 0 ]] && exit 0
  SEMGREP_OUT=$(semgrep --config auto --error --severity ERROR --severity WARNING --json "${args[@]}" 2>/dev/null || true)
  # Only cache if output is valid JSON with a .results key
  if [[ -n "$CACHE_FILE" ]] && printf '%s' "$SEMGREP_OUT" | jq -e '.results' >/dev/null 2>&1; then
    printf '%s' "$SEMGREP_OUT" > "$CACHE_FILE"
  fi
fi

# --- Detect scan failure (don't let an errored scan look like a clean one) ---
if ! printf '%s' "$SEMGREP_OUT" | jq -e '.results' >/dev/null 2>&1; then
  echo "semgrep returned no valid results — scan error or no network for --config auto; SAST scan incomplete, not blocking" >&2
  exit 0
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
