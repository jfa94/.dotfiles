#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/apply-project-agent-config.sh"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

repos=(
  outsidey
  almunia-survey-email
  almunia-send-surveys-trigger
  almunia-web
  almunia-response-process
)

for repo in "${repos[@]}"; do
  mkdir -p "$SCRATCH/$repo"
  git -C "$SCRATCH/$repo" init -q
done

mkdir -p "$SCRATCH/outsidey/.codex"
printf '%s\n' \
  '{"mcpServers":{"supabase":{"type":"http","url":"https://example.test"}}}' \
  > "$SCRATCH/outsidey/.mcp.json"
printf '%s\n' \
  '[shell_environment_policy.set]' \
  'AWS_PROFILE = "Outsidey"' \
  '' \
  '[mcp_servers.posthog]' \
  'enabled = false' \
  > "$SCRATCH/outsidey/.codex/config.toml"
# shellcheck disable=SC2016  # Fixture must contain a literal home reference.
printf '%s\n' \
  'export AGENT_ENV_FILE="$HOME/.config/agent-env/outsidey.env"' \
  'export AWS_PROFILE="Outsidey"' \
  > "$SCRATCH/outsidey/.envrc"

for repo in "${repos[@]:1}"; do
  # shellcheck disable=SC2016  # Fixture must contain a literal home reference.
  printf '%s\n' \
    'export AGENT_ENV_FILE="$HOME/.config/agent-env/almunia.env"' \
    'export AWS_PROFILE="Almunia"' \
    > "$SCRATCH/$repo/.envrc"
done

AGENT_PROJECTS_ROOT="$SCRATCH" bash "$SCRIPT"
AGENT_PROJECTS_ROOT="$SCRATCH" bash "$SCRIPT"

jq -e '.mcpServers.supabase.url == "https://example.test"' "$SCRATCH/outsidey/.mcp.json" >/dev/null
jq -e '.mcpServers.posthog.url | contains("readonly=true&project_id=107700")' "$SCRATCH/outsidey/.mcp.json" >/dev/null
grep -Fqx 'POSTHOG_CLI_PROJECT_ID=107700' "$SCRATCH/outsidey/.agent-env"
# shellcheck disable=SC2016  # Assert the literal deferred expansion.
grep -Fqx 'export AGENT_ENV_FILE="$(expand_path .agent-env)"' "$SCRATCH/outsidey/.envrc"
grep -Fqx 'bearer_token_env_var = "POSTHOG_MCP_TOKEN"' "$SCRATCH/outsidey/.codex/config.toml"

for repo in "${repos[@]:1}"; do
  grep -Fqx 'export AGENT_ENV_FILE=/dev/null' "$SCRATCH/$repo/.envrc"
  grep -Fqx 'AWS_PROFILE = "Almunia"' "$SCRATCH/$repo/.codex/config.toml"
  [[ $(grep -Fxc 'enabled = false' "$SCRATCH/$repo/.codex/config.toml") -eq 2 ]]
done

printf 'project agent config script checks passed\n'
