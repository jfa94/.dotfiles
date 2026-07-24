#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PLUGINS_FILE="$ROOT/.codex/plugins.txt"
MARKETPLACES_FILE="$ROOT/.codex/plugin-marketplaces.txt"
failures=()

command -v codex >/dev/null 2>&1 || {
  printf 'Codex CLI not found\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'jq not found\n' >&2
  exit 1
}
[[ -f "$PLUGINS_FILE" ]] || {
  printf 'Plugin manifest not found: %s\n' "$PLUGINS_FILE" >&2
  exit 1
}

marketplaces_json=""
if ! marketplaces_json=$(codex plugin marketplace list --json 2>/dev/null); then
  failures+=("could not list marketplaces")
elif [[ -f "$MARKETPLACES_FILE" ]]; then
  while read -r marketplace_name marketplace_source extra; do
    [[ -z "${marketplace_name:-}" || "$marketplace_name" == \#* ]] && continue
    if [[ -n "${extra:-}" || -z "${marketplace_source:-}" ]]; then
      failures+=("invalid marketplace row: $marketplace_name $marketplace_source ${extra:-}")
      continue
    fi
    if printf '%s' "$marketplaces_json" | jq -e --arg name "$marketplace_name" \
      '.marketplaces[] | select(.name == $name)' >/dev/null; then
      if ! codex plugin marketplace upgrade "$marketplace_name" --json >/dev/null 2>&1; then
        failures+=("marketplace upgrade failed: $marketplace_name")
      fi
    elif ! codex plugin marketplace add "$marketplace_source" --json >/dev/null 2>&1; then
      failures+=("marketplace add failed: $marketplace_source")
    fi
  done < "$MARKETPLACES_FILE"
fi

plugins_json=""
if ! plugins_json=$(codex plugin list --available --json 2>/dev/null); then
  failures+=("could not list plugins")
fi

while IFS= read -r selector; do
  [[ -z "$selector" || "$selector" == \#* ]] && continue
  if ! printf '%s' "$plugins_json" | jq -e --arg id "$selector" \
    '(.installed + .available)[] | select(.pluginId == $id)' >/dev/null; then
    failures+=("not available: $selector")
    continue
  fi
  if printf '%s' "$plugins_json" | jq -e --arg id "$selector" \
    '.installed[] | select(.pluginId == $id and .enabled == true)' >/dev/null; then
    printf '[OK]   Codex plugin already installed: %s\n' "$selector"
  elif codex plugin add "$selector" --json >/dev/null 2>&1; then
    printf '[OK]   Codex plugin installed: %s\n' "$selector"
  else
    failures+=("install failed: $selector")
  fi
done < "$PLUGINS_FILE"

if plugins_json=$(codex plugin list --available --json 2>/dev/null); then
  while IFS= read -r selector; do
    [[ -z "$selector" || "$selector" == \#* ]] && continue
    if ! printf '%s' "$plugins_json" | jq -e --arg id "$selector" \
      '.installed[] | select(.pluginId == $id and .enabled == true)' >/dev/null; then
      failures+=("post-verification failed: $selector")
    fi
  done < "$PLUGINS_FILE"
else
  failures+=("post-verification list failed")
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  for failure in "${failures[@]}"; do
    printf '[WARN] Codex plugin: %s\n' "$failure" >&2
  done
  exit 1
fi

printf '[OK]   All required Codex plugins are installed and enabled\n'
