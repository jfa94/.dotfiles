#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=hook-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
# Match git push at start or after a chain operator — `git commit && git push`
# skipped a ^-anchored trigger entirely.
# git invocation at a segment start, also inside ( ) / { } or behind a command wrapper.
GIT_RE='[[:space:]({]*((env|command|exec|nice|nohup|sudo|time|xargs)([[:space:]]+[^;&|]*)?[[:space:]]+)?git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?'
grep -qE "(^|;|&|\|)${GIT_RE}push" <<< "$CMD" || exit 0

if ! command -v semgrep >/dev/null 2>&1; then
  deny "Semgrep gate requires semgrep, but semgrep is unavailable."
  exit 0
fi

# Honor git -C <dir>: scan the repo being pushed, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
CWD=$(project_dir "$INPUT")
if ! cd "${DIR:-$CWD}"; then deny "Semgrep gate cannot enter target repository."; exit 0; fi

# Base: origin/HEAD target, then origin/main, then origin/master. With no base
# the whole tree is new, so scan every tracked file.
BASE=""
for ref in "$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/||')" origin/main origin/master; do
  if [[ -n "$ref" ]] && git rev-parse --verify --quiet "$ref" >/dev/null; then BASE=$ref; break; fi
done
if [[ -n "$BASE" ]]; then
  if ! CHANGED=$(git diff --diff-filter=ACMR --name-only "${BASE}...HEAD" 2>/dev/null); then
    deny "Semgrep gate could not diff against ${BASE}; refusing to treat an unscanned push as clean."
    exit 0
  fi
else
  CHANGED=$(git ls-files)
fi
[[ -n "$CHANGED" ]] || exit 0

HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
CACHE_FILE=""
if [[ -n "$HEAD_SHA" ]]; then
  CACHE_FILE="/tmp/semgrep-cache-v2-${HEAD_SHA}.json"
  find /tmp -maxdepth 1 -name 'semgrep-cache-*.json' ! -name "semgrep-cache-v2-${HEAD_SHA}.json" -delete 2>/dev/null || true
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
  SEMGREP_OUT=$(semgrep --config auto --severity ERROR --severity WARNING --json "${args[@]}" 2>/dev/null)
  SEMGREP_RC=$?
  if [[ "$SEMGREP_RC" -ne 0 ]]; then
    deny "Semgrep scan failed (exit ${SEMGREP_RC}); refusing to treat an incomplete scan as success."
    exit 0
  fi
  if [[ -n "$CACHE_FILE" ]] && printf '%s' "$SEMGREP_OUT" | jq -e '.results | arrays' >/dev/null 2>&1; then
    printf '%s' "$SEMGREP_OUT" > "$CACHE_FILE"
  fi
fi

if ! printf '%s' "$SEMGREP_OUT" | jq -e '.results | arrays' >/dev/null 2>&1; then
  deny "Semgrep returned invalid output; refusing to treat an incomplete scan as success."
  exit 0
fi

FINDING_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '.results | length' 2>/dev/null || echo 0)
if [[ -z "$FINDING_COUNT" || "$FINDING_COUNT" -eq 0 ]]; then
  exit 0
fi

FILE_COUNT=$(printf '%s' "$SEMGREP_OUT" | jq '[.results[].path] | unique | length' 2>/dev/null || echo "?")
deny "Semgrep found ${FINDING_COUNT} finding(s) in ${FILE_COUNT} file(s). Fix before pushing."
