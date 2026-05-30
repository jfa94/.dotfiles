#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
printf '%s' "$CMD" | grep -qE '^[[:space:]]*git( -C [^ ]+)? commit([[:space:]]|$)' || exit 0
CWD=$(project_dir "$INPUT")
cd "$CWD" || exit 0

STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
BLOCKED=$(printf '%s\n' "$STAGED" | grep -iE '(^|/)\.env($|\.|/)|(^|/)secrets/|\.pem$|\.key$|\.p12$|\.pfx$|/id_rsa$|/id_ed25519$' || true)
if [[ -n "$BLOCKED" ]]; then
  deny "Blocked: staged files contain secrets or env files: $(printf '%s' "$BLOCKED" | tr '\n' ' ')"
  exit 0
fi

if command -v trufflehog >/dev/null 2>&1 && [[ -n "$STAGED" ]]; then
  TH_ERR=$(mktemp)
  TH_OUT=$(printf '%s\n' "$STAGED" | xargs -I{} trufflehog filesystem "{}" --only-verified --no-update --json 2>"$TH_ERR" || true)
  if [[ -s "$TH_ERR" ]]; then
    echo "trufflehog reported errors; regex secret scan still runs" >&2
    tail -3 "$TH_ERR" >&2
  fi
  rm -f "$TH_ERR"
  if [[ -n "$TH_OUT" ]]; then
    deny "Trufflehog detected verified secrets in staged files."
    exit 0
  fi
fi

SECRETS=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null |
  grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|password\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|secret_?key\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' ||
  true)
if [[ -n "$SECRETS" ]]; then
  deny "Potential secrets detected in staged changes."
fi
