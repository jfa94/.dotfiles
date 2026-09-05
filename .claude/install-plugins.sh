#!/usr/bin/env bash
# Local setup only; cloud setup retains its enabled-only, best-effort policy.
set -euo pipefail
DOTFILES_DIR="${1:?usage: install-plugins.sh DOTFILES_DIR}"
settings_file="$DOTFILES_DIR/.claude/settings.json"
known_file="$HOME/.claude/plugins/known_marketplaces.json"
installed_file="$HOME/.claude/plugins/installed_plugins.json"
known='{}'
installed='{"plugins":{}}'
failed=0

if ! command -v jq &>/dev/null; then
  echo 'jq is required to install Claude plugins safely' >&2
  exit 1
fi
snapshot=$(jq -ce '.enabledPlugins // {} | objects' "$settings_file")
marketplaces=$(jq -er '.extraKnownMarketplaces // {} | to_entries | map(
  if .value.source.source == "github" and (.value.source.repo | type) == "string"
  then [.key, .value.source.repo] | @tsv
  else error("Unsupported Claude marketplace source") end) | join("\n")' "$settings_file")
if [[ -f "$known_file" ]]; then
  known=$(jq -ce 'objects' "$known_file")
fi
if [[ -f "$installed_file" ]]; then
  installed=$(jq -ce 'select(.version == 2) | select(.plugins | type == "object")' "$installed_file")
fi

# Installs can flip disabled entries through the runtime settings symlink.
# Restore even when an independent install fails or the script exits early.
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
restore_enablement() {
  local status=$? restored
  restored=$(mktemp "$settings_file.XXXXXX") || exit 1
  if jq --argjson snap "$snapshot" '.enabledPlugins = ((.enabledPlugins // {}) + $snap)' \
      "$settings_file" > "$restored" && mv "$restored" "$settings_file"; then
    exit "$status"
  fi
  echo "Failed to restore Claude plugin enablement; snapshot: $snapshot" >&2
  rm -f "$restored"
  exit 1
}
trap 'restore_enablement' EXIT

while IFS=$'\t' read -r name repo; do
  [[ -z "$name" ]] && continue
  if jq -e --arg name "$name" 'has($name)' <<< "$known" >/dev/null; then
    echo "Marketplace already registered: $name"
  elif claude plugin marketplace add "$repo"; then
    if jq -e --arg name "$name" 'has($name)' "$known_file" >/dev/null; then
      echo "Marketplace: $name"
    else
      echo "Marketplace verification failed: $name" >&2
      failed=1
    fi
  else
    echo "Marketplace registration failed: $name ($repo)" >&2
    failed=1
  fi
done <<< "$marketplaces"

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  if jq -e --arg id "$line" 'any(.plugins[$id][]?; .scope == "user")' <<< "$installed" >/dev/null; then
    echo "Plugin already installed: $line"
  elif claude plugin install "$line" --scope user; then
    echo "Plugin install completed: $line"
  else
    echo "Plugin installation failed: $line" >&2
    failed=1
  fi
  if ! jq -e --arg id "$line" 'any(.plugins[$id][]?; .scope == "user")' "$installed_file" >/dev/null; then
    echo "Plugin verification failed: $line" >&2
    failed=1
  fi
done < "$DOTFILES_DIR/.claude/plugins.txt"
exit "$failed"
