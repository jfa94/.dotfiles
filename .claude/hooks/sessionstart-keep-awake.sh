#!/bin/bash
# SessionStart hook. Launches a detached powershell.exe process that keeps
# Windows awake (SetThreadExecutionState) for the life of this session.
# Paired with sessionend-keep-awake.sh, which kills it on clean exit.
# WSL-only: this settings.json is shared with a Mac install, so no-op there
# (no powershell.exe/wslpath -> nothing to launch, no pidfile written).
set -uo pipefail
command -v powershell.exe >/dev/null 2>&1 || exit 0
sid=$(jq -r '.session_id // "nosession"')
pidfile="$HOME/.claude/keep-awake-$sid.pid"
# Idempotent: SessionStart also fires on resume/clear/compact; if this
# session's keep-awake process is already alive, don't spawn another.
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  exit 0
fi
script_win=$(wslpath -w "$HOME/.claude/hooks/keep-awake.ps1")
nohup powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$script_win" >/dev/null 2>&1 &
echo $! > "$pidfile"
exit 0
