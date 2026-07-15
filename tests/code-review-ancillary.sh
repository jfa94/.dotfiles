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

SETTINGS=.claude/settings.json

for directory in \
  .code-review \
  .comprehensive-code-review \
  .focused-code-review \
  .claude-plugin-data \
  .worktrees; do
  for operation in Read Edit; do
    jq -e --arg rule "${operation}(//Users/Javier/**/$directory/**)" \
      '.permissions.allow | index($rule) != null' "$SETTINGS" >/dev/null \
      || fail "$SETTINGS missing $operation permission for $directory"
  done
done

jq -e '.permissions.allow | index("Write") != null' "$SETTINGS" >/dev/null \
  || fail "$SETTINGS missing bare Write permission"

if jq -e '.permissions.allow[] | select(startswith("Write("))' "$SETTINGS" >/dev/null; then
  fail "$SETTINGS contains unsupported scoped Write permission"
fi

for path in \
  '//tmp/**' \
  '//private/tmp/**' \
  '//var/tmp/**' \
  '//private/var/tmp/**' \
  '//var/folders/**' \
  '//private/var/folders/**'; do
  jq -e --arg rule "Edit($path)" '.permissions.allow | index($rule) != null' "$SETTINGS" >/dev/null \
    || fail "$SETTINGS missing absolute $path Edit permission"
done

if jq -e '.permissions.allow[] | select(test("^Edit\\(/(?:private/)?(?:tmp|var/)"))' "$SETTINGS" >/dev/null; then
  fail "$SETTINGS contains project-relative temp Edit permission"
fi

grep -Fq '.codex/skills/code-review' docs/codex-claude-parity.md \
  || fail 'parity doc missing Codex-only skill location'
grep -Fq '.code-review/runs/<UTC timestamp>-<profile>-<nonce>/' docs/codex-claude-parity.md \
  || fail 'parity doc missing shared artifact contract'
grep -Fq 'Codex-only orchestration skills may live under ' .codex/AGENTS.md \
  || fail 'AGENTS.md missing Codex-only skill exception'

printf 'code-review ancillary checks passed\n'
