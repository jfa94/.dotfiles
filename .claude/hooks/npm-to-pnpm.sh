#!/bin/bash
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
DESC=$(printf '%s' "$INPUT" | jq -r '.tool_input.description // empty')
[ -z "$CMD" ] && exit 0

NEW=$(printf '%s' "$CMD" | perl -pe '
  s{(^|(?<=[;&|])\s*)npm\s+ci\b}{${1}pnpm install --frozen-lockfile}g;
  s{(^|(?<=[;&|])\s*)npm\s+(i|install)\b}{${1}pnpm install}g;
  s{(^|(?<=[;&|])\s*)npm\s+(t|test)\b}{${1}pnpm test}g;
  s{(^|(?<=[;&|])\s*)npm\b}{${1}pnpm}g;
  s{(^|(?<=[;&|])\s*)npx\b}{${1}pnpm dlx}g;
')

[ "$NEW" = "$CMD" ] && exit 0

jq -cn \
  --arg new "$NEW" \
  --arg desc "$DESC" \
  --arg msg "npm → pnpm: $CMD  ⇒  $NEW" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "Rewrote npm → pnpm",
      updatedInput: { command: $new, description: $desc }
    },
    systemMessage: $msg
  }'
