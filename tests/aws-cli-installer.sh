#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/setup.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
mkdir -p "$HOME/.local/bin" "$tmp/bin"

cat > "$tmp/bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf 'aws-cli/2.22.27 Python/3.12 Darwin/arm64\n'
MOCK

cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "${MOCK_DOWNLOADS:?}"
case "$url" in
  https://awscli.amazonaws.com/v2/install.sh)
    cat > "$out" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/aws" <<'AWS'
#!/usr/bin/env bash
printf 'aws-cli/2.35.23 Python/3.13 Darwin/arm64\n'
AWS
chmod +x "$HOME/.local/bin/aws"
INSTALL
    ;;
  https://astral.sh/uv/install.sh)
    cat > "$out" <<'INSTALL'
#!/usr/bin/env sh
set -eu
mkdir -p "$UV_INSTALL_DIR"
cat > "$UV_INSTALL_DIR/uvx" <<'UVX'
#!/usr/bin/env sh
printf 'uvx 0.8.0\n'
UVX
chmod +x "$UV_INSTALL_DIR/uvx"
INSTALL
    ;;
  *) exit 2 ;;
esac
MOCK

chmod +x "$tmp/bin/aws" "$tmp/bin/curl"
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin"
export MOCK_DOWNLOADS="$tmp/downloads"

eval "$(sed -n '/^version_at_least() {/,/^install_codex() {/p' "$SETUP" | sed '$d')"
info() { :; }
success() { :; }
error() { printf '%s\n' "$*" >&2; }

version_at_least 2.35.0 2.35.0
version_at_least 2.36.1 2.35.0
if version_at_least 2.34.99 2.35.0; then
  echo "FAIL: version comparison accepted an old AWS CLI" >&2
  exit 1
fi

install_aws
[[ "$(aws --version)" == aws-cli/2.35.23* ]]
install_uv
command -v uvx >/dev/null

downloads=$(wc -l < "$MOCK_DOWNLOADS")
install_aws
install_uv
[[ "$(wc -l < "$MOCK_DOWNLOADS")" -eq "$downloads" ]]

echo "OK"
