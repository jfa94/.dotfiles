#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CWD=$(project_dir "$INPUT")

while IFS= read -r fp; do
  [[ -z "$fp" ]] && continue
  # .env only as a basename prefix (not foo.env.ts), with committed-safe
  # example/sample/template variants exempt.
  if printf '%s' "$fp" | grep -qE '(^|/)\.env[^/]*$|(^|/)secrets(/|$)|\.(pem|key|p12|pfx)$|(^|/)id_rsa$|(^|/)id_ed25519$' \
    && ! printf '%s' "$fp" | grep -qE '\.env\.(example|sample|template)$'; then
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
    # Resolve the real default branch — hardcoding main misses master/develop repos.
    DEFAULT=$(git -C "$ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||' || true)
    DEFAULT="${DEFAULT:-main}"
    if git -C "$ROOT" cat-file -e "${DEFAULT}:${rel}" 2>/dev/null; then
      deny "Applied migration exists on ${DEFAULT}. Retry only after explicit user confirmation to edit this migration."
      exit 0
    fi
  fi
done < <(extract_paths "$INPUT")
