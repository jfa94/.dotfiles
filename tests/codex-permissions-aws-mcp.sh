#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG="$ROOT/.codex/user-config.toml"
HOOKS="$ROOT/.codex/hooks.json"
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

assert_protected_write() {
  local path=$1 expected=$2 output decision
  output=$(HOME="$HOME" bash "$ROOT/.codex/hooks/protected-files-check.sh" <<< \
    "$(jq -cn --arg path "$path" '{tool_input:{file_path:$path}}')")
  if [[ -n "$output" ]]; then
    decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  else
    decision=allow
  fi
  [[ "$decision" == "$expected" ]] || {
    echo "FAIL protected write $path: expected $expected, got $decision: $output" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

assert_shell_command() {
  local command=$1 expected=$2 output decision
  output=$(HOME="$HOME" bash "$ROOT/.codex/hooks/dangerous-patterns-check.sh" <<< \
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

# Environment files inherit readable workspace access. They remain protected
# from writes by protected-files-check.sh and from commits by pre-commit-check.sh.
assert_config_absent '\.env(\.\*)?"[[:space:]]*=[[:space:]]*"deny"'
assert_config_present '"~/.aws/credentials" = "deny"'
assert_config_present '"~/.aws/config" = "deny"'
assert_config_present '"~/.ssh" = "deny"'
assert_config_present '"**/secrets/**" = "deny"'
assert_config_present '"**/*.pem" = "deny"'
assert_config_present '"**/*.key" = "deny"'
assert_config_present 'ignore_default_excludes = false'
assert_config_absent '^sandbox_mode[[:space:]]*='
grep -qF '(^|/)\.env[^/]*$' "$ROOT/.codex/hooks/protected-files-check.sh"
grep -qF '(^|/)\.env($|\.|/)' "$ROOT/.codex/hooks/pre-commit-check.sh"
PASS=$((PASS + 2))
assert_protected_write "$ROOT/.env.local" deny
assert_protected_write "$ROOT/.env.example" allow
assert_shell_command "cat $ROOT/.env.local" allow
assert_shell_command "printf value > $ROOT/.env.local" deny

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
