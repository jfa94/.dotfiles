#!/usr/bin/env bash
# git clean filter: strip Codex-managed [hooks.state] from user-config.toml
# before it enters the index. The working file (linked to ~/.codex/config.toml)
# keeps the section so Codex's hook-trust state survives; only git ignores it.
#
# Codex appends other sections (e.g. [marketplaces.*]) after [hooks.state], so
# only [hooks.state*] sections are skipped — everything else passes through.
# Volatile [marketplaces.*] keys (last_updated/last_revision) are dropped too:
# they churn on every refresh; only the declarative source belongs in git.
# Blank lines are buffered and flushed only when a later kept non-blank line
# appears, so blank line(s) immediately preceding a stripped section drop too.
#
# stdin -> stdout. Identity transform when no [hooks.state] section exists.
exec awk '
  /^\[hooks\.state/ { skip = 1; next }
  /^\[/             { skip = 0; mkt = ($0 ~ /^\[marketplaces/) }
  skip              { next }
  mkt && /^(last_updated|last_revision)[[:space:]]*=/ { next }
  /^[[:space:]]*$/  { blanks = blanks $0 "\n"; next }
  { printf "%s", blanks; blanks = ""; print }
'
