#!/bin/bash
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

NEW=$(printf '%s' "$CMD" | perl -pe '
  s{(^|(?<=[;&|])\s*)npm\s+init\s+(?:-y|--yes)\b}{${1}pnpm init}g;
  s{(^|(?<=[;&|])\s*)npm\s+ci\b}{${1}pnpm install --frozen-lockfile}g;
  s{(^|(?<=[;&|])\s*)npm\s+(i|install)\b}{${1}pnpm install}g;
  s{(^|(?<=[;&|])\s*)npm\s+(t|test)\b}{${1}pnpm test}g;
  s{(^|(?<=[;&|])\s*)npm\b}{${1}pnpm}g;
  s{(^|(?<=[;&|])\s*)npx\b}{${1}pnpm dlx}g;
')

[ "$NEW" = "$CMD" ] && exit 0

# Deny with the pnpm form instead of rewriting: an allow carrying updatedInput
# would auto-approve the whole chained command, including plan mode.
jq -cn --arg r "Use pnpm, not npm. Run instead: $NEW" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
