#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BREWFILE="$ROOT/Brewfile"
SETUP="$ROOT/setup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for formula in awscli uv shellcheck typescript typescript-language-server npm-check-updates; do
  grep -Fqx "brew \"$formula\"" "$BREWFILE" || fail "missing formula: $formula"
done

for cask in 1password codex claude-code@latest microsoft-auto-update ollama-app pycharm; do
  grep -Fqx "cask \"$cask\"" "$BREWFILE" || fail "missing cask: $cask"
done

if grep -Fqx 'brew "docker"' "$BREWFILE"; then
  fail 'Docker CLI formula must not duplicate Docker Desktop ownership'
fi

for excluded in adobe-digital-editions firefox inkscape loom macs-fan-control markedit meetingbar nordvpn slack steam voiceink zen zoom; do
  grep -Fqx "cask \"$excluded\"" "$BREWFILE" && fail "unselected cask was added: $excluded"
done

# shellcheck disable=SC2016  # Assert literal deferred expansion in setup.sh.
grep -Fq 'brew bundle install --no-upgrade --file="$DOTFILES_DIR/Brewfile"' "$SETUP" \
  || fail 'brew bundle is not presence-only'
grep -Fq 'verify_homebrew_cli formula awscli aws' "$SETUP" \
  || fail 'macOS AWS ownership is not checked'
grep -Fq 'verify_homebrew_cli cask claude-code@latest claude' "$SETUP" \
  || fail 'macOS Claude ownership is not checked'

# JavaScript CLIs stay presence-only on Linux: each installer runs once even
# when setup invokes it repeatedly.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export MOCK_PNPM_CALLS="$tmp/pnpm-calls"
mkdir -p "$HOME/bin"

cat > "$HOME/bin/pnpm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
package="${3:?missing package}"
printf '%s\n' "$package" >> "$MOCK_PNPM_CALLS"
case "$package" in
  typescript) executable=tsc ;;
  typescript-language-server) executable=typescript-language-server ;;
  npm-check-updates) executable=ncu ;;
  *) exit 2 ;;
esac
printf '#!/bin/sh\nexit 0\n' > "$HOME/bin/$executable"
chmod +x "$HOME/bin/$executable"
MOCK
chmod +x "$HOME/bin/pnpm"
export PATH="$HOME/bin:/usr/bin:/bin"

eval "$(sed -n '/^ensure_pnpm_cli() {/,/^install_npm_check_updates()/p' "$SETUP")"
info() { :; }
warn() { :; }

for _pass in 1 2; do
  install_typescript
  install_typescript_language_server
  install_npm_check_updates
done

[[ "$(wc -l < "$MOCK_PNPM_CALLS")" -eq 3 ]] || fail 'JavaScript CLIs were reinstalled'

printf 'OK\n'
