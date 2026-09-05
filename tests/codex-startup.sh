#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.codex/hooks" "$HOME/.codex/rules"
cp "$ROOT/.codex/user-config.toml" "$TMP/config"
ln -s "$TMP/config" "$HOME/.codex/config.toml"
ln -s "$ROOT/.codex/user-hooks.json" "$HOME/.codex/hooks.json"
ln -s "$ROOT/.codex/hooks/hook-lib.sh" "$HOME/.codex/hooks/hook-lib.sh"
ln -s "$ROOT/.codex/rules/default.rules" "$HOME/.codex/rules/default.rules"
check() { bash "$ROOT/.codex/hooks/sessionstart-symlink-check.sh"; }
[[ -z "$(check)" ]]
sed 's/approvals_reviewer = "auto_review"/approvals_reviewer = "user"/' "$ROOT/.codex/user-config.toml" > "$TMP/config"
check | jq -e '.hookSpecificOutput.additionalContext | contains("approvals_reviewer")' >/dev/null
sed 's/default_permissions = "workspace-net"/default_permissions = ":workspace"/' "$ROOT/.codex/user-config.toml" > "$TMP/config"
check | jq -e '.hookSpecificOutput.additionalContext | contains("default_permissions")' >/dev/null
cp "$ROOT/.codex/user-config.toml" "$TMP/config"
rm "$HOME/.codex/hooks.json"
ln -s "$TMP/missing" "$HOME/.codex/hooks.json"
check | jq -e '.hookSpecificOutput.additionalContext | contains("symlink-integrity")' >/dev/null
rm "$HOME/.codex/hooks.json"
check | jq -e '.hookSpecificOutput.additionalContext | contains("symlink-integrity")' >/dev/null
echo 'codex startup: correct config, reviewer/profile drift, broken/missing links passed'
