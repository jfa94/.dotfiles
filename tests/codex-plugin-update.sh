#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/.codex" "$tmp/home/plugins/cache/acme/sample/1.0.0/hooks"
printf '%s\n' 'sample@acme' > "$tmp/repo/.codex/plugins.txt"
printf '%s\n' 'acme acme/marketplace' > "$tmp/repo/.codex/plugin-marketplaces.txt"
printf '%s\n' '{"name":"sample","version":"1.0.0","hooks":"./hooks/hooks.json"}' \
  > "$tmp/home/plugins/cache/acme/sample/1.0.0/.codex-plugin.json.tmp"
mkdir -p "$tmp/home/plugins/cache/acme/sample/1.0.0/.codex-plugin"
mv "$tmp/home/plugins/cache/acme/sample/1.0.0/.codex-plugin.json.tmp" \
  "$tmp/home/plugins/cache/acme/sample/1.0.0/.codex-plugin/plugin.json"
# shellcheck disable=SC2016 # Fixture must retain the literal plugin placeholder.
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash \"${PLUGIN_ROOT}/hooks/check.sh\""}]}]}}' \
  > "$tmp/home/plugins/cache/acme/sample/1.0.0/hooks/hooks.json"
printf '%s\n' '#!/usr/bin/env bash' > "$tmp/home/plugins/cache/acme/sample/1.0.0/hooks/check.sh"

cat > "$tmp/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CALLS:?}"
case "$*" in
  'plugin marketplace list --json') printf '%s\n' '{"marketplaces":[{"name":"acme"}]}' ;;
  'plugin marketplace upgrade acme --json'|'plugin add sample@acme --json') printf '%s\n' '{}' ;;
  'plugin list --available --json') printf '%s\n' '{"installed":[{"pluginId":"sample@acme","name":"sample","marketplaceName":"acme","version":"1.0.0","enabled":true,"source":{"path":"/unused"}}],"available":[]}' ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$tmp/bin/codex"
export PATH="$tmp/bin:/usr/bin:/bin" CODEX_HOME="$tmp/home" CALLS="$tmp/calls"

env -u CODEX_THREAD_ID bash "$ROOT/.codex/update-plugins.sh" "$tmp/repo" > "$tmp/output"
grep -Fq 'plugin marketplace upgrade acme --json' "$tmp/calls"
grep -Fq 'REQUIRED: restart Codex/ChatGPT' "$tmp/output"

: > "$tmp/calls"
env CODEX_THREAD_ID=test bash "$ROOT/.codex/update-plugins.sh" --validate-only "$tmp/repo" > "$tmp/output"
grep -Fq 'plugin list --available --json' "$tmp/calls"
if grep -Eq 'plugin marketplace (upgrade|add)|plugin add ' "$tmp/calls"; then
  echo 'FAIL: validate-only mode mutated plugin state' >&2
  exit 1
fi
grep -Fq '[OK]   Enabled plugin hook manifests and command targets are readable' "$tmp/output"

rm "$tmp/home/plugins/cache/acme/sample/1.0.0/hooks/check.sh"
if env -u CODEX_THREAD_ID bash "$ROOT/.codex/update-plugins.sh" "$tmp/repo" >/dev/null 2>"$tmp/error"; then
  echo 'FAIL: missing or moved hook command target passed validation' >&2
  exit 1
fi
grep -Fq 'missing/unreadable hook target' "$tmp/error"

echo OK
