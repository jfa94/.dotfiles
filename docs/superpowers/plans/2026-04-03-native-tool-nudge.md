# Native Tool Nudge Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PreToolUse Bash hook that detects commands with Claude-native equivalents and emits a soft advisory message.

**Architecture:** A standalone bash script receives tool input JSON on stdin, splits the command on `|`/`;`/`&` into segments, checks the first token of each segment against a known mapping, and emits `permissionDecision: "allow"` with a brief advisory if any matches are found. Never blocks.

**Tech Stack:** bash 3.2+, jq

---

### Task 1: Write failing tests

**Files:**
- Create: `~/.dotfiles/.claude/hooks/native-tool-nudge.sh` (empty for now — tests must fail first)

- [ ] **Step 1: Create the empty script**

```bash
touch ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
chmod +x ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
```

- [ ] **Step 2: Run each test — verify they all fail or produce no output**

```bash
# Test 1: bare cat — should emit advisory, currently produces nothing
echo '{"tool_input":{"command":"cat file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected (after implementation): JSON with permissionDecision allow and cat → Read
# Now: no output

# Test 2: grep — should emit advisory
echo '{"tool_input":{"command":"grep pattern file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: JSON with grep → Grep

# Test 3: pipeline — should emit both
echo '{"tool_input":{"command":"cat file.txt | grep pattern"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: JSON with cat → Read, grep → Grep

# Test 4: git command — should produce no output
echo '{"tool_input":{"command":"git log --oneline -5"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: no output, exit 0

# Test 5: echo without redirect — should produce no output
echo '{"tool_input":{"command":"echo hello"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: no output

# Test 6: echo with redirect — should emit advisory
echo '{"tool_input":{"command":"echo content > file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: JSON with echo → Write

# Test 7: find — should emit advisory
echo '{"tool_input":{"command":"find . -name \"*.ts\""}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: JSON with find → Glob

# Test 8: ls — should emit advisory
echo '{"tool_input":{"command":"ls src/"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: JSON with ls → Glob

# Test 9: sed — should emit advisory
echo '{"tool_input":{"command":"sed -n \"1,10p\" file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: JSON with sed → Edit

# Test 10: no tool_input.command — should produce no output, exit 0
echo '{"tool_input":{}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: no output
```

All should produce no output at this point.

---

### Task 2: Implement the script

**Files:**
- Modify: `~/.dotfiles/.claude/hooks/native-tool-nudge.sh`

- [ ] **Step 1: Write the implementation**

```bash
cat > ~/.dotfiles/.claude/hooks/native-tool-nudge.sh << 'EOF'
#!/bin/bash
set -uo pipefail

CMD=$(cat | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

get_native() {
  case "$1" in
    cat|head|tail) printf 'Read' ;;
    find|ls)       printf 'Glob' ;;
    grep|rg)       printf 'Grep' ;;
    sed|awk)       printf 'Edit' ;;
    *)             printf ''     ;;
  esac
}

FOUND=""

while IFS= read -r segment; do
  first=$(printf '%s' "$segment" | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
  [ -z "$first" ] && continue
  # Skip if already reported this command
  printf '%s' "$FOUND" | grep -qF "\`$first\`" && continue
  native=$(get_native "$first")
  if [ -n "$native" ]; then
    entry="\`$first\` → $native"
    [ -z "$FOUND" ] && FOUND="$entry" || FOUND="$FOUND, $entry"
  elif [ "$first" = "echo" ] || [ "$first" = "printf" ]; then
    if printf '%s' "$segment" | grep -q '>'; then
      entry="\`$first\` → Write"
      [ -z "$FOUND" ] && FOUND="$entry" || FOUND="$FOUND, $entry"
    fi
  fi
done < <(printf '%s\n' "$CMD" | tr '|;&' '\n')

[ -z "$FOUND" ] && exit 0

jq -cn --arg r "Native tool available: $FOUND — prefer dedicated tools when no pipeline is needed." \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$r}}'
EOF
chmod +x ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
```

- [ ] **Step 2: Run all tests — verify they pass**

```bash
echo '{"tool_input":{"command":"cat file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Native tool available: `cat` → Read — prefer dedicated tools when no pipeline is needed."}}

echo '{"tool_input":{"command":"grep pattern file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: ...`grep` → Grep...

echo '{"tool_input":{"command":"cat file.txt | grep pattern"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: ...`cat` → Read, `grep` → Grep...

echo '{"tool_input":{"command":"git log --oneline -5"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: no output

echo '{"tool_input":{"command":"echo hello"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: no output

echo '{"tool_input":{"command":"echo content > file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: ...`echo` → Write...

echo '{"tool_input":{"command":"find . -name \"*.ts\""}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: ...`find` → Glob...

echo '{"tool_input":{"command":"ls src/"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: ...`ls` → Glob...

echo '{"tool_input":{"command":"sed -n \"1,10p\" file.txt"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: ...`sed` → Edit...

echo '{"tool_input":{}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: no output

# Deduplication: grep twice in a pipeline should only report once
echo '{"tool_input":{"command":"grep foo file | grep bar file"}}' | ~/.dotfiles/.claude/hooks/native-tool-nudge.sh
# Expected: ...`grep` → Grep... (only once)
```

- [ ] **Step 3: Commit**

```bash
git -C ~/.dotfiles add .claude/hooks/native-tool-nudge.sh
git -C ~/.dotfiles commit -m "Add native-tool-nudge PreToolUse hook"
```

---

### Task 3: Wire into settings.json

**Files:**
- Modify: `~/.dotfiles/.claude/settings.json`

- [ ] **Step 1: Add hook entry after the dangerous-patterns hook**

In `~/.dotfiles/.claude/settings.json`, after the `dangerous-patterns-check.sh` block (currently ends around line 303), add:

```json
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/native-tool-nudge.sh",
            "statusMessage": "Checking for native tool alternatives"
          }
        ]
      },
```

- [ ] **Step 2: Verify JSON is valid**

```bash
jq empty ~/.dotfiles/.claude/settings.json && echo "valid"
# Expected: valid
```

- [ ] **Step 3: Commit**

```bash
git -C ~/.dotfiles add .claude/settings.json
git -C ~/.dotfiles commit -m "Wire native-tool-nudge hook into settings.json"
```
