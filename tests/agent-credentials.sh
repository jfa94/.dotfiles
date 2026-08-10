#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENV_DIR="$ROOT/.config/agent-env"

file="$ENV_DIR/personal.env"
[[ -f "$file" ]] || { echo "FAIL missing $file" >&2; exit 1; }
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  case "$line" in
    *=op://*) ;;
    POSTHOG_CLI_HOST=https://eu.posthog.com) ;;
    *) echo "FAIL unsafe value in $file: ${line%%=*}" >&2; exit 1 ;;
  esac
done < "$file"

lock_helper="$ENV_DIR/op-read-locked"
[[ -f "$lock_helper" ]] || { echo "FAIL missing $lock_helper" >&2; exit 1; }
[[ -x "$lock_helper" ]] || { echo "FAIL not executable: $lock_helper" >&2; exit 1; }
grep -Fq 'zsystem flock' "$lock_helper" || { echo "FAIL $lock_helper does not serialize via zsystem flock" >&2; exit 1; }

for profile in outsidey almunia; do
  [[ ! -e "$ENV_DIR/$profile.env" ]] || {
    echo "FAIL project credential profile remains in dotfiles: $profile" >&2
    exit 1
  }
done

# shellcheck disable=SC2016  # Assert the literal deferred expansion in zshrc.
grep -Fqx 'export AGENT_ENV_FILE="${AGENT_ENV_FILE:-$HOME/.config/agent-env/personal.env}"' "$ROOT/.zshrc"
grep -Fqx "  alias codex='op run --no-masking --env-file \"\$AGENT_ENV_FILE\" -- codex'" "$ROOT/.zshrc"
grep -Fqx "  alias supabase='op run --env-file \"\$AGENT_ENV_FILE\" -- supabase'" "$ROOT/.zshrc"
grep -Fqx "  alias posthog-cli='op run --env-file \"\$AGENT_ENV_FILE\" -- posthog-cli'" "$ROOT/.zshrc"

grep -Fqx 'cask "1password-cli"' "$ROOT/Brewfile"
grep -Fqx 'brew "stripe-cli"' "$ROOT/Brewfile"
grep -q '^install_posthog_cli()' "$ROOT/setup.sh"
grep -q '^install_onepassword_cli()' "$ROOT/setup.sh"
grep -q '^install_stripe()' "$ROOT/setup.sh"
# shellcheck disable=SC2016  # Assert the literal deferred expansion.
grep -Fq '"${XDG_CONFIG_HOME:-$HOME/.config}/op/plugins.sh"' "$ROOT/.zshrc"
if grep -Fq '/Users/Javier/.config/op/plugins.sh' "$ROOT/.zshrc"; then
  echo "FAIL machine-specific 1Password plugin path remains" >&2
  exit 1
fi

if grep -Eq '^(stripe|posthog)@' "$ROOT/.codex/plugins.txt"; then
  echo "FAIL unscoped credential plugin remains in Codex manifest" >&2
  exit 1
fi

echo "agent credential checks passed"
