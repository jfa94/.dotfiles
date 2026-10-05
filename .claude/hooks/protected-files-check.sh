#!/bin/bash
set -euo pipefail
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty')
[ -z "$FP" ] && exit 0

emit() {
  jq -cn --arg d "$1" --arg r "$2" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":$d,"permissionDecisionReason":$r}}'
}

# Kept identical to the SECRET_PATH_RE/SECRET_EXEMPT_RE in dangerous-patterns-check.sh
# and both pre-commit-check.sh (drift-checked by tests/codex-permissions-aws-mcp.sh).
SECRET_PATH_RE='(^|/)\.env[^/]*($|/)|(^|/)secrets(/|$)|\.(pem|key|p12|pfx)$|(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa)$'
SECRET_EXEMPT_RE='\.env\.(example|sample|template)$'
CREDENTIALS_RE='(^|/)(credentials|\.git-credentials|credentials\.json)$'

if { printf '%s' "$FP" | grep -qiE "$SECRET_PATH_RE" || printf '%s' "$FP" | grep -qE "$CREDENTIALS_RE"; } \
  && ! printf '%s' "$FP" | grep -qiE "$SECRET_EXEMPT_RE"; then
  emit deny 'Protected file: requires human review.'
  exit 0
fi

if printf '%s' "$FP" | grep -qE '/migrations/'; then
  # Resolve the file's own repo from its nearest existing ancestor (Write may
  # target a directory that doesn't exist yet), not from the session project.
  REST=$(basename -- "$FP")
  DIR=$(dirname -- "$FP")
  while [ ! -d "$DIR" ] && [ "$DIR" != / ] && [ "$DIR" != . ]; do
    REST="$(basename -- "$DIR")/$REST"
    DIR=$(dirname -- "$DIR")
  done
  TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
  REL="$(git -C "$DIR" rev-parse --show-prefix)${REST}"

  # Remote refs first: a stale local default branch must not hide an applied migration.
  HEADREF=$(git -C "$TOP" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  RESOLVED=0
  FOUND=''
  for ref in $HEADREF origin/main origin/master main master; do
    git -C "$TOP" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || continue
    RESOLVED=1
    if git -C "$TOP" cat-file -e "${ref}:${REL}" 2>/dev/null; then
      FOUND=$ref
      break
    fi
  done
  if [ -n "$FOUND" ]; then
    emit ask "Applied migration (exists on ${FOUND}): confirm edit."
  elif [ "$RESOLVED" -eq 0 ]; then
    emit ask 'Cannot verify migration status (no default-branch ref found): confirm edit.'
  fi
fi
