#!/bin/bash
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
# Match git commit at start or after a chain operator (&&, ;, ||, &, |) — Claude
# routinely writes `git add -A && git commit`, which a ^-anchored trigger skipped.
printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit' || exit 0
# Honor git -C <dir>: scan the repo the commit targets, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
cd "${DIR:-${CLAUDE_PROJECT_DIR:-.}}" || exit 0

# Kept identical to .codex/hooks/pre-commit-check.sh (drift-checked by
# tests/codex-permissions-aws-mcp.sh). id_rsa/id_ed25519 etc. must NOT be
# anchored with a leading '/' — git yields repo-relative paths, so a
# repo-root key (e.g. "id_rsa") needs the (^|/) anchor to match at all.
SECRET_PATH_RE='(^|/)\.env[^/]*($|/)|(^|/)secrets(/|$)|\.(pem|key|p12|pfx)$|(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa)$'
SECRET_EXEMPT_RE='\.env\.(example|sample|template)$'

# --- 1. Block sensitive file paths ---
STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
BLOCKED=$(printf '%s\n' "$STAGED" | grep -iE "$SECRET_PATH_RE" | grep -ivE "$SECRET_EXEMPT_RE" || true)
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
# Added lines only: a commit that REMOVES a secret must not be blocked.
# Split in two: vendor-prefixed/high-signal patterns scan every staged file;
# the generic password/secret_key patterns skip test files, which routinely
# contain fixtures like password: 'Password1' that aren't secrets.
SECRETS=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null \
  | grep -E '^\+' \
  | grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' \
  || true)
if [ -n "$SECRETS" ]; then
  jq -cn --arg r 'Potential secrets detected in staged changes.' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi

NON_TEST=$(printf '%s\n' "$STAGED" | grep -vE '\.(test|spec)\.[jt]sx?$|(^|/)(tests?|__tests__)/' || true)
if [ -n "$NON_TEST" ]; then
  SECRETS=$(printf '%s\n' "$NON_TEST" | tr '\n' '\0' \
    | xargs -0 git diff --cached --diff-filter=ACMR -U0 -- 2>/dev/null \
    | grep -E '^\+' \
    | grep -iE '(password\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|secret_?key\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`])' \
    || true)
  if [ -n "$SECRETS" ]; then
    jq -cn --arg r 'Potential secrets detected in staged changes.' \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
fi
