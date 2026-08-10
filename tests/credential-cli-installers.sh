#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/setup.sh"

eval "$(sed -n '/^onepassword_arch() {/,/^}/p' "$SETUP")"
eval "$(sed -n '/^stripe_arch() {/,/^}/p' "$SETUP")"

[[ "$(onepassword_arch x86_64)" == amd64 ]]
[[ "$(onepassword_arch aarch64)" == arm64 ]]
[[ "$(onepassword_arch armv7l)" == arm ]]
[[ "$(onepassword_arch i686)" == 386 ]]
if onepassword_arch mips64 >/dev/null 2>&1; then
  echo "FAIL unsupported 1Password architecture accepted" >&2
  exit 1
fi

[[ "$(stripe_arch x86_64)" == x86_64 ]]
[[ "$(stripe_arch aarch64)" == arm64 ]]
if stripe_arch i686 >/dev/null 2>&1; then
  echo "FAIL unsupported Stripe architecture accepted" >&2
  exit 1
fi

grep -Fq 'https://downloads.1password.com/linux/keys/1password.asc' "$SETUP"
# shellcheck disable=SC2016  # Assert the installer's literal temporary path.
grep -Fq 'GNUPGHOME="$tmp/gnupg" gpg --batch --verify op.sig op' "$SETUP"
grep -Fq 'stripe-linux-checksums.txt' "$SETUP"
grep -Fq 'sha256sum -c -' "$SETUP"

echo "credential CLI installer checks passed"
