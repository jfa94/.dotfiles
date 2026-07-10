#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/setup.sh"
PROFILE="$ROOT/.zprofile"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq "$2" "$1" || fail "$1 missing: $2"; }

assert_contains "$SETUP" 'https://chatgpt.com/codex/install.sh'
assert_contains "$SETUP" 'CODEX_NON_INTERACTIVE=1'
assert_contains "$SETUP" 'install_codex()'
assert_contains "$SETUP" 'brew uninstall --cask codex'
assert_contains "$SETUP" 'npm uninstall -g @openai/codex'
assert_contains "$SETUP" 'export PATH="$HOME/.local/bin:'

path_line=$(grep -nF 'export PATH="$HOME/.local/bin:' "$SETUP" | head -1 | cut -d: -f1)
install_line=$(grep -n '^install_codex$' "$SETUP" | head -1 | cut -d: -f1)
[[ "$path_line" -lt "$install_line" ]] || fail 'install_codex must run after ~/.local/bin enters PATH'

if grep -Fq '# >>> Codex installer >>>' "$PROFILE"; then
  fail '.zprofile retains installer-generated Codex PATH block'
fi

# Exercise install_codex twice with a disposable HOME and a mocked official
# installer: first run creates the managed layout, second run must skip it.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.local/bin" "$tmp/bin"

cat > "$tmp/bin/curl" <<'MOCK'
#!/bin/sh
cat <<'INSTALLER'
set -eu
release="$HOME/.codex/packages/standalone/releases/0.0.0-test/bin"
mkdir -p "$release" "$HOME/.codex/packages/standalone" "$HOME/.local/bin"
printf '#!/bin/sh\nprintf "codex-cli 0.0.0-test\\n"\n' > "$release/codex"
chmod +x "$release/codex"
ln -sfn "$HOME/.codex/packages/standalone/releases/0.0.0-test" "$HOME/.codex/packages/standalone/current"
ln -sfn "$HOME/.codex/packages/standalone/current/bin/codex" "$HOME/.local/bin/codex"
INSTALLER
MOCK
chmod +x "$tmp/bin/curl"
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin"

eval "$(sed -n '/^install_codex() {/,/^}/p' "$SETUP")"
info() { :; }
success() { :; }
error() { printf '%s\n' "$*" >&2; }

install_codex
[[ "$codex_status" == 'freshly installed' ]] || fail 'first install status incorrect'
install_codex
[[ "$codex_status" == 'already installed' ]] || fail 'second install did not skip managed installation'

rm "$HOME/.local/bin/codex"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/codex"
chmod +x "$tmp/bin/codex"
if install_codex 2>/dev/null; then
  fail 'non-managed Codex installation was accepted'
fi

printf 'OK\n'
