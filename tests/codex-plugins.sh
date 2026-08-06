#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/.codex/install-plugins.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/state" "$tmp/repo/.codex"
cp "$ROOT/.codex/plugins.txt" "$tmp/repo/.codex/plugins.txt"
cp "$ROOT/.codex/plugin-marketplaces.txt" "$tmp/repo/.codex/plugin-marketplaces.txt"

cat > "$tmp/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state="${MOCK_STATE:?}"
printf '%s\n' "$*" >> "$state/calls"

if [[ "$*" == "plugin marketplace list --json" ]]; then
  extra=""
  [[ -f "$state/aws-market" ]] && extra="$extra,{\"name\":\"agent-toolkit-for-aws\"}"
  [[ -f "$state/javier-market" ]] && extra="$extra,{\"name\":\"javier-plugins\"}"
  printf '{"marketplaces":[{"name":"openai-curated"}%s]}\n' "$extra"
elif [[ "$1 $2 $3" == "plugin marketplace add" ]]; then
  case "$4" in
    aws/agent-toolkit-for-aws) touch "$state/aws-market" ;;
    jfa94/web-designer) touch "$state/javier-market" ;;
    *) exit 2 ;;
  esac
  printf '{}\n'
elif [[ "$1 $2 $3" == "plugin marketplace upgrade" ]]; then
  printf '{}\n'
elif [[ "$*" == "plugin list --available --json" ]]; then
  installed=()
  available=()
  while IFS= read -r selector; do
    [[ -z "$selector" || "$selector" == \#* ]] && continue
    if [[ -f "$state/plugin-${selector//@/_}" ]]; then
      installed+=("{\"pluginId\":\"$selector\",\"installed\":true,\"enabled\":true}")
    else
      available+=("{\"pluginId\":\"$selector\",\"installed\":false,\"enabled\":false}")
    fi
  done < "$MOCK_MANIFEST"
  printf '{"installed":[%s],"available":[%s]}\n' \
    "$(IFS=,; echo "${installed[*]}")" "$(IFS=,; echo "${available[*]}")"
elif [[ "$1 $2" == "plugin add" ]]; then
  selector="$3"
  [[ "${FAIL_PLUGIN:-}" == "$selector" ]] && exit 3
  touch "$state/plugin-${selector//@/_}"
  printf '{}\n'
else
  exit 4
fi
MOCK
chmod +x "$tmp/bin/codex"

export PATH="$tmp/bin:/usr/bin:/bin"
export MOCK_STATE="$tmp/state"
export MOCK_MANIFEST="$tmp/repo/.codex/plugins.txt"

bash "$INSTALLER" "$tmp/repo"
grep -Fq 'plugin marketplace add aws/agent-toolkit-for-aws --json' "$tmp/state/calls"
grep -Fq 'plugin marketplace add jfa94/web-designer --json' "$tmp/state/calls"

first_adds=$(grep -c '^plugin add ' "$tmp/state/calls")
bash "$INSTALLER" "$tmp/repo"
second_adds=$(grep -c '^plugin add ' "$tmp/state/calls")
[[ "$first_adds" -eq "$second_adds" ]]
if grep -Fq 'plugin marketplace upgrade ' "$tmp/state/calls"; then
  echo "FAIL: normal installer upgraded an existing marketplace" >&2
  exit 1
fi

rm -f "$tmp/state/plugin-posthog_openai-curated"
export FAIL_PLUGIN="posthog@openai-curated"
if bash "$INSTALLER" "$tmp/repo" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a required plugin failure" >&2
  exit 1
fi

expected_plugins=$'stripe@openai-curated\nposthog@openai-curated\naws-core@agent-toolkit-for-aws\nweb-designer@javier-plugins'
[[ $(grep -Ev '^(#|$)' "$ROOT/.codex/plugins.txt") == "$expected_plugins" ]]
expected_marketplace=$'agent-toolkit-for-aws aws/agent-toolkit-for-aws\njavier-plugins jfa94/web-designer'
[[ $(grep -Ev '^(#|$)' "$ROOT/.codex/plugin-marketplaces.txt") == "$expected_marketplace" ]]

: > "$tmp/state/calls"
if env CODEX_THREAD_ID=test bash "$ROOT/.codex/update-plugins.sh" "$tmp/repo" >/dev/null 2>&1; then
  echo "FAIL: updater ran inside an active Codex task" >&2
  exit 1
fi
[[ ! -s "$tmp/state/calls" ]]

echo "OK"
