#!/bin/bash
set -uo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
# Match git commit at start or after a chain operator (&&, ;, ||, &, |) — Claude
# routinely writes `git add -A && git commit`, which a ^-anchored trigger skipped.
printf '%s' "$CMD" | grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit' || exit 0

deny() {
  jq -cn --arg r "$1" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
}

# Honor git -C <dir>: scan the repo the commit targets, not just the session project.
# One target repo only: a later segment's own -C is not honored (same as the Codex hook).
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
cd "${DIR:-${CLAUDE_PROJECT_DIR:-.}}" || exit 0

# Kept identical to .codex/hooks/pre-commit-check.sh (drift-checked by
# tests/codex-permissions-aws-mcp.sh). id_rsa/id_ed25519 etc. must NOT be
# anchored with a leading '/' — git yields repo-relative paths, so a
# repo-root key (e.g. "id_rsa") needs the (^|/) anchor to match at all.
SECRET_PATH_RE='(^|/)\.env[^/]*($|/)|(^|/)secrets(/|$)|\.(pem|key|p12|pfx)$|(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa)$'
SECRET_EXEMPT_RE='\.env\.(example|sample|template)$'
TEST_FILE_RE='\.(test|spec)\.[jt]sx?$|(^|/)(tests?|__tests__)/'

if ! STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null); then
  deny "Pre-commit gate could not inspect staged files."
  exit 0
fi

# The gate runs BEFORE the command executes: `git add X && git commit` has
# nothing staged yet at hook time. Ask git (dry run, touches nothing) what this
# command's own `git add` would stage. `commit -a/--all` stages tracked
# modifications too; any ` -…a…` token over-matches, which only scans more files.
# Residual: `git commit <pathspec>` is not resolved.
PENDING=""
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # Fail closed rather than eval anything that can execute.
  if printf '%s' "$seg" | grep -qE '[`$><]'; then
    deny "Pre-commit gate cannot resolve 'git add' arguments statically: $seg"
    exit 0
  fi
  rest=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?add[[:space:]]*//')
  ADD_OUT=$(eval "git add --dry-run --ignore-missing $rest" 2>/dev/null) || true
  PENDING+=$(printf '%s\n' "$ADD_OUT" | sed -nE "s/^add '(.*)'\$/\\1/p")$'\n'
done < <(printf '%s' "$CMD" | tr ';&|' '\n' | grep -E '^[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?add([[:space:]]|$)')
if printf '%s' "$CMD" | grep -qE '[[:space:]](--all|-[a-zA-Z]*a[a-zA-Z]*)([[:space:]]|$)'; then
  # --name-only is repo-root relative; prefix the way back from this directory.
  CDUP=$(git rev-parse --show-cdup 2>/dev/null || true)
  PENDING+=$(git diff --name-only --diff-filter=ACMR 2>/dev/null | sed "s|^|${CDUP}|")$'\n'
fi
PENDING=$(printf '%s\n' "$PENDING" | sed '/^$/d')

ALL_FILES=$(printf '%s\n%s\n' "$STAGED" "$PENDING" | sed '/^$/d' | sort -u)

# --- 1. Block sensitive file paths ---
BLOCKED=$(printf '%s\n' "$ALL_FILES" | grep -iE "$SECRET_PATH_RE" | grep -ivE "$SECRET_EXEMPT_RE" || true)
if [ -n "$BLOCKED" ]; then
  deny "Blocked: staged files contain secrets or env files: $(printf '%s' "$BLOCKED" | tr '\n' ' ')"
  exit 0
fi

# --- 2. Trufflehog scan (verified secrets only) ---
# Dropped --fail so the exit code is not overloaded (it returns non-zero on BOTH
# findings and errors); presence of JSON output is the secret signal. Scanner or
# read errors only warn — the regex sweep below is still a backstop.
if command -v trufflehog >/dev/null 2>&1 && [ -n "$ALL_FILES" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    BLOB=$(mktemp)
    TH_ERR=$(mktemp)
    # Staged -> scan the index blob; only pending -> read the worktree file.
    if printf '%s\n' "$STAGED" | grep -qxF "$f"; then
      git show ":$f" > "$BLOB" 2>"$TH_ERR" || echo "pre-commit: could not read index blob for $f (secret scan incomplete)" >&2
    else
      cat -- "$f" > "$BLOB" 2>"$TH_ERR" || echo "pre-commit: could not read $f (secret scan incomplete)" >&2
    fi
    TH_OUT=$(trufflehog filesystem "$BLOB" --only-verified --no-update --json 2>"$TH_ERR" || true)
    if [ -s "$TH_ERR" ]; then
      echo "trufflehog reported errors; secret scan may be incomplete (regex sweep still runs):" >&2
      tail -3 "$TH_ERR" >&2
    fi
    rm -f "$BLOB" "$TH_ERR"
    if [ -n "$TH_OUT" ]; then
      deny "Trufflehog detected a verified secret in file: $f"
      exit 0
    fi
  done <<< "$ALL_FILES"
fi

# --- 3. Regex sweep (catches unverified/offline secrets trufflehog skips) ---
# Added lines only: a commit that REMOVES a secret must not be blocked.
# Split in two: vendor-prefixed/high-signal patterns scan every file; the generic
# password/secret_key patterns skip test files, which routinely contain fixtures
# with dummy credentials that aren't secrets.
STAGED_ADDED=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null | grep -E '^\+' || true)
STAGED_ADDED_NON_TEST=""
NON_TEST=$(printf '%s\n' "$STAGED" | grep -vE "$TEST_FILE_RE" || true)
if [ -n "$NON_TEST" ]; then
  STAGED_ADDED_NON_TEST=$(printf '%s\n' "$NON_TEST" | tr '\n' '\0' \
    | xargs -0 git diff --cached --diff-filter=ACMR -U0 -- 2>/dev/null \
    | grep -E '^\+' || true)
fi
PENDING_ADDED=""
PENDING_ADDED_NON_TEST=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    ADDED=$(git diff -U0 -- "$f" 2>/dev/null | grep -E '^\+' || true)
  else
    ADDED=$(git diff --no-index -U0 -- /dev/null "$f" 2>/dev/null | grep -E '^\+' || true)
  fi
  PENDING_ADDED+="$ADDED"$'\n'
  printf '%s\n' "$f" | grep -qE "$TEST_FILE_RE" || PENDING_ADDED_NON_TEST+="$ADDED"$'\n'
done <<< "$PENDING"

SECRETS=$(printf '%s\n%s\n' "$STAGED_ADDED" "$PENDING_ADDED" \
  | grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' \
  || true)
if [ -n "$SECRETS" ]; then
  deny 'Potential secrets detected in staged changes.'
  exit 0
fi

SECRETS=$(printf '%s\n%s\n' "$STAGED_ADDED_NON_TEST" "$PENDING_ADDED_NON_TEST" \
  | grep -iE '(password\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|secret_?key\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`])' \
  || true)
if [ -n "$SECRETS" ]; then
  deny 'Potential secrets detected in staged changes.'
  exit 0
fi
