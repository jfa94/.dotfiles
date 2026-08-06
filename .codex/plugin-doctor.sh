#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PLUGINS_FILE="$ROOT/.codex/plugins.txt"
failures=0

command -v codex >/dev/null 2>&1 || { printf '[FAIL] Bundle installation: Codex CLI missing\n'; exit 1; }
command -v jq >/dev/null 2>&1 || { printf '[FAIL] Bundle installation: jq missing\n'; exit 1; }
[[ -r "$PLUGINS_FILE" ]] || { printf '[FAIL] Bundle installation: required plugin list missing\n'; exit 1; }

plugins_json=$(codex plugin list --available --json 2>/dev/null) || {
  printf '[FAIL] Bundle installation: plugin inventory unavailable\n'
  exit 1
}
mcp_json=$(codex mcp list --json 2>/dev/null || printf '[]')

while IFS= read -r selector; do
  [[ -z "$selector" || "$selector" == \#* ]] && continue
  if printf '%s' "$plugins_json" | jq -e --arg id "$selector" \
      '.installed[] | select(.pluginId == $id and .enabled == true)' >/dev/null; then
    printf '[OK] Bundle installation: %s installed and enabled\n' "$selector"
  else
    printf '[FAIL] Bundle installation: %s missing or disabled\n' "$selector"
    failures=$((failures + 1))
  fi
done < "$PLUGINS_FILE"

while IFS=$'\t' read -r plugin_id plugin_root; do
  [[ -n "$plugin_id" ]] || continue
  manifest="$plugin_root/.codex-plugin/plugin.json"
  if [[ ! -r "$manifest" ]]; then
    printf '[FAIL] App dependencies: %s manifest inaccessible: %s\n' "$plugin_id" "$manifest"
    failures=$((failures + 1))
    continue
  fi
  declared=0
  while IFS= read -r app_rel; do
    [[ -n "$app_rel" ]] || continue
    declared=$((declared + 1))
    if [[ -r "$plugin_root/${app_rel#./}" ]]; then
      printf '[OK] App dependencies: %s app manifest readable: %s\n' "$plugin_id" "$app_rel"
    else
      printf '[FAIL] App dependencies: %s app manifest inaccessible: %s\n' "$plugin_id" "$app_rel"
      failures=$((failures + 1))
    fi
  done < <(jq -r '.apps // empty | if type == "array" then .[] else . end' "$manifest")
  (( declared > 0 )) || printf '[INFO] App dependencies: %s declares no app manifest\n' "$plugin_id"
done < <(printf '%s' "$plugins_json" | jq -r '.installed[] | select(.enabled == true) | [.pluginId, .source.path] | @tsv')

while IFS=$'\t' read -r name status; do
  printf '[INFO] OAuth: %s = %s\n' "$name" "$status"
done < <(printf '%s' "$mcp_json" | jq -r '.[] | [.name, .auth_status] | @tsv')
printf '[INFO] Tool discovery: %s enabled MCP servers discovered\n' \
  "$(printf '%s' "$mcp_json" | jq '[.[] | select(.enabled == true)] | length')"

if hook_output=$(bash "$ROOT/.codex/update-plugins.sh" --validate-only "$ROOT" 2>&1); then
  printf '[OK] Hook validity: enabled hook manifests and targets are readable\n'
else
  printf '[FAIL] Hook validity: %s\n' "$hook_output"
  failures=$((failures + 1))
fi

(( failures == 0 ))
