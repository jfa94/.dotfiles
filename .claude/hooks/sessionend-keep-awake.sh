#!/bin/bash
# SessionEnd hook. Kills the powershell keep-awake process started by
# sessionstart-keep-awake.sh for this session_id.
set -uo pipefail
sid=$(jq -r '.session_id // "nosession"')
pidfile="$HOME/.claude/keep-awake-$sid.pid"
if [ -f "$pidfile" ]; then
  kill "$(cat "$pidfile")" 2>/dev/null
  rm -f "$pidfile"
fi
exit 0
