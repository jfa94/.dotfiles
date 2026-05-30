#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

printf '%s' "$CMD" | grep -qE '[|;&]' && exit 0

first=$(printf '%s' "$CMD" | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
case "$first" in
  cat|head|tail)
    context "Native file-read tool available; prefer it when no shell pipeline is needed."
    ;;
  find|ls)
    context "Native file search/listing tool available; prefer it when no shell-specific behavior is needed."
    ;;
  grep|rg)
    context "Native search tool available; prefer it when no shell pipeline is needed."
    ;;
  sed|awk)
    context "Native edit/read tools may be clearer than shell text processing when no pipeline is needed."
    ;;
esac
