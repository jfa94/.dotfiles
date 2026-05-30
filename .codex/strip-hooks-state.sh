#!/usr/bin/env bash
# git clean filter: strip Codex-managed [hooks.state] section from config.toml
# before it enters the index. The working file (symlinked to ~/.codex/config.toml)
# keeps the section so Codex's hook-trust state survives; only git ignores it.
#
# [hooks.state] is always the trailing section Codex appends, so we print
# everything up to the first `[hooks.state` line and stop. Blank lines are
# buffered and flushed only when a later non-blank line appears, so the blank
# line(s) immediately preceding the stripped section are dropped too.
#
# stdin -> stdout. Identity transform when no [hooks.state] section exists.
exec awk '
  /^\[hooks\.state/ { exit }
  /^[[:space:]]*$/  { blanks = blanks $0 "\n"; next }
  { printf "%s", blanks; blanks = ""; print }
'
