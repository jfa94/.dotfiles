#!/bin/bash
set -euo pipefail
INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.pattern // empty')
[ -z "$FP" ] && exit 0

printf '%s' "$FP" | grep -qE '(^|/)\.claude(/|$)' || exit 0
printf '%s' "$FP" | grep -qE '(^|/)\.claude/worktrees/' && exit 0
printf '%s' "$FP" | grep -qE '(^|/)\.claude/plans/' && exit 0

jq -cn --arg r 'Accessing .claude/ — confirm this is intentional.' \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
