#!/bin/bash
set -euo pipefail
cat >/dev/null   # drain stdin; nothing here depends on the payload

# Plan mode ignores whole-tool allow rules for MCP tools that publish no
# annotations.readOnlyHint (isReadOnly() => annotations?.readOnlyHint ?? false).
# PostHog's `exec` publishes none, so mcp__posthog__exec prompts on every plan-mode
# call despite its allow rule. A hook `allow` resolves on a path with no plan-mode
# branch, so it lands.
#
# Blanket-allow is safe by construction, not by trust: this server's URL carries
# readonly=true and PostHog rejects every write tool on it server-side
# ("Unknown tool"). posthog_write is a separate server with its own ask rule,
# which still beats a hook allow.
jq -cn '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"posthog server is server-enforced read-only (readonly=true)."}}'
