#!/usr/bin/env bash
set -uo pipefail

json_get() {
  local input="$1"
  local expr="$2"
  printf '%s' "$input" | jq -r "$expr" 2>/dev/null
}

deny() {
  local reason="$1"
  jq -cn --arg r "$reason" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
}

context() {
  local message="$1"
  jq -cn --arg r "$message" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":$r}}'
}

post_error() {
  local message="$1"
  jq -cn --arg r "$message" '{systemMessage:$r}'
}

session_context() {
  local message="$1"
  jq -cn --arg r "$message" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$r}}'
}

extract_paths() {
  local input="$1"
  local direct patch
  direct=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty' 2>/dev/null)
  if [[ -n "$direct" ]]; then
    printf '%s\n' "$direct"
  fi

  patch=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if [[ -n "$patch" ]]; then
    printf '%s\n' "$patch" |
      sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.*)$/\2/p; s/^\*\*\* Move to: (.*)$/\1/p'
  fi
}

project_dir() {
  local input="$1"
  local cwd
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  [[ -n "$cwd" ]] && printf '%s\n' "$cwd" || pwd
}
