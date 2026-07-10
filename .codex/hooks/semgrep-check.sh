#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
# Match git push at start or after a chain operator — `git commit && git push`
# skipped a ^-anchored trigger entirely.
printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push' || exit 0

if ! command -v semgrep >/dev/null 2>&1; then
  deny "Semgrep gate requires semgrep, but semgrep is unavailable."
  exit 0
fi

# Honor git -C <dir>: scan the repo being pushed, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
CWD=$(project_dir "$INPUT")
if ! cd "${DIR:-$CWD}"; then deny "Semgrep gate cannot enter target repository."; exit 0; fi

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
  if ! SEMGREP_OUT=$(semgrep --config auto --error --severity ERROR --severity WARNING --json "${args[@]}" 2>/dev/null); then
    deny "Semgrep scan failed; refusing to treat an incomplete scan as success."
    exit 0
  fi
  if [[ -n "$CACHE_FILE" ]] && printf '%s' "$SEMGREP_OUT" | jq -e '.results' >/dev/null 2>&1; then
    printf '%s' "$SEMGREP_OUT" > "$CACHE_FILE"
  fi
fi

if ! printf '%s' "$SEMGREP_OUT" | jq -e '.results' >/dev/null 2>&1; then
  deny "Semgrep returned invalid output; refusing to treat an incomplete scan as success."
  exit 0
fi

FINDING_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '.results | length' 2>/dev/null || echo 0)
if [[ -z "$FINDING_COUNT" || "$FINDING_COUNT" -eq 0 ]]; then
  exit 0
fi

FILE_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '[.results[].path] | unique | length' 2>/dev/null || echo "?")
deny "Semgrep found ${FINDING_COUNT} finding(s) in ${FILE_COUNT} file(s). Fix before pushing."
