#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG="$ROOT/.codex/user-config.toml"
HOOKS="$ROOT/.codex/user-hooks.json"
HOOK="$ROOT/.codex/hooks/aws-mcp-readonly-check.sh"
PASS=0

assert_config_absent() {
  local pattern=$1
  ! grep -Eq "$pattern" "$CONFIG" || {
    echo "FAIL config unexpectedly contains: $pattern" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

assert_config_present() {
  local value=$1
  grep -Fqx "$value" "$CONFIG" || {
    echo "FAIL config missing: $value" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

assert_tool() {
  local name=$1 expected=$2 output decision
  output=$(HOME="$HOME" bash "$HOOK" <<< "$(jq -cn --arg name "$name" '{tool_name:$name,tool_input:{}}')")
  if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  else
    decision=allow
  fi
  [[ "$decision" == "$expected" ]] || {
    echo "FAIL $name: expected $expected, got $decision: $output" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

assert_shell_command() {
  local command=$1 expected=$2 output decision
  output=$(HOME="$HOME" bash "$ROOT/.codex/hooks/critical-rm-check.sh" <<< \
    "$(jq -cn --arg command "$command" '{tool_input:{command:$command}}')")
  if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  else
    decision=allow
  fi
  [[ "$decision" == "$expected" ]] || {
    echo "FAIL shell command: expected $expected, got $decision: $output" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

# Environment files inherit readable workspace access. Edits require
# conversational confirmation; commits remain protected by pre-commit-check.sh.
assert_config_absent '\.env(\.\*)?"[[:space:]]*=[[:space:]]*"deny"'
assert_config_present '"~/.aws/credentials" = "read"'
assert_config_present '"~/.aws/config" = "read"'
# No filesystem deny entries anywhere: a single deny-read makes Codex silently
# keep the seatbelt sandbox on require_escalated commands instead of dropping
# it (Chromium/Playwright's mach-register need is otherwise unreachable).
# Secrets stay protected on the commit side by pre-commit-check.sh; edits use
# the current-turn conversational confirmation requirement.
assert_config_absent '=[[:space:]]*"deny"'
assert_config_present 'ignore_default_excludes = false'
assert_config_absent '^sandbox_mode[[:space:]]*='
[[ ! -e "$ROOT/.codex/hooks/protected-files-check.sh" ]]
[[ ! -e "$ROOT/.codex/hooks/sql-readonly-check.sh" ]]
! jq -e '.. | strings | select(test("protected-files|sql-readonly"))' "$HOOKS" >/dev/null
PASS=$((PASS + 3))

# The pre-commit gates (Codex + Claude) hand-maintain the same secret-path
# regex in two files with no shared library between runtimes; the workdir
# bug (id_rsa unblocked at repo root) shipped BECAUSE these silently drifted.
# Pin them equal so a future edit to one side fails loudly instead of drifting.
CODEX_SECRET_RE=$(grep -oE "^SECRET_PATH_RE='[^']*'" "$ROOT/.codex/hooks/pre-commit-check.sh")
CLAUDE_SECRET_RE=$(grep -oE "^SECRET_PATH_RE='[^']*'" "$ROOT/.claude/hooks/pre-commit-check.sh")
[[ -n "$CODEX_SECRET_RE" && "$CODEX_SECRET_RE" == "$CLAUDE_SECRET_RE" ]] || {
  echo "FAIL pre-commit SECRET_PATH_RE drifted between .codex and .claude hooks" >&2
  exit 1
}
grep -qF "(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa)\$" "$ROOT/.codex/hooks/pre-commit-check.sh"
PASS=$((PASS + 2))

assert_shell_command "cat $ROOT/.env.local" allow
assert_shell_command "printf value > $ROOT/.env.local" allow
assert_shell_command "printf '%s' 'git push --force; rm -rf /; DROP TABLE x; pnpm publish'" allow

[[ $(grep -A1 '^\[plugins\."github@openai-curated"\]$' "$CONFIG" | tail -1) == "enabled = false" ]]
if grep -q '^\[plugins\."github@openai-curated-remote"\]$' "$CONFIG"; then
  exit 1
fi
PASS=$((PASS + 2))

jq -e '.hooks.PreToolUse[] | select(.matcher == "mcp__.*[Aa][Ww][Ss].*") |
  .hooks[] | select(.command == "bash $HOME/.codex/hooks/aws-mcp-readonly-check.sh")' "$HOOKS" >/dev/null
PASS=$((PASS + 1))

assert_tool "mcp__aws_core__call_aws" deny
assert_tool "mcp__aws_core__run_script" deny
assert_tool "mcp__aws_core__get_presigned_url" deny
assert_tool "mcp__aws_core__get_secret_value" deny
assert_tool "mcp__aws_core__search_documentation" allow
assert_tool "mcp__aws_core__list_regions" allow
assert_tool "mcp__aws_core__get_skill" allow
assert_tool "mcp__other__run_script" allow

echo "codex permissions/aws mcp: $PASS checks passed"
