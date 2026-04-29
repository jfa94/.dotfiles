#!/bin/bash
set -euo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# Policy denies (formerly settings.json permissions.deny — moved here because
# the CLI strips that array on auto-rewrite; see anthropics/claude-code#22659,
# #51843, #6699).
for PAT in \
  'git( -C [^[:space:]]+)? push[[:space:]].*--force' \
  'git( -C [^[:space:]]+)? push[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? push[[:space:]].*-f([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-gpg-sign' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*-n([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? rebase[[:space:]].*--no-verify' \
  'rm -rf[[:space:]]+(~|\$HOME)' \
  '(pnpm|npm|yarn) publish'; do
  if printf '%s' "$CMD" | grep -qE "$PAT"; then
    jq -cn --arg r "Blocked by policy: $PAT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
done

for PAT in 'rm -r /' 'DROP TABLE' 'DROP DATABASE' 'chmod 777' 'curl.*\|.*sh' 'wget.*\|.*sh'; do
  if printf '%s' "$CMD" | grep -qiE "$PAT"; then
    jq -cn --arg r "Blocked dangerous command pattern: $PAT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
done

if printf '%s' "$CMD" | grep -qiE 'rm -rf'; then
  jq -cn --arg r 'rm -rf detected — confirm before running' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
fi
