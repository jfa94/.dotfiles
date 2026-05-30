#!/bin/bash
# Tests for sessionstart-compact-restore.sh — the compaction-continuity hook.
# Run: bash tests/hooks/sessionstart-compact-restore.test.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../.." && pwd)/.claude/hooks/sessionstart-compact-restore.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { # check <description> <condition-exit-code>
  if [ "$2" -eq 0 ]; then printf 'ok   - %s\n' "$1"; pass=$((pass + 1));
  else printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); fi
}
contains() { printf '%s' "$1" | grep -qF "$2"; }
absent() { ! printf '%s' "$1" | grep -qF "$2"; }

# --- Fixture transcript: exercises every content shape ----------------------
FIX="$TMP/transcript.jsonl"
{
  # genuine typed user messages (string content) — the signal we want
  echo '{"type":"user","message":{"content":"First real instruction"}}'
  echo '{"type":"user","message":{"content":"Second real instruction"}}'
  # slash-command / system wrappers (string starting with "<") — must be dropped
  echo '{"type":"user","message":{"content":"<command-name>/foo</command-name>"}}'
  echo '{"type":"user","isMeta":true,"message":{"content":"meta noise"}}'
  echo '{"type":"user","isCompactSummary":true,"message":{"content":"the compact summary itself"}}'
  # array content: injected skill body (text block) + tool_result-only turn — dropped
  echo '{"type":"user","message":{"content":[{"type":"text","text":"injected skill body"}]}}'
  echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"cmd output"}]}}'
  # assistant turn — irrelevant
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}'
  # last genuine message, multi-line — newlines must collapse to one bullet line
  printf '%s\n' '{"type":"user","message":{"content":"Third real instruction\nwith a second line"}}'
} >"$FIX"

run() { # run <transcript_path> <cwd> ; echoes hook stdout, sets RC
  printf '{"hook_event_name":"SessionStart","source":"compact","transcript_path":"%s","cwd":"%s"}' "$1" "$2" | bash "$HOOK"
}

# --- Test 1: happy path -----------------------------------------------------
OUT=$(run "$FIX" "$TMP"); RC=$?
# additionalContext is JSON-encoded; decode to inspect the human-readable text
TEXT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)

check "exit 0 on happy path" "$RC"
check "emits valid SessionStart additionalContext JSON" "$([ -n "$TEXT" ] && echo 0 || echo 1)"
check "wraps output in <compaction-continuity>" "$(contains "$TEXT" "<compaction-continuity>" && echo 0 || echo 1)"
check "includes lossy-summary note" "$(contains "$TEXT" "lossy" && echo 0 || echo 1)"
check "includes transcript pointer path" "$(contains "$TEXT" "$FIX" && echo 0 || echo 1)"
check "includes JSONL format hint" "$(contains "$TEXT" "JSONL" && echo 0 || echo 1)"
check "includes resume nudge" "$(contains "$TEXT" "Next Step" && echo 0 || echo 1)"
check "includes genuine user msg 1" "$(contains "$TEXT" "First real instruction" && echo 0 || echo 1)"
check "includes genuine user msg 3" "$(contains "$TEXT" "Third real instruction" && echo 0 || echo 1)"
check "collapses multi-line msg to one line" "$(contains "$TEXT" "Third real instruction with a second line" && echo 0 || echo 1)"
check "drops <command> wrapper noise" "$(absent "$TEXT" "command-name" && echo 0 || echo 1)"
check "drops isMeta noise" "$(absent "$TEXT" "meta noise" && echo 0 || echo 1)"
check "drops compact summary record" "$(absent "$TEXT" "the compact summary itself" && echo 0 || echo 1)"
check "drops injected skill body (array text)" "$(absent "$TEXT" "injected skill body" && echo 0 || echo 1)"
check "drops tool_result output" "$(absent "$TEXT" "cmd output" && echo 0 || echo 1)"

# --- Test 2: missing transcript file ----------------------------------------
OUT=$(run "$TMP/nope.jsonl" "$TMP"); RC=$?
TEXT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
check "exit 0 when transcript missing" "$RC"
check "core block still present when transcript missing" "$(contains "$TEXT" "<compaction-continuity>" && echo 0 || echo 1)"
check "no user-instructions block when transcript missing" "$(absent "$TEXT" "keep following these" && echo 0 || echo 1)"

# --- Test 3: non-git cwd ----------------------------------------------------
OUT=$(run "$FIX" "$TMP"); RC=$?
TEXT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
check "exit 0 in non-git cwd" "$RC"
check "branch falls back to (no git)" "$(contains "$TEXT" "(no git)" && echo 0 || echo 1)"

# --- Test 4: jq unavailable / failing ---------------------------------------
# Shadow jq with a stub that always fails (simulates jq absent or broken) while
# keeping bash/cat/git real. Hook must not crash; falls back to plain stdout.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 127\n' >"$TMP/bin/jq"
chmod +x "$TMP/bin/jq"
OUT=$(printf '{"transcript_path":"%s","cwd":"%s"}' "$FIX" "$TMP" | PATH="$TMP/bin:$PATH" bash "$HOOK" 2>/dev/null); RC=$?
check "exit 0 when jq fails" "$RC"
check "falls back to plain-stdout continuity block when jq fails" "$(contains "$OUT" "<compaction-continuity>" && echo 0 || echo 1)"

# --- Test 5: empty stdin ----------------------------------------------------
OUT=$(printf '' | bash "$HOOK"); RC=$?
check "exit 0 on empty stdin" "$RC"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
