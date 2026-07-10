#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.rollout_path // .transcript_path // .session_path // empty' 2>/dev/null)

if [[ -z "$TRANSCRIPT" ]]; then
  session_context "Compaction continuity warning: Codex supplied no rollout/transcript path; original requests could not be restored."
  exit 0
fi

if [[ ! -r "$TRANSCRIPT" ]]; then
  session_context "Compaction continuity warning: rollout is unreadable: $TRANSCRIPT"
  exit 0
fi

if ! MESSAGES=$(jq -rs '
  [ .[]
    | select(.type == "event_msg" and .payload.type == "user_message")
    | .payload.message
    | select(type == "string")
    | if test("</environment_context>") then split("</environment_context>") | last else . end
    | gsub("[[:space:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "")
    | select(length > 0)
  ]' "$TRANSCRIPT" 2>/dev/null); then
  session_context "Compaction continuity warning: rollout schema is unreadable or invalid: $TRANSCRIPT"
  exit 0
fi

COUNT=$(printf '%s' "$MESSAGES" | jq 'length')
if [[ "$COUNT" -eq 0 ]]; then
  session_context "Compaction continuity warning: no event_msg.user_message records found; rollout schema may have changed: $TRANSCRIPT"
  exit 0
fi

ORIGINAL=$(printf '%s' "$MESSAGES" | jq -r '.[0][0:1500]')
LATEST=$(printf '%s' "$MESSAGES" | jq -r '.[-1][0:1000]')
CTX="<compaction-continuity>
The built-in compaction summary is lossy. Full rollout: $TRANSCRIPT

Original request (verbatim, capped):
\"$ORIGINAL\""
if [[ "$LATEST" != "$ORIGINAL" ]]; then
  CTX="$CTX

Most recent request (verbatim, capped):
\"$LATEST\""
fi
CTX="$CTX
</compaction-continuity>"
session_context "$CTX"
