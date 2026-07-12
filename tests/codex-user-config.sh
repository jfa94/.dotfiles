#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables are consumed by functions loaded via eval.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

DOTFILES_DIR="$ROOT"
CODEX_USER_CONFIG=".codex/user-config.toml"
CODEX_LEGACY_CONFIG=".codex/config.toml"
linked=()
replaced=()
skipped=()
success() { :; }
warn() { :; }

eval "$(sed -n '/^link_file() {/,/^}/p' "$ROOT/setup.sh")"
eval "$(sed -n '/^link_codex_user_config() {/,/^}/p' "$ROOT/setup.sh")"

HOME="$TMP/fresh"
MODE=replace
link_codex_user_config
[[ "$(readlink "$HOME/.codex/config.toml")" == "$ROOT/.codex/user-config.toml" ]]

linked=()
replaced=()
skipped=()
link_codex_user_config
[[ "${skipped[*]}" == *"~/.codex/config.toml"* ]]

HOME="$TMP/legacy"
mkdir -p "$HOME/.codex"
ln -s "$ROOT/.codex/config.toml" "$HOME/.codex/config.toml"
linked=()
replaced=()
skipped=()
MODE=skip
link_codex_user_config
[[ "$(readlink "$HOME/.codex/config.toml")" == "$ROOT/.codex/user-config.toml" ]]
[[ "${replaced[*]}" == *"legacy link migrated"* ]]

HOME="$TMP/user-owned"
mkdir -p "$HOME/.codex"
printf '%s\n' 'user-owned' > "$HOME/.codex/config.toml"
linked=()
replaced=()
skipped=()
MODE=skip
link_codex_user_config
[[ "$(cat "$HOME/.codex/config.toml")" == "user-owned" ]]
[[ "${skipped[*]}" == *"~/.codex/config.toml"* ]]

echo "codex user config link checks passed"
