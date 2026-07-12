#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_line() {
  local file="$1"
  local line="$2"
  grep -Fqx "$line" "$file" || fail "$file missing: $line"
}

assert_line .gitignore '.code-review/'
assert_line .gitignore '.comprehensive-code-review/'
assert_line .gitignore '.focused-code-review/'

for operation in Read Edit Write; do
  jq -e --arg rule "${operation}(//Users/Javier/**/.code-review/**)" \
    '.permissions.allow | index($rule) != null' .claude/settings.json >/dev/null \
    || fail ".claude/settings.json missing $operation permission"
done

grep -Fq '.codex/skills/code-review' docs/codex-claude-parity.md \
  || fail 'parity doc missing Codex-only skill location'
grep -Fq '.code-review/runs/<UTC timestamp>-<profile>-<nonce>/' docs/codex-claude-parity.md \
  || fail 'parity doc missing shared artifact contract'
grep -Fq 'Codex-only orchestration skills may live under ' .codex/AGENTS.md \
  || fail 'AGENTS.md missing Codex-only skill exception'

printf 'code-review ancillary checks passed\n'
