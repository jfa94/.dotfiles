#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -r "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$CALLS"
settings="$DOTFILES_DIR/.claude/settings.json"
known="$HOME/.claude/plugins/known_marketplaces.json"
installed="$HOME/.claude/plugins/installed_plugins.json"
mkdir -p "$HOME/.claude/plugins"
case "$*" in
  'plugin marketplace add '*)
    repo=$4
    [[ "$repo" != github:* ]] || exit 90
    if [[ "$SCENARIO" == registration && "$repo" == openai/codex-plugin-cc ]]; then
      echo 'registration diagnostic' >&2
      exit 1
    fi
    name=$(jq -er --arg repo "$repo" '.extraKnownMarketplaces | to_entries[] | select(.value.source.repo == $repo) | .key' "$settings")
    [[ -f "$known" ]] || echo '{}' > "$known"
    jq --arg name "$name" '.[$name] = {}' "$known" > "$known.tmp"
    mv "$known.tmp" "$known"
    ;;
  'plugin install '*)
    id=$3
    [[ "$4 $5" == '--scope user' ]] || exit 91
    jq --arg id "$id" '.enabledPlugins[$id] = true' "$settings" > "$settings.tmp"
    mv "$settings.tmp" "$settings"
    if [[ "$SCENARIO" == plugin && "$id" == codex@openai-codex ]]; then
      echo 'plugin diagnostic' >&2
      exit 1
    fi
    if [[ "$SCENARIO" == unverified && "$id" == codex@openai-codex ]]; then exit 0; fi
    [[ -f "$installed" ]] || echo '{"version":2,"plugins":{}}' > "$installed"
    jq --arg id "$id" '.plugins[$id] = [{scope:"user"}]' "$installed" > "$installed.tmp"
    mv "$installed.tmp" "$installed"
    ;;
  *) exit 92 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/codex"
chmod +x "$WORK/bin/claude" "$WORK/bin/codex"

# Run the actual package/plugin orchestration and final summary with installers
# stubbed. Preflight/linking are covered separately; no live setup is invoked.
cat > "$WORK/run.sh" <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
OS=macos
linked=(); replaced=(); skipped=()
info() { echo "$*"; }
warn() { echo "$*"; }
success() { echo "$*"; }
brew() { echo "brew $*" >> "$CALLS"; [[ "$SCENARIO" != brew ]]; }
install_posthog_cli() { echo posthog >> "$CALLS"; }
posthog-cli() { :; }
verify_homebrew_cli() { :; }
install_codex() { :; }
install_claude_code() { :; }
vim() { :; }
RUN
sed -n '/^# Section 6: Install Packages/,$p' "$ROOT/setup.sh" >> "$WORK/run.sh"

for scenario in fresh existing registration plugin unverified brew malformed; do
  export SCENARIO="$scenario" DOTFILES_DIR="$WORK/$scenario/repo" HOME="$WORK/$scenario/home" CALLS="$WORK/$scenario/calls"
  mkdir -p "$DOTFILES_DIR/.claude" "$DOTFILES_DIR/.codex" "$HOME"
  cp "$ROOT/.claude/settings.json" "$DOTFILES_DIR/.claude/settings.json"
  cp "$ROOT/.claude/plugins.txt" "$ROOT/.claude/install-plugins.sh" "$DOTFILES_DIR/.claude/"
  snapshot=$(jq -c '.enabledPlugins' "$DOTFILES_DIR/.claude/settings.json")
  touch "$DOTFILES_DIR/.codex/plugins.txt" "$CALLS"
  cat > "$DOTFILES_DIR/.codex/install-plugins.sh" <<'STUB'
echo codex-plugins >> "$CALLS"
STUB
  if [[ "$scenario" == existing ]]; then
    PATH="$WORK/bin:$PATH" bash "$WORK/run.sh" > "$WORK/seed-output" 2>&1
    : > "$CALLS"
  elif [[ "$scenario" == malformed ]]; then
    mkdir -p "$HOME/.claude/plugins"
    echo '{broken' > "$HOME/.claude/plugins/known_marketplaces.json"
  fi
  status=0
  PATH="$WORK/bin:$PATH" bash "$WORK/run.sh" > "$WORK/output" 2>&1 || status=$?
  expected=1
  [[ "$scenario" == fresh || "$scenario" == existing ]] && expected=0
  [[ "$status" == "$expected" ]] || { cat "$WORK/output"; fail "$scenario exit $status, expected $expected"; }
  grep -q '=== Summary ===' "$WORK/output" || fail "$scenario summary missing"
  grep -qx codex-plugins "$CALLS" || fail "$scenario independent Codex work skipped"
  [[ $(jq -c '.enabledPlugins' "$DOTFILES_DIR/.claude/settings.json") == "$snapshot" ]] || fail "$scenario enablement changed"
  case "$scenario" in
    fresh)
      [[ $(grep -c '^plugin install ' "$CALLS") == 19 ]] || fail 'fresh installation incomplete'
      [[ $(grep -c '^plugin marketplace add ' "$CALLS") == 5 ]] || fail 'marketplace inventory incomplete'
      ;;
    existing)
      if grep -q '^plugin ' "$CALLS"; then fail 'existing entries reinstalled or upgraded'; fi
      ;;
    registration|plugin|unverified)
      grep -q 'Claude plugins: FAILED' "$WORK/output" || fail "$scenario failure summary missing"
      grep -q 'plugin install aws-core@agent-toolkit-for-aws' "$CALLS" || fail "$scenario later plugin skipped"
      if [[ "$scenario" != unverified ]]; then
        grep -q "$scenario diagnostic" "$WORK/output" || fail "$scenario diagnostic lost"
      else
        grep -q 'Plugin verification failed: codex@openai-codex' "$WORK/output" || fail 'verification missing'
      fi
      ;;
    brew)
      grep -q 'bundle FAILED' "$WORK/output" || fail 'Brewfile failure summary missing'
      grep -q 'Claude plugins: installed' "$WORK/output" || fail 'Brewfile failure stopped Claude installs'
      ;;
  esac
done

# Backup warning and one-generation retention in the real link helper.
eval "$(sed -n '/^link_file() {/,/^}/p' "$ROOT/setup.sh")"
warn() { echo "$*"; }
success() { :; }
# shellcheck disable=SC2034 # Consumed by the eval-loaded production link helper.
MODE=replace
# shellcheck disable=SC2034 # Consumed by the eval-loaded production link helper.
linked=()
# shellcheck disable=SC2034 # Consumed by the eval-loaded production link helper.
replaced=()
# shellcheck disable=SC2034 # Consumed by the eval-loaded production link helper.
skipped=()
echo source > "$WORK/source"
echo current > "$WORK/dest"
echo previous > "$WORK/dest.bak"
link_file "$WORK/source" "$WORK/dest" fixture > "$WORK/backup-output"
grep -q 'Replacing existing backup' "$WORK/backup-output" || fail 'backup warning missing'
[[ $(cat "$WORK/dest.bak") == current && -L "$WORK/dest" && ! -e "$WORK/dest.bak.bak" ]] || fail 'backup retention incorrect'
echo 'local setup: OK'
