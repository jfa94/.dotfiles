#!/bin/bash
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
printf '%s' "$CMD" | grep -qE '^git commit' || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# --- 1. Block sensitive file paths ---
STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
BLOCKED=$(printf '%s\n' "$STAGED" | grep -iE '(^|/)\.env($|\.|/)|(^|/)secrets/|\.pem$|\.key$|\.p12$|\.pfx$|/id_rsa$|/id_ed25519$' || true)
if [ -n "$BLOCKED" ]; then
  jq -cn --arg r "Blocked: staged files contain secrets or env files: $(printf '%s' "$BLOCKED" | tr '\n' ' ')" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi

# --- 2. Trufflehog scan (verified secrets only) ---
if command -v trufflehog >/dev/null 2>&1 && [ -n "$STAGED" ]; then
  # Dropped --fail so the exit code is not overloaded (it returns non-zero on BOTH
  # findings and errors); presence of JSON output is the secret signal. Capture
  # stderr and surface scanner errors instead of swallowing them — a crashed scan
  # must not look like a clean one (the regex sweep below is still a backstop).
  TH_ERR=$(mktemp)
  TH_OUT=$(printf '%s\n' "$STAGED" | xargs -I{} trufflehog filesystem "{}" \
    --only-verified --no-update --json 2>"$TH_ERR" || true)
  if [ -s "$TH_ERR" ]; then
    echo "trufflehog reported errors; secret scan may be incomplete (regex sweep still runs):" >&2
    tail -3 "$TH_ERR" >&2
  fi
  rm -f "$TH_ERR"
  if [ -n "$TH_OUT" ]; then
    jq -cn --arg r "Trufflehog detected verified secrets in staged files: $(printf '%s' "$STAGED" | tr '\n' ' ')" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
fi

# --- 3. Regex sweep (catches unverified/offline secrets trufflehog skips) ---
SECRETS=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null \
  | grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|password\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|secret_?key\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' \
  || true)
if [ -n "$SECRETS" ]; then
  jq -cn --arg r 'Potential secrets detected in staged changes.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi
