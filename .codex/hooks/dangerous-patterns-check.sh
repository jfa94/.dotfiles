#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

# Matches any rm whose flags include r, in any grouping/order
# (-rf, -fr, -Rf, -r -f, -f -r): flag groups may precede and follow the r-group.
RECURSIVE_RM='rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*r[a-zA-Z]*([[:space:]]+-[a-zA-Z]+)*'

# Policy denies — mirrored from rules/default.rules where prefix matching can't
# express them. The push-refspec pattern ([^;&|]* bounds it to the same command)
# catches `git push origin +branch` force-pushes flag rules miss.
for pat in \
  'git( -C [^[:space:]]+)? push[[:space:]].*--force' \
  'git( -C [^[:space:]]+)? push[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? push[[:space:]].*-f([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? push[[:space:]][^;&|]*[[:space:]]\+[^[:space:]]' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-gpg-sign' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*-n([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? rebase[[:space:]].*--no-verify' \
  "${RECURSIVE_RM}[[:space:]]+(~|\\\$HOME)" \
  '(pnpm|npm|yarn) publish'; do
  if printf '%s' "$CMD" | grep -qE "$pat"; then
    deny "Blocked by policy: $pat"
    exit 0
  fi
done

# Dangerous patterns. rm targeting / tolerates any flag order; chmod covers
# -R 777; curl/wget pipes only deny when the pipe target is an actual shell
# word (sh/bash/zsh/dash, optionally sudo) — not shasum, .shell, etc.
for pat in \
  "${RECURSIVE_RM}[[:space:]]+/([[:space:]]|\$|\\*)" \
  'DROP TABLE' \
  'DROP DATABASE' \
  'DROP SCHEMA' \
  'TRUNCATE[[:space:]]+TABLE' \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*777' \
  '(curl|wget)[^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'; do
  if printf '%s' "$CMD" | grep -qiE "$pat"; then
    deny "Blocked dangerous command pattern: $pat"
    exit 0
  fi
done

# Backstop for shell writes that bypass the Edit/Write protected-files gate:
# redirects, sed -i, tee, cp/mv onto .env* / credentials / secrets paths.
# Claude uses an ask tier here; Codex PreToolUse has no ask, so deny with a
# confirm instruction. example/sample/template exempt.
if printf '%s' "$CMD" | grep -qiE '(^|[[:space:]/=("'"'"'])\.env([.[:alnum:]_-]*)?|credentials|(^|[[:space:]/])secrets?/' \
  && printf '%s' "$CMD" | grep -qE '>|[[:space:]]tee[[:space:]]|sed[[:space:]]+[^;&|]*-i|(^|[[:space:]])(mv|cp)[[:space:]]' \
  && ! printf '%s' "$CMD" | grep -qiE '\.env[^[:space:]]*\.(example|sample|template)'; then
  deny "Shell write touching .env/credentials/secrets blocked (protected-files backstop). Retry only after the user confirms the exact target."
  exit 0
fi

# Any recursive+force rm (flag order/grouping tolerant) — confirm-gated.
if printf '%s' "$CMD" | grep -qiE "$RECURSIVE_RM" \
  && printf '%s' "$CMD" | grep -qiE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*f'; then
  deny "Recursive force rm requires explicit user confirmation in the current turn. Retry only after the user confirms the exact target."
fi
