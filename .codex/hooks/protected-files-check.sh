#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CWD=$(project_dir "$INPUT")

while IFS= read -r fp; do
  [[ -z "$fp" ]] && continue
  if printf '%s' "$fp" | grep -qE '(^|/)\.env($|\.|/)|(^|/)secrets(/|$)|\.(pem|key|p12|pfx)$|(^|/)id_rsa$|(^|/)id_ed25519$'; then
    deny "Protected file blocked. Retry only after explicit user confirmation for this exact file."
    exit 0
  fi

  if printf '%s' "$fp" | grep -qE '/migrations/'; then
    ROOT=$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null) || continue
    [[ -z "$ROOT" ]] && continue
    case "$fp" in
      /*) abs="$fp" ;;
      *) abs="$CWD/$fp" ;;
    esac
    rel="${abs#"$ROOT"/}"
    if git -C "$ROOT" cat-file -e "main:$rel" 2>/dev/null; then
      deny "Applied migration exists on main. Retry only after explicit user confirmation to edit this migration."
      exit 0
    fi
  fi
done < <(extract_paths "$INPUT")
