#!/bin/bash
set -euo pipefail
cat >/dev/null   # drain stdin; nothing here depends on the payload

# Plan mode ignores whole-tool allow rules for MCP tools that publish no
# annotations.readOnlyHint (isReadOnly() => annotations?.readOnlyHint ?? false).
# PostHog's `exec` publishes none, so mcp__posthog__exec prompts on every plan-mode
# call despite its allow rule. A hook `allow` resolves on a path with no plan-mode
# branch, so it lands.
#
# NOT server-enforced: posthog is a single full-catalogue server now: no readonly=true,
# no separate write server/ask rule. This hook allows writes too, plan mode or not.
# Safety is the PostHog API key's own scopes, not this hook.
jq -cn '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"posthog MCP calls are allowed; gated by the PostHog API key'\''s scopes, not this hook."}}'
