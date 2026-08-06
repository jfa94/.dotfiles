#!/usr/bin/env bash
set -euo pipefail

mode=update
if [[ "${1:-}" == "--validate-only" ]]; then
  mode=validate
  shift
fi

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PLUGINS_FILE="$ROOT/.codex/plugins.txt"
MARKETPLACES_FILE="$ROOT/.codex/plugin-marketplaces.txt"

if [[ "$mode" == "update" && -n "${CODEX_THREAD_ID:-}" ]]; then
  printf 'error: refusing to update plugins inside an active Codex task\n' >&2
  printf 'Run this command from a normal terminal after closing Codex/ChatGPT.\n' >&2
  exit 1
fi

command -v codex >/dev/null 2>&1 || { printf 'error: Codex CLI not found\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'error: jq not found\n' >&2; exit 1; }

if [[ "$mode" == "update" ]]; then
  marketplaces_json=$(codex plugin marketplace list --json)
  while read -r marketplace_name marketplace_source extra; do
    [[ -z "${marketplace_name:-}" || "$marketplace_name" == \#* ]] && continue
    [[ -z "${extra:-}" ]] || { printf 'error: invalid marketplace row: %s\n' "$marketplace_name" >&2; exit 1; }
    if printf '%s' "$marketplaces_json" | jq -e --arg name "$marketplace_name" \
        '.marketplaces[] | select(.name == $name)' >/dev/null; then
      codex plugin marketplace upgrade "$marketplace_name" --json >/dev/null
      printf '[OK]   Marketplace upgraded: %s\n' "$marketplace_name"
    else
      codex plugin marketplace add "$marketplace_source" --json >/dev/null
      printf '[OK]   Marketplace added: %s\n' "$marketplace_name"
    fi
  done < "$MARKETPLACES_FILE"

  # Add installs missing plugins and refreshes installed plugins from the current snapshot.
  while IFS= read -r selector; do
    [[ -z "$selector" || "$selector" == \#* ]] && continue
    codex plugin add "$selector" --json >/dev/null
    printf '[OK]   Plugin refreshed: %s\n' "$selector"
  done < "$PLUGINS_FILE"
fi

plugins_json=$(codex plugin list --available --json)
failures=()
while IFS=$'\t' read -r plugin_id plugin_name marketplace version source_root; do
  [[ -n "$plugin_id" ]] || continue
  plugin_root="${CODEX_HOME:-$HOME/.codex}/plugins/cache/$marketplace/$plugin_name/$version"
  [[ -d "$plugin_root" ]] || plugin_root="$source_root"
  manifest="$plugin_root/.codex-plugin/plugin.json"
  if [[ ! -r "$manifest" ]]; then
    failures+=("$plugin_id: missing/unreadable manifest $manifest")
    continue
  fi
  hook_rel=$(jq -r '.hooks // empty' "$manifest")
  [[ -n "$hook_rel" ]] || continue
  hook_manifest="$plugin_root/${hook_rel#./}"
  if [[ ! -r "$hook_manifest" ]]; then
    failures+=("$plugin_id: missing/unreadable hook manifest $hook_manifest")
    continue
  fi
  while IFS= read -r command; do
    [[ -n "$command" ]] || continue
    # shellcheck disable=SC2016 # These are literal vendor placeholders.
    resolved=${command//'${PLUGIN_ROOT}'/$plugin_root}
    # shellcheck disable=SC2016 # These are literal vendor placeholders.
    resolved=${resolved//'${CLAUDE_PLUGIN_ROOT}'/$plugin_root}
    while IFS= read -r target; do
      [[ -r "$target" ]] || failures+=("$plugin_id: missing/unreadable hook target $target")
    done < <(printf '%s\n' "$resolved" | grep -Eo '"[^"]+/[^"]+"' | tr -d '"' || true)
  done < <(jq -r '.. | objects | select(.type? == "command") | .command' "$hook_manifest")
done < <(printf '%s' "$plugins_json" | jq -r '.installed[] | select(.enabled == true) | [.pluginId,.name,.marketplaceName,.version,.source.path] | @tsv')

if (( ${#failures[@]} )); then
  printf 'Plugin hook validation failed; do not restart into this plugin set:\n' >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

printf '[OK]   Enabled plugin hook manifests and command targets are readable\n'
if [[ "$mode" == "update" ]]; then
  printf 'REQUIRED: restart Codex/ChatGPT, then review all newly changed hooks in /hooks before working.\n'
fi
