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
  TH_OUT=$(printf '%s\n' "$STAGED" | xargs -I{} trufflehog filesystem "{}" \
    --only-verified --fail --no-update --json 2>/dev/null || true)
  if [ -n "$TH_OUT" ]; then
    jq -cn --arg r "Trufflehog detected verified secrets in staged files: $(printf '%s' "$STAGED" | tr '\n' ' ')" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
fi

# --- 3. Regex sweep (catches unverified/offline secrets trufflehog skips) ---
SECRETS=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null \
  | grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|password\s*[:=]\s*\S+|secret_?key\s*[:=]\s*\S+|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' \
  || true)
if [ -n "$SECRETS" ]; then
  jq -cn --arg r 'Potential secrets detected in staged changes.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi

# --- 4. TypeScript + lint gates (JS projects only) ---
[ -f "${CLAUDE_PROJECT_DIR:-.}/package.json" ] || exit 0
TSC=0; { npx tsc --noEmit 2>&1; } | tail -10 || TSC=1
LINT=0; { npx eslint . --max-warnings 0 2>&1; } | tail -10 || LINT=1

if [ "$TSC" -ne 0 ] || [ "$LINT" -ne 0 ]; then
  jq -cn --arg r "Pre-commit gate failed: tsc($TSC) lint($LINT). Fix before committing." \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
fi
