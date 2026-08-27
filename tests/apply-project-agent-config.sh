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

# Stub `claude` so the user-scope registration step is exercised without
# touching the real ~/.claude.json: writes to a scratch file instead.
STUB_CLAUDE_JSON="$SCRATCH/.claude.json"
printf '%s\n' '{"mcpServers":{}}' > "$STUB_CLAUDE_JSON"
STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
set -euo pipefail
[[ "\$1" == mcp && "\$3" == --scope && "\$4" == user ]] || { echo "unexpected claude invocation: \$*" >&2; exit 1; }
tmp=\$(mktemp "$STUB_CLAUDE_JSON.tmp.XXXXXX")
case "\$2" in
  add-json)
    name="\$5" json="\$6"
    jq --arg n "\$name" --argjson v "\$json" '.mcpServers[\$n] = \$v' "$STUB_CLAUDE_JSON" > "\$tmp"
    ;;
  remove)
    name="\$5"
    jq --arg n "\$name" 'del(.mcpServers[\$n])' "$STUB_CLAUDE_JSON" > "\$tmp"
    ;;
  *)
    echo "unexpected claude invocation: \$*" >&2; exit 1
    ;;
esac
mv "\$tmp" "$STUB_CLAUDE_JSON"
STUB
chmod +x "$STUB_BIN/claude"

HOME="$SCRATCH" PATH="$STUB_BIN:$PATH" AGENT_PROJECTS_ROOT="$SCRATCH" bash "$SCRIPT"
HOME="$SCRATCH" PATH="$STUB_BIN:$PATH" AGENT_PROJECTS_ROOT="$SCRATCH" bash "$SCRIPT"

jq -e '.mcpServers.supabase.url == "https://example.test"' "$SCRATCH/outsidey/.mcp.json" >/dev/null
jq -e '.mcpServers.posthog.url == "https://mcp.posthog.com/mcp?mode=cli&project_id=107700"' "$SCRATCH/outsidey/.mcp.json" >/dev/null
jq -e '.mcpServers.posthog.headersHelper | contains("op-read-locked")' "$SCRATCH/outsidey/.mcp.json" >/dev/null
jq -e '.mcpServers.posthog.headersHelper | contains("PostHog Outsidey API Key")' "$SCRATCH/outsidey/.mcp.json" >/dev/null
jq -e '.mcpServers.posthog_write == null' "$SCRATCH/outsidey/.mcp.json" >/dev/null
grep -Fqx 'POSTHOG_CLI_PROJECT_ID=107700' "$SCRATCH/outsidey/.agent-env"

# User-scope registration: full catalogue, not project-pinned, on the generic (non-Outsidey) credential.
jq -e '.mcpServers.posthog.url == "https://mcp.posthog.com/mcp?mode=cli"' "$STUB_CLAUDE_JSON" >/dev/null
jq -e '.mcpServers.posthog.headersHelper | contains("PostHog API Key")' "$STUB_CLAUDE_JSON" >/dev/null
jq -e '.mcpServers.posthog.headersHelper | contains("PostHog Outsidey API Key") | not' "$STUB_CLAUDE_JSON" >/dev/null
jq -e '.mcpServers.posthog_write == null' "$STUB_CLAUDE_JSON" >/dev/null
jq -e '.mcpServers.supabase.url == "https://mcp.supabase.com/mcp?project_ref=sqdzkusynsbmrdqpfqir&read_only=true"' "$STUB_CLAUDE_JSON" >/dev/null
jq -e '.mcpServers.supabase.headersHelper | contains("Supabase Outsidey Access Token")' "$STUB_CLAUDE_JSON" >/dev/null
# shellcheck disable=SC2016  # Assert the literal deferred expansion.
grep -Fqx 'export AGENT_ENV_FILE="$(expand_path .agent-env)"' "$SCRATCH/outsidey/.envrc"
[[ $(grep -Fxc 'bearer_token_env_var = "POSTHOG_MCP_TOKEN"' "$SCRATCH/outsidey/.codex/config.toml") -eq 1 ]]
[[ $(grep -Fxc '[mcp_servers.posthog_write]' "$SCRATCH/outsidey/.codex/config.toml") -eq 0 ]]

for repo in "${repos[@]:1}"; do
  grep -Fqx 'export AGENT_ENV_FILE=/dev/null' "$SCRATCH/$repo/.envrc"
  grep -Fqx 'AWS_PROFILE = "Almunia"' "$SCRATCH/$repo/.codex/config.toml"
  [[ $(grep -Fxc 'enabled = false' "$SCRATCH/$repo/.codex/config.toml") -eq 2 ]]
done

# Migration fixture: an install still on the old readonly/posthog_write split
# must converge to the single full-catalogue server on the next run.
printf '%s\n' \
  '{"mcpServers":{"supabase":{"type":"http","url":"https://example.test"},"posthog":{"type":"http","url":"https://mcp.posthog.com/mcp?mode=cli&readonly=true&project_id=107700","headersHelper":"old"},"posthog_write":{"type":"http","url":"https://mcp.posthog.com/mcp?mode=cli&project_id=107700","headersHelper":"old"}}}' \
  > "$SCRATCH/outsidey/.mcp.json"
printf '%s\n' \
  '[shell_environment_policy.set]' \
  'AWS_PROFILE = "Outsidey"' \
  '' \
  '[mcp_servers.posthog]' \
  'url = "https://mcp.posthog.com/mcp?mode=cli&readonly=true&project_id=107700"' \
  'bearer_token_env_var = "POSTHOG_MCP_TOKEN"' \
  'required = false' \
  '' \
  '[mcp_servers.posthog_write]' \
  'url = "https://mcp.posthog.com/mcp?mode=cli&project_id=107700"' \
  'bearer_token_env_var = "POSTHOG_MCP_TOKEN"' \
  'required = false' \
  > "$SCRATCH/outsidey/.codex/config.toml"
jq -n '{mcpServers:{
  posthog:{type:"http",url:"https://mcp.posthog.com/mcp?mode=cli&readonly=true",headersHelper:"old"},
  posthog_write:{type:"http",url:"https://mcp.posthog.com/mcp?mode=cli",headersHelper:"old"},
  supabase:{type:"http",url:"https://mcp.supabase.com/mcp?project_ref=sqdzkusynsbmrdqpfqir&read_only=true",headersHelper:"old"}
}}' > "$STUB_CLAUDE_JSON"

HOME="$SCRATCH" PATH="$STUB_BIN:$PATH" AGENT_PROJECTS_ROOT="$SCRATCH" bash "$SCRIPT"

jq -e '.mcpServers.posthog.url == "https://mcp.posthog.com/mcp?mode=cli&project_id=107700"' "$SCRATCH/outsidey/.mcp.json" >/dev/null
jq -e '.mcpServers.posthog_write == null' "$SCRATCH/outsidey/.mcp.json" >/dev/null
jq -e '.mcpServers.posthog.url == "https://mcp.posthog.com/mcp?mode=cli"' "$STUB_CLAUDE_JSON" >/dev/null
jq -e '.mcpServers.posthog_write == null' "$STUB_CLAUDE_JSON" >/dev/null
[[ $(grep -Fxc 'bearer_token_env_var = "POSTHOG_MCP_TOKEN"' "$SCRATCH/outsidey/.codex/config.toml") -eq 1 ]]
[[ $(grep -Fxc '[mcp_servers.posthog_write]' "$SCRATCH/outsidey/.codex/config.toml") -eq 0 ]]

printf 'project agent config script checks passed\n'
