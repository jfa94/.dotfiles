#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

for pat in \
  'git( -C [^[:space:]]+)? push[[:space:]].*--force' \
  'git( -C [^[:space:]]+)? push[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? push[[:space:]].*-f([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-gpg-sign' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*-n([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? rebase[[:space:]].*--no-verify' \
  'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+/(|[[:space:]]|\*)' \
  'rm -rf[[:space:]]+(~|\$HOME)' \
  '(pnpm|npm|yarn) publish'; do
  if printf '%s' "$CMD" | grep -qE "$pat"; then
    deny "Blocked by policy: $pat"
    exit 0
  fi
done

for pat in 'DROP TABLE' 'DROP DATABASE' 'TRUNCATE TABLE' 'chmod 777' 'curl.*\|.*sh' 'wget.*\|.*sh'; do
  if printf '%s' "$CMD" | grep -qiE "$pat"; then
    deny "Blocked dangerous command pattern: $pat"
    exit 0
  fi
done

if printf '%s' "$CMD" | grep -qiE 'rm -rf'; then
  deny "rm -rf requires explicit user confirmation in the current turn. Retry only after the user confirms the exact target."
fi
