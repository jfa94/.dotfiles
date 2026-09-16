#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SETTINGS="$ROOT/.claude/settings.json"
HOOK="$ROOT/.claude/hooks/playwright-plan-guard.sh"
CONFIG="$ROOT/.codex/user-config.toml"
DOC="$ROOT/docs/codex-claude-parity.md"

readonly_tools=(
  browser_navigate
  browser_navigate_back
  browser_snapshot
  browser_take_screenshot
  browser_console_messages
  browser_tabs
  browser_wait_for
  browser_find
)
interaction_tools=(
  browser_click
  browser_type
  browser_fill_form
  browser_select_option
  browser_press_key
  browser_hover
  browser_drag
  browser_drop
  browser_handle_dialog
  browser_close
  browser_evaluate
)

jq empty "$SETTINGS"
jq -e '.enabledPlugins["playwright@claude-plugins-official"] == true' "$SETTINGS" >/dev/null
jq -e '.autoMode.allow | index("$defaults") != null' "$SETTINGS" >/dev/null
jq -e '.autoMode.allow[] | select(startswith("Local-development Playwright:"))' "$SETTINGS" >/dev/null

for tool in "${readonly_tools[@]}" "${interaction_tools[@]}"; do
  jq -e --arg tool "mcp__plugin_playwright_playwright__$tool" \
    '.permissions.allow | index($tool) != null' "$SETTINGS" >/dev/null
done

for tool in browser_run_code_unsafe browser_file_upload browser_network_request browser_network_requests browser_webmcp_call browser_webmcp_list; do
  jq -e --arg tool "mcp__plugin_playwright_playwright__$tool" \
    '.permissions.allow | index($tool) == null' "$SETTINGS" >/dev/null
done

jq -e '.hooks.PreToolUse[] |
  select(.matcher == "^mcp__plugin_playwright_playwright__.*$") |
  .hooks[] |
  select(.command == "~/.claude/hooks/playwright-plan-guard.sh")' "$SETTINGS" >/dev/null

decision() {
  local mode=$1 tool=$2 output
  output=$(jq -cn --arg mode "$mode" --arg tool "mcp__plugin_playwright_playwright__$tool" \
    '{permission_mode:$mode,tool_name:$tool,tool_input:{}}' | bash "$HOOK")
  if [[ -z "$output" ]]; then
    printf 'pass\n'
  else
    jq -r '.hookSpecificOutput.permissionDecision' <<<"$output"
  fi
}

for tool in "${readonly_tools[@]}"; do
  [[ $(decision plan "$tool") == allow ]]
done
for tool in "${interaction_tools[@]}" browser_file_upload browser_network_requests browser_webmcp_call browser_run_code_unsafe browser_future_tool; do
  [[ $(decision plan "$tool") == deny ]]
  [[ $(decision auto "$tool") == pass ]]
  [[ $(decision default "$tool") == pass ]]
done

grep -Fqx 'default_permissions = "workspace-net"' "$CONFIG"
grep -Fqx 'approval_policy = "on-request"' "$CONFIG"
grep -Fqx 'approvals_reviewer = "auto_review"' "$CONFIG"
[[ $(grep -A1 '^\[plugins\."browser@openai-bundled"\]' "$CONFIG" | tail -1) == 'enabled = true' ]]
[[ $(grep -A1 '^\[plugins\."chrome@openai-bundled"\]' "$CONFIG" | tail -1) == 'enabled = true' ]]
grep -Fq 'official Playwright MCP' "$DOC"
grep -Fq "\`tab.playwright.evaluate\`" "$DOC"

echo 'playwright permissions: OK'
