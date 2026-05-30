#!/bin/bash
# SessionStart(compact) hook. After a compaction the built-in summary replaces the
# conversation, but the full pre-compaction transcript survives on disk and is not
# surfaced to Claude (Claude Code issue #26125). This hook adds one neutral line:
# where that transcript is, so anything the lossy summary dropped can be recovered.
# No claims about task state, no parsing — purely additive, always exits 0.
set -uo pipefail

TRANSCRIPT=$(cat | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$TRANSCRIPT" ] && exit 0

CTX="<compaction-continuity>
Context was compacted; the summary above is lossy. The full pre-compaction transcript survives on disk at:
${TRANSCRIPT}
It is JSONL (one event per line). If something earlier seems missing (an instruction, an edited file, a command's output), recover it from there — inspect a few lines, then grep/jq or Read the relevant part.
</compaction-continuity>"

printf '%s' "$CTX" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null \
  || printf '%s\n' "$CTX"

exit 0
