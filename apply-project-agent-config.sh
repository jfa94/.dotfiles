#!/usr/bin/env bash
set -euo pipefail

PROJECTS_ROOT="${AGENT_PROJECTS_ROOT:-$HOME/Projects}"
OUTSIDEY="$PROJECTS_ROOT/outsidey"
ALMUNIA_REPOS=(
  almunia-survey-email
  almunia-send-surveys-trigger
  almunia-web
  almunia-response-process
)

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$PROJECTS_ROOT" == /* && "$PROJECTS_ROOT" != / ]] || fail "unsafe projects root: $PROJECTS_ROOT"
command -v jq >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

require_repo() {
  local repo="$1" repo_real root
  [[ -d "$repo" ]] || fail "repository is missing: $repo"
  repo_real=$(cd "$repo" && pwd -P)
  root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || fail "not a git repository: $repo"
  [[ "$root" == "$repo_real" ]] || fail "unexpected repository root for $repo: $root"
}

write_known_file() {
  local path="$1" old_content="$2" new_content="$3" tmp

  if [[ -e "$path" ]] \
    && ! cmp -s "$path" <(printf '%s\n' "$old_content") \
    && ! cmp -s "$path" <(printf '%s\n' "$new_content"); then
    fail "refusing to overwrite unexpected contents: $path"
  fi

  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "${path}.tmp.XXXXXX")
  printf '%s\n' "$new_content" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$path"
}

outsidey_env=$'SUPABASE_ACCESS_TOKEN=op://Credentials/Supabase Outsidey Access Token/credential\nSTRIPE_MCP_TOKEN=op://Credentials/Stripe Outsidey MCP Restricted Key/credential\nPOSTHOG_MCP_TOKEN=op://Credentials/PostHog API Key/credential\nPOSTHOG_CLI_API_KEY=op://Credentials/PostHog API Key/credential\nPOSTHOG_CLI_HOST=https://eu.posthog.com\nPOSTHOG_CLI_PROJECT_ID=107700'
outsidey_envrc=$'export AGENT_ENV_FILE="$(expand_path .agent-env)"\nexport AWS_PROFILE="Outsidey"'
outsidey_envrc_old=$'export AGENT_ENV_FILE="$HOME/.config/agent-env/outsidey.env"\nexport AWS_PROFILE="Outsidey"'
posthog_url='https://mcp.posthog.com/mcp?mode=cli&readonly=true&project_id=107700'
# shellcheck disable=SC2016  # Preserve command substitution for Claude's helper.
posthog_helper='printf '\''{"Authorization":"Bearer %s"}'\'' "$("$HOME/.config/agent-env/op-read-locked" '\''op://Credentials/PostHog API Key/credential'\'')"'
posthog_toml=$'[mcp_servers.posthog]\nurl = "https://mcp.posthog.com/mcp?mode=cli&readonly=true&project_id=107700"\nbearer_token_env_var = "POSTHOG_MCP_TOKEN"\nrequired = false'
posthog_toml_old=$'[mcp_servers.posthog]\nenabled = false'
almunia_envrc=$'export AGENT_ENV_FILE=/dev/null\nexport AWS_PROFILE="Almunia"'
almunia_envrc_old=$'export AGENT_ENV_FILE="$HOME/.config/agent-env/almunia.env"\nexport AWS_PROFILE="Almunia"'
almunia_codex=$'[shell_environment_policy.set]\nAWS_PROFILE = "Almunia"\n\n[mcp_servers.supabase]\nenabled = false\n\n[mcp_servers.posthog]\nenabled = false'

require_repo "$OUTSIDEY"
for name in "${ALMUNIA_REPOS[@]}"; do
  require_repo "$PROJECTS_ROOT/$name"
done

write_known_file "$OUTSIDEY/.agent-env" "$outsidey_env" "$outsidey_env"
write_known_file "$OUTSIDEY/.envrc" "$outsidey_envrc_old" "$outsidey_envrc"

mcp_file="$OUTSIDEY/.mcp.json"
[[ -f "$mcp_file" ]] || fail "missing $mcp_file"
mcp_tmp=$(mktemp "${mcp_file}.tmp.XXXXXX")
jq --arg url "$posthog_url" --arg helper "$posthog_helper" \
  '.mcpServers.posthog = {type: "http", url: $url, headersHelper: $helper}' \
  "$mcp_file" > "$mcp_tmp"
chmod 600 "$mcp_tmp"
mv "$mcp_tmp" "$mcp_file"

codex_file="$OUTSIDEY/.codex/config.toml"
[[ -f "$codex_file" ]] || fail "missing $codex_file"
current_posthog=$(awk '
  /^\[mcp_servers\.posthog\]$/ { capture=1 }
  capture && /^\[/ && $0 != "[mcp_servers.posthog]" { exit }
  capture { print }
' "$codex_file")
if [[ "$current_posthog" == "$posthog_toml_old" ]]; then
  codex_tmp=$(mktemp "${codex_file}.tmp.XXXXXX")
  awk '
    /^\[mcp_servers\.posthog\]$/ {
      print "[mcp_servers.posthog]"
      print "url = \"https://mcp.posthog.com/mcp?mode=cli&readonly=true&project_id=107700\""
      print "bearer_token_env_var = \"POSTHOG_MCP_TOKEN\""
      print "required = false"
      print ""
      skip=1
      next
    }
    skip && /^\[/ { skip=0 }
    !skip { print }
  ' "$codex_file" > "$codex_tmp"
  chmod 600 "$codex_tmp"
  mv "$codex_tmp" "$codex_file"
elif [[ "$current_posthog" != "$posthog_toml" ]]; then
  fail "refusing to replace unexpected PostHog config in $codex_file"
fi

for name in "${ALMUNIA_REPOS[@]}"; do
  repo="$PROJECTS_ROOT/$name"
  write_known_file "$repo/.envrc" "$almunia_envrc_old" "$almunia_envrc"
  write_known_file "$repo/.codex/config.toml" "$almunia_codex" "$almunia_codex"
done

jq -e --arg url "$posthog_url" \
  '.mcpServers.posthog.type == "http" and .mcpServers.posthog.url == $url' \
  "$mcp_file" >/dev/null
grep -Fqx 'POSTHOG_CLI_PROJECT_ID=107700' "$OUTSIDEY/.agent-env"
# shellcheck disable=SC2016  # Assert the literal deferred expansion.
grep -Fqx 'export AGENT_ENV_FILE="$(expand_path .agent-env)"' "$OUTSIDEY/.envrc"
grep -Fqx 'bearer_token_env_var = "POSTHOG_MCP_TOKEN"' "$codex_file"

for name in "${ALMUNIA_REPOS[@]}"; do
  repo="$PROJECTS_ROOT/$name"
  grep -Fqx 'export AGENT_ENV_FILE=/dev/null' "$repo/.envrc"
  [[ $(grep -Fxc 'enabled = false' "$repo/.codex/config.toml") -eq 2 ]]
done

printf 'Project agent configuration applied and validated.\n'
printf 'Run direnv allow once in Outsidey and each Almunia checkout.\n'
