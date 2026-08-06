#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

plugin_root="$tmp/plugin"
mkdir -p "$tmp/bin" "$tmp/repo/.codex" "$plugin_root/.codex-plugin" "$plugin_root/apps" "$plugin_root/hooks"
printf '%s\n' 'sample@acme' > "$tmp/repo/.codex/plugins.txt"
cp "$ROOT/.codex/update-plugins.sh" "$tmp/repo/.codex/update-plugins.sh"
printf '%s\n' '{"apps":"./apps/apps.json","hooks":"./hooks/hooks.json"}' > "$plugin_root/.codex-plugin/plugin.json"
printf '%s\n' '{}' > "$plugin_root/apps/apps.json"
# shellcheck disable=SC2016 # Fixture must retain the literal plugin placeholder.
printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash \"${PLUGIN_ROOT}/hooks/check.sh\""}]}]}}' > "$plugin_root/hooks/hooks.json"
printf '%s\n' '#!/usr/bin/env bash' > "$plugin_root/hooks/check.sh"

cat > "$tmp/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'plugin list --available --json')
    jq -cn --arg root "${PLUGIN_ROOT_FIXTURE:?}" '{installed:[{pluginId:"sample@acme",name:"sample",marketplaceName:"acme",version:"1.0.0",enabled:true,source:{path:$root}}],available:[]}'
    ;;
  'mcp list --json')
    printf '%s\n' '[{"name":"outsidey_supabase","enabled":true,"auth_status":"authenticated"},{"name":"aws-mcp","enabled":true,"auth_status":"unsupported"}]'
    ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$tmp/bin/codex"
export PATH="$tmp/bin:/usr/bin:/bin" PLUGIN_ROOT_FIXTURE="$plugin_root"

bash "$ROOT/.codex/plugin-doctor.sh" "$tmp/repo" > "$tmp/output"
grep -Fq '[OK] Bundle installation: sample@acme installed and enabled' "$tmp/output"
grep -Fq '[OK] App dependencies: sample@acme app manifest readable' "$tmp/output"
grep -Fq '[INFO] OAuth: outsidey_supabase = authenticated' "$tmp/output"
grep -Fq '[INFO] Tool discovery: 2 enabled MCP servers discovered' "$tmp/output"
grep -Fq '[OK] Hook validity: enabled hook manifests and targets are readable' "$tmp/output"

rm "$plugin_root/hooks/check.sh"
if bash "$ROOT/.codex/plugin-doctor.sh" "$tmp/repo" > "$tmp/output" 2>&1; then
  echo 'FAIL: doctor accepted a missing or moved hook target' >&2
  exit 1
fi
grep -Fq '[FAIL] Hook validity:' "$tmp/output"

printf '%s\n' '#!/usr/bin/env bash' > "$plugin_root/hooks/check.sh"
rm "$plugin_root/apps/apps.json"
if bash "$ROOT/.codex/plugin-doctor.sh" "$tmp/repo" > "$tmp/output" 2>&1; then
  echo 'FAIL: doctor accepted an inaccessible app dependency' >&2
  exit 1
fi
grep -Fq '[FAIL] App dependencies: sample@acme app manifest inaccessible' "$tmp/output"

echo OK
