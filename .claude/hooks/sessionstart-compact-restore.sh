#!/bin/bash
# SessionStart(compact) hook: after a compaction, the built-in summary replaces
# the conversation but the full pre-compaction transcript survives on disk and is
# NOT surfaced to Claude. This hook re-injects a small continuity block: a cheap
# anchor (cwd/branch), the user's most recent verbatim instructions (the #1
# post-compaction failure mode is ignoring standing instructions), and a pointer
# to the surviving transcript for on-demand recovery of anything the lossy summary
# dropped. It is purely additive and never blocks compaction.
#
# Design notes:
# - No -e: a single failing command must never abort the hook. Always exit 0.
# - The load-bearing core (anchor + pointer + nudge) needs ZERO transcript parsing.
#   Only the recent-instructions block parses, and it degrades to absent on error.
# - No baked jq recovery recipes: the JSONL schema is undocumented/unstable, so
#   recovery is left to Claude at runtime (inspect a few lines, then query).
set -uo pipefail

INPUT=$(cat)

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"

BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -z "$BRANCH" ] && BRANCH="(no git)"

# Best-effort, non-load-bearing: last 5 genuinely-typed user messages. Filter to
# string content that is not a meta record, not the compact summary, and not a
# slash-command / system wrapper (those start with "<"). Collapse whitespace and
# cap each at 500 chars so one message == one line for tail.
USER_MSGS=""
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  USER_MSGS=$(jq -r '
    select(.type == "user"
      and (.message.content | type == "string")
      and (.isMeta != true)
      and (.isCompactSummary != true)
      and ((.message.content | startswith("<")) | not))
    | (.message.content | gsub("[[:space:]]+"; " ") | sub("^ +"; "") | .[0:500])
  ' "$TRANSCRIPT" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -5)
fi

# Assemble the continuity block.
CONTEXT="Context was just compacted. The summary above is lossy: it caps each section (~2k tokens) and drops tool outputs, command results, and reasoning.

Working dir: ${CWD} | branch: ${BRANCH}"

if [ -n "$USER_MSGS" ]; then
  CONTEXT="${CONTEXT}

My most recent instructions (verbatim — keep following these):"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    CONTEXT="${CONTEXT}
- \"${line}\""
  done <<EOF
$USER_MSGS
EOF
fi

if [ -n "$TRANSCRIPT" ]; then
  CONTEXT="${CONTEXT}

The full pre-compaction transcript survives on disk at:
${TRANSCRIPT}
It is JSONL (one event per line). To recover anything the summary dropped (older instructions, files edited, command outputs), inspect a few lines first, then jq/grep it or Read its tail."
fi

CONTEXT="${CONTEXT}

You were mid-task. Continue from the summary's Next Step unless I redirect you."

CONTEXT="<compaction-continuity>
${CONTEXT}
</compaction-continuity>"

# Emit as SessionStart additionalContext (documented schema). Fall back to plain
# stdout if jq fails for any reason — either way the context reaches Claude.
printf '%s' "$CONTEXT" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null \
  || printf '%s\n' "$CONTEXT"

exit 0
