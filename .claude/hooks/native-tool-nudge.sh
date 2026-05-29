#!/bin/bash
set -uo pipefail

CMD=$(cat | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Only nudge standalone commands. A real pipeline/compound (|, ;, &, &&) genuinely
# needs the shell, so suppress there — the nudge previously fired inside pipelines,
# contradicting its own "when no pipeline is needed" message.
printf '%s' "$CMD" | grep -qE '[|;&]' && exit 0

get_native() {
  case "$1" in
    cat|head|tail) printf 'Read' ;;
    find|ls)       printf 'Glob' ;;
    grep|rg)       printf 'Grep' ;;
    sed|awk)       printf 'Edit' ;;
    *)             printf ''     ;;
  esac
}

FOUND=""
add_entry() { [ -z "$FOUND" ] && FOUND="$1" || FOUND="$FOUND, $1"; }

while IFS= read -r segment; do
  first=$(printf '%s' "$segment" | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
  [ -z "$first" ] && continue
  # Skip if already reported this command
  printf '%s' "$FOUND" | grep -qF "\`$first\`" && continue
  native=$(get_native "$first")
  if [ -n "$native" ]; then
    add_entry "\`$first\` → $native"
  elif [ "$first" = "echo" ] || [ "$first" = "printf" ]; then
    if printf '%s' "$segment" | grep -q '>'; then
      add_entry "\`$first\` → Write"
    fi
  fi
done < <(printf '%s\n' "$CMD" | tr '|;&' '\n')

[ -z "$FOUND" ] && exit 0

jq -cn --arg r "Native tool available: $FOUND — prefer dedicated tools when no pipeline is needed." \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$r}}'
