#!/bin/bash
# SessionStart(compact) hook. After a compaction the built-in summary replaces the
# conversation. The summary paraphrases the original ask and drops tool output, so
# this hook re-injects the two highest-value anchors verbatim — the original request
# (frames the session) and the most-recent request (immediate task) — plus a pointer
# to the surviving on-disk transcript for anything re-derivable. Purely additive;
# makes no task-state claims; always exits 0.
set -uo pipefail

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$TRANSCRIPT" ] && exit 0

# Emit every genuine user ask, one whitespace-collapsed line each, in order.
# Qualifying = user record, string content, not meta, not the compact summary, and
# either plain typed text or a slash-command <command-args> payload. Bare
# <command-message>/<command-name> wrappers and tool_result turns are skipped, so the
# auto-injected using-superpowers command is ignored and we land on the real ask.
QUALIFIED=""
if [ -r "$TRANSCRIPT" ]; then
  QUALIFIED=$(jq -r '
    select(.type == "user"
      and (.message.content | type == "string")
      and (.isMeta != true)
      and (.isCompactSummary != true))
    | .message.content as $c
    | (if ($c | test("<command-args>"))
         then ($c | capture("<command-args>(?<a>[\\s\\S]*?)</command-args>").a)
       elif ($c | test("^<"))
         then empty
       else $c end)
    | select(. != null)
    | gsub("[[:space:]]+"; " ") | sub("^ +"; "")
    | select(length > 0)
  ' "$TRANSCRIPT" 2>/dev/null)
fi

ORIGINAL=""
LATEST=""
if [ -n "$QUALIFIED" ]; then
  ORIGINAL=$(printf '%s\n' "$QUALIFIED" | head -1 | cut -c1-1500)
  LATEST=$(printf '%s\n' "$QUALIFIED" | tail -1 | cut -c1-1000)
fi

CTX="<compaction-continuity>
Context was compacted; the summary above is lossy. The full pre-compaction transcript survives on disk at:
${TRANSCRIPT}
It is JSONL — grep/jq or Read it if you need to find a bit of missing context (e.g., tool output, edited files, earlier decisions)."

if [ -n "$ORIGINAL" ]; then
  CTX="${CTX}

Original request (verbatim):
\"${ORIGINAL}\""
fi

# Omit latest when it duplicates the original (single-turn session).
if [ -n "$LATEST" ] && [ "$LATEST" != "$ORIGINAL" ]; then
  CTX="${CTX}

Most recent request (verbatim):
\"${LATEST}\""
fi

CTX="${CTX}
</compaction-continuity>"

printf '%s' "$CTX" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null \
  || printf '%s\n' "$CTX"

exit 0
