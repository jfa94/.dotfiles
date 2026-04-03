# Native Tool Nudge Hook

**Date:** 2026-04-03  
**Status:** Approved

## Context

Claude Code provides native tools (Read, Glob, Grep, Edit, Write) that are preferred over Bash equivalents. These give better UX, finer permission granularity, and clearer intent. The CLAUDE.md global config already states this preference, but there's no enforcement. This hook provides a lightweight runtime nudge when Claude uses Bash commands that have native equivalents.

## Goal

Add a PreToolUse hook for Bash that detects common native-tool-equivalent commands and emits a soft advisory message. Never blocks — Claude can proceed. Designed to re-inforce the preference without disrupting flow.

## Detection Strategy

**Segment scan (Approach B):** Split the command on `|`, `;`, `&` and check the first token of each segment against a known mapping. This catches chained commands (e.g. `cat file | grep pattern` flags both) without the noise of full substring matching (which would flag `git commit -m "find the bug"`).

Special case: `echo`/`printf` are only flagged when the segment contains a `>` redirect — bare `echo "msg"` is not a Write equivalent.

## Command Mapping

| Bash command | Native tool |
|---|---|
| `cat`, `head`, `tail` | Read |
| `find`, `ls` | Glob |
| `grep`, `rg` | Grep |
| `sed`, `awk` | Edit |
| `echo`/`printf` + `>` | Write |

## Output Format

`permissionDecision: "allow"` — never blocks execution.

If matches are found, `permissionDecisionReason` contains a single brief line:

```
Native tool available: `grep` → Grep, `cat` → Read — prefer dedicated tools when no pipeline is needed.
```

If no matches: exit 0 silently (no output).

## Implementation

**File:** `~/.dotfiles/.claude/hooks/native-tool-nudge.sh`

- `set -uo pipefail` (no `-e`; commands may legitimately exit non-zero)
- `printf '%s'` for all variable expansion to avoid echo flag issues
- `jq -cn --arg` for JSON output
- Bash 3.2-compatible (no associative arrays; uses `case` for mapping)

**settings.json:** New `Bash` matcher entry, no timeout needed, status message: `"Checking for native tool alternatives"`.

## What This Does Not Do

- Does not block — advisory only
- Does not distinguish pipeline context (false positives are acceptable given soft tone)
- Does not cover every possible Bash equivalent (only the most common ones from CLAUDE.md)
