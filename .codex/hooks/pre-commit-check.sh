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

# The gate runs BEFORE the command executes: `git add X && git commit` has
# nothing staged yet at hook time. Ask git (dry run, touches nothing) what
# this command's own `git add` would stage, so a secret added and committed
# in the same command isn't scanned against an empty/stale index.
PENDING=""
while IFS= read -r seg; do
  [[ -n "$seg" ]] || continue
  # Fail closed rather than eval anything that can execute.
  if printf '%s' "$seg" | grep -qE '[`$><]'; then
    deny "Pre-commit gate cannot resolve 'git add' arguments statically: $seg"
    exit 0
  fi
  rest=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?add[[:space:]]*//')
  ADD_OUT=$(eval "git add --dry-run --ignore-missing $rest" 2>/dev/null) || true
  PENDING+=$(printf '%s\n' "$ADD_OUT" | sed -nE "s/^add '(.*)'\$/\\1/p")$'\n'
done < <(printf '%s' "$CMD" | tr ';&|' '\n' | grep -E '^[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?add([[:space:]]|$)')
PENDING=$(printf '%s\n' "$PENDING" | sed '/^$/d')

ALL_FILES=$(printf '%s\n%s\n' "$STAGED" "$PENDING" | sed '/^$/d' | sort -u)

BLOCKED=$(printf '%s\n' "$ALL_FILES" | grep -iE '(^|/)\.env($|\.|/)|(^|/)secrets/|\.pem$|\.key$|\.p12$|\.pfx$|/id_rsa$|/id_ed25519$' || true)
if [[ -n "$BLOCKED" ]]; then
  deny "Blocked: staged files contain secrets or env files: $(printf '%s' "$BLOCKED" | tr '\n' ' ')"
  exit 0
fi

if [[ -n "$ALL_FILES" ]]; then
  command -v trufflehog >/dev/null 2>&1 || { deny "Pre-commit secret gate requires TruffleHog, but it is unavailable."; exit 0; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    BLOB=$(mktemp)
    TH_ERR=$(mktemp)
    # Already staged -> read the index blob; only pending (not yet staged)
    # -> the file doesn't have a blob yet, read it straight from the worktree.
    if printf '%s\n' "$STAGED" | grep -qxF "$f"; then
      READ_OK=1
      git show ":$f" > "$BLOB" 2>"$TH_ERR" || READ_OK=0
    else
      READ_OK=1
      cat -- "$f" > "$BLOB" 2>"$TH_ERR" || READ_OK=0
    fi
    if [[ "$READ_OK" -eq 0 ]]; then
      DETAIL=$(tail -3 "$TH_ERR" | tr '\n' ' ')
      rm -f "$BLOB" "$TH_ERR"
      deny "Pre-commit gate could not read blob for $f: $DETAIL"
      exit 0
    fi
    if ! TH_OUT=$(trufflehog filesystem "$BLOB" --only-verified --no-update --json 2>"$TH_ERR"); then
      DETAIL=$(tail -3 "$TH_ERR" | tr '\n' ' ')
      rm -f "$BLOB" "$TH_ERR"
      deny "TruffleHog failed while scanning $f: $DETAIL"
      exit 0
    fi
    rm -f "$BLOB" "$TH_ERR"
    if [[ -n "$TH_OUT" ]]; then
      deny "TruffleHog detected a verified secret in file: $f"
      exit 0
    fi
  done <<< "$ALL_FILES"
fi

# Regex sweep, added lines only: a commit that REMOVES a secret must not be blocked.
STAGED_ADDED=$(git diff --cached --diff-filter=ACMR -U0 2>/dev/null | grep -E '^\+' || true)
PENDING_ADDED=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    PENDING_ADDED+=$(git diff -U0 -- "$f" 2>/dev/null | grep -E '^\+' || true)$'\n'
  else
    PENDING_ADDED+=$(git diff --no-index -U0 -- /dev/null "$f" 2>/dev/null | grep -E '^\+' || true)$'\n'
  fi
done <<< "$PENDING"

SECRETS=$(printf '%s\n%s\n' "$STAGED_ADDED" "$PENDING_ADDED" |
  grep -iE '(AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|password\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|secret_?key\s*[:=]\s*["'"'"'`][^"'"'"'`]+["'"'"'`]|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY)' ||
  true)
if [[ -n "$SECRETS" ]]; then
  deny "Potential secrets detected in staged changes."
fi
