#!/bin/bash
# SessionStart(compact) hook. The superpowers plugin's own SessionStart injection is
# disabled (we don't want the using-superpowers bootstrap on every startup/clear/compact).
# But a supervised session that was ACTIVELY using superpowers loses that bootstrap when
# the built-in compaction summary replaces the conversation, and won't re-invoke skills.
# This re-arms it — re-injecting the using-superpowers skill verbatim — but ONLY when the
# surviving pre-compaction transcript shows this session actually engaged superpowers.
# Additive; makes no task-state claims; always exits 0.
set -uo pipefail

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$TRANSCRIPT" ] && exit 0
[ -r "$TRANSCRIPT" ] || exit 0

# Invocation-shaped gate: match actual skill invocations (slash command or Skill tool
# call), not the mere presence of "superpowers:" — the available-skills system-reminder
# embeds that substring in virtually every transcript, which made a bare grep always
# true (~1K injected tokens on every compaction, superpowers in use or not).
grep -qE '<command-name>superpowers:|"skill"[[:space:]]*:[[:space:]]*"superpowers:|Skill\(superpowers:' "$TRANSCRIPT" 2>/dev/null || exit 0

# Resolve the active plugin install path from the registry so this tracks version bumps
# (no hardcoded version dir). Missing entry/file → no-op (e.g. superpowers uninstalled).
REG="$HOME/.claude/plugins/installed_plugins.json"
[ -r "$REG" ] || exit 0
INSTALL=$(jq -r '.plugins["superpowers@claude-plugins-official"][0].installPath // empty' "$REG" 2>/dev/null)
[ -z "$INSTALL" ] && exit 0
SKILL="${INSTALL}/skills/using-superpowers/SKILL.md"
[ -r "$SKILL" ] || exit 0

CONTENT=$(cat "$SKILL")
CTX="<EXTREMELY_IMPORTANT>
You have superpowers, and this session was actively using them before it was compacted. The summary above is lossy and dropped the bootstrap below — re-arm it. This is the full content of your 'superpowers:using-superpowers' skill, your introduction to using skills. For all other skills, use the 'Skill' tool:

${CONTENT}
</EXTREMELY_IMPORTANT>"

printf '%s' "$CTX" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null \
  || printf '%s\n' "$CTX"

exit 0
