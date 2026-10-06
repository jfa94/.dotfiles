#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=hook-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

# Kept identical to .claude/hooks/pre-commit-check.sh (drift-checked by
# tests/codex-permissions-aws-mcp.sh). id_rsa/id_ed25519 etc. must NOT be
# anchored with a leading '/' — git yields repo-relative paths, so a
# repo-root key (e.g. "id_rsa") needs the (^|/) anchor to match at all.
SECRET_PATH_RE='(^|/)\.env[^/]*($|/)|(^|/)secrets(/|$)|\.(pem|key|p12|pfx)$|(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa)$'
SECRET_EXEMPT_RE='\.env\.(example|sample|template)$'

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
# Match git commit at start or after a chain operator (&&, ;, ||, &, |) —
# `git add -A && git commit` skipped a ^-anchored trigger.
# git invocation at a segment start, also inside ( ) / { } or behind a command wrapper.
GIT_RE='[[:space:]({]*((env|command|exec|nice|nohup|sudo|time|xargs)([[:space:]]+[^;&|]*)?[[:space:]]+)?git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?'
grep -qE "(^|;|&|\|)${GIT_RE}commit" <<< "$CMD" || exit 0
# Honor git -C <dir>: scan the repo the commit targets, not just the session project.
DIR=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
CWD=$(project_dir "$INPUT")
if ! cd "${DIR:-$CWD}"; then deny "Pre-commit gate cannot enter target repository."; exit 0; fi

# >>> shared pre-commit block
# Byte-identical in both runtimes (drift-checked by tests/codex-permissions-aws-mcp.sh).
if ! STAGED=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR 2>/dev/null); then
  deny "Pre-commit gate could not inspect staged files."
  exit 0
fi

# The gate runs BEFORE the command executes: `git add X && git commit` has
# nothing staged yet at hook time. Ask git (dry run, touches nothing) what this
# command's own `git add` would stage, before the cd below (pathspecs are cwd-relative).
PENDING=""
while IFS= read -r seg; do
  [[ -n "$seg" ]] || continue
  rest=$(printf '%s' "$seg" | sed -E "s/^${GIT_RE}add[[:space:]]*//")
  # Fail closed: never eval what can execute, and deny when the dry run fails
  # (subshell parens, quotes split by the segmenter, ignored paths, xargs stdin).
  if grep -qE '[`$><]|(^|[[:space:]({])xargs[[:space:]]' <<< "$seg" || ! ADD_OUT=$(eval "git add --dry-run --ignore-missing $rest" 2>/dev/null); then
    deny "Pre-commit gate cannot resolve 'git add' arguments: $seg"
    exit 0
  fi
  PENDING+=$(printf '%s\n' "$ADD_OUT" | sed -nE "s/^add '(.*)'\$/\\1/p")$'\n'
done < <(printf '%s' "$CMD" | tr ';&|' '\n' | grep -E "^${GIT_RE}add([[:space:]]|\$)")

# Git reports repo-root-relative paths; resolve every one from the root.
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""
if [[ -z "$TOP" ]] || ! cd "$TOP"; then
  deny "Pre-commit gate cannot enter target repository."
  exit 0
fi

# `commit -a/--all` also stages tracked modifications; a ` -…a…` token in any
# message over-matches, which only scans more. Residual: `commit <pathspec>`.
if grep -qE '[[:space:]](--all|-[a-zA-Z]*a[a-zA-Z]*)([[:space:]]|$)' <<< "$CMD"; then
  PENDING+=$(git -c core.quotePath=false diff --name-only --diff-filter=ACMR 2>/dev/null)$'\n'
fi
PENDING=$(printf '%s\n' "$PENDING" | sed '/^$/d')

ALL_FILES=$(printf '%s\n%s\n' "$STAGED" "$PENDING" | sed '/^$/d' | sort -u)

BLOCKED=$(printf '%s\n' "$ALL_FILES" | grep -iE "$SECRET_PATH_RE" | grep -ivE "$SECRET_EXEMPT_RE" || true)
if [[ -n "$BLOCKED" ]]; then
  deny "Blocked: staged files contain secrets or env files: $(printf '%s' "$BLOCKED" | tr '\n' ' ')"
  exit 0
fi

# Scans the index or worktree version of $1 for verified secrets; denies on any
# read or scanner failure. Call directly, never in a subshell: it exits on deny.
scan_version() {
  local f=$1 version=$2 blob err out detail read_ok=1
  blob=$(mktemp)
  err=$(mktemp)
  if [[ "$version" == index ]]; then
    git show ":$f" > "$blob" 2>"$err" || read_ok=0
  else
    cat -- "$f" > "$blob" 2>"$err" || read_ok=0
  fi
  if [[ "$read_ok" -eq 0 ]]; then
    detail=$(tail -3 "$err" | tr '\n' ' ')
    rm -f "$blob" "$err"
    deny "Pre-commit gate could not read the $version version of $f: $detail"
    exit 0
  fi
  # No --fail: its exit code conflates findings with errors; JSON output is the finding.
  if ! out=$(trufflehog filesystem "$blob" --only-verified --no-update --json 2>"$err"); then
    detail=$(tail -3 "$err" | tr '\n' ' ')
    rm -f "$blob" "$err"
    deny "TruffleHog failed while scanning $f: $detail"
    exit 0
  fi
  rm -f "$blob" "$err"
  if [[ -n "$out" ]]; then
    deny "TruffleHog detected a verified secret in file: $f"
    exit 0
  fi
}

if [[ -n "$ALL_FILES" ]]; then
  command -v trufflehog >/dev/null 2>&1 || { deny "Pre-commit secret gate requires TruffleHog, but it is unavailable."; exit 0; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    # Staged and re-added: scan both, either may be committed. Submodule
    # pointers and symlinks commit no scannable content.
    if grep -qxF -- "$f" <<< "$STAGED" &&
      [[ "$(git --literal-pathspecs ls-files --stage -- "$f")" != 160000\ * ]]; then
      scan_version "$f" index
    fi
    if grep -qxF -- "$f" <<< "$PENDING" && [[ ! -L "$f" && ! -d "$f" ]]; then
      scan_version "$f" worktree
    fi
  done <<< "$ALL_FILES"
fi
# <<< shared pre-commit block

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
