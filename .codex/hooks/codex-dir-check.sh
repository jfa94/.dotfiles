#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CWD=$(project_dir "$INPUT")

while IFS= read -r fp; do
  [[ -z "$fp" ]] && continue
  printf '%s' "$fp" | grep -qE '(^|/)\.codex(/|$)' || continue

  case "$fp" in
    /*) ABS="$fp" ;;
    *) ABS="$CWD/$fp" ;;
  esac

  if [[ "$ABS" == "$CWD/.codex" || "$ABS" == "$CWD/.codex/"* ]]; then
    continue
  fi

  printf '%s' "$fp" | grep -qE '(^|/)\.codex/(logs?|cache|shell_snapshots|\.tmp|skills/\.system)(/|$)' && continue
  deny "Accessing .codex-managed config requires explicit user confirmation. Retry only after the user confirms this exact Codex config change."
  exit 0
done < <(extract_paths "$INPUT")
