#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hook-lib.sh
. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
TOOL_NAME=$(json_get "$INPUT" '.tool_name // .toolName // empty' | tr '[:upper:]' '[:lower:]')
[[ -n "$TOOL_NAME" ]] || exit 0

# Only govern AWS MCP servers. The hook matcher provides the first filter, and
# this check prevents direct or future broad matcher use from affecting other
# MCP servers with similarly named tools.
case "$TOOL_NAME" in
  mcp__*aws* | mcp__*amazon*) ;;
  *) exit 0 ;;
esac

# AWS core's authenticated escape hatches can read secrets or mutate resources.
# Keep discovery, documentation, skills, and region tools available; require the
# audited AWS CLI path for actual account/resource reads.
case "$TOOL_NAME" in
  *__call_aws | *__run_script | *__get_presigned_url)
    deny "Authenticated AWS MCP API execution is disabled. Use the audited AWS CLI read allowlist; writes require Codex's normal approval flow."
    ;;
  *__get_secret_value | *__batch_get_secret_value)
    deny "Secret values must never enter the context. Resolve secrets only at runtime outside the model context."
    ;;
esac
