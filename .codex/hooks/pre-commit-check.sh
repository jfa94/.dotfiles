#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
# Match git commit at start or after a chain operator (&&, ;, ||, &, |) —
# `git add -A && git commit` skipped a ^-anchored trigger.
printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit' || exit 0
# Honor git -C <dir>: scan the repo the commit targets, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
CWD=$(project_dir "$INPUT")
if ! cd "${DIR:-$CWD}"; then deny "Pre-commit gate cannot enter target repository."; exit 0; fi

if ! STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null); then
  deny "Pre-commit gate could not inspect staged files."
  exit 0
fi
BLOCKED=$(printf '%s\n' "$STAGED" | grep -iE '(^|/)\.env($|\.|/)|(^|/)secrets/|\.pem$|\.key$|\.p12$|\.pfx$|/id_rsa$|/id_ed25519$' || true)
if [[ -n "$BLOCKED" ]]; then
  deny "Blocked: staged files contain secrets or env files: $(printf '%s' "$BLOCKED" | tr '\n' ' ')"
  exit 0
fi

if [[ -n "$STAGED" ]]; then
  command -v trufflehog >/dev/null 2>&1 || { deny "Pre-commit secret gate requires TruffleHog, but it is unavailable."; exit 0; }
  while IFS= read -r staged_file; do
    [[ -n "$staged_file" ]] || continue
    STAGED_BLOB=$(mktemp)
    TH_ERR=$(mktemp)
    if ! git show ":$staged_file" > "$STAGED_BLOB" 2>"$TH_ERR"; then
      DETAIL=$(tail -3 "$TH_ERR" | tr '\n' ' ')
      rm -f "$STAGED_BLOB" "$TH_ERR"
      deny "Pre-commit gate could not read staged blob $staged_file: $DETAIL"
      exit 0
    fi
    if ! TH_OUT=$(trufflehog filesystem "$STAGED_BLOB" --only-verified --no-update --json 2>"$TH_ERR"); then
      DETAIL=$(tail -3 "$TH_ERR" | tr '\n' ' ')
      rm -f "$STAGED_BLOB" "$TH_ERR"
      deny "TruffleHog failed while scanning $staged_file: $DETAIL"
      exit 0
    fi
    rm -f "$STAGED_BLOB" "$TH_ERR"
    if [[ -n "$TH_OUT" ]]; then
      deny "TruffleHog detected a verified secret in staged file: $staged_file"
      exit 0
    fi
  done <<< "$STAGED"
fi

# Regex sweep, added lines only: a commit that REMOVES a secret must not be blocked.
SECRETS=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null |
  grep -E '^\+' |
  grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|password\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|secret_?key\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' ||
  true)
if [[ -n "$SECRETS" ]]; then
  deny "Potential secrets detected in staged changes."
fi
