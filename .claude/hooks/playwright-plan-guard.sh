#!/bin/bash
set -euo pipefail

PAYLOAD=$(cat)
MODE=$(jq -r '.permission_mode // empty' <<<"$PAYLOAD")
[ "$MODE" = "plan" ] || exit 0

TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")
case "$TOOL" in
  mcp__plugin_playwright_playwright__browser_navigate | \
    mcp__plugin_playwright_playwright__browser_navigate_back | \
    mcp__plugin_playwright_playwright__browser_snapshot | \
    mcp__plugin_playwright_playwright__browser_take_screenshot | \
    mcp__plugin_playwright_playwright__browser_console_messages | \
    mcp__plugin_playwright_playwright__browser_tabs | \
    mcp__plugin_playwright_playwright__browser_wait_for | \
    mcp__plugin_playwright_playwright__browser_find)
    jq -cn '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Read-only Playwright navigation or inspection is allowed in plan mode."}}'
    ;;
  mcp__plugin_playwright_playwright__*)
    jq -cn '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Plan mode permits only Playwright navigation and read-only inspection; use auto or default mode for browser interactions and JavaScript evaluation."}}'
    ;;
esac
