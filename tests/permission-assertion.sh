#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -r "$WORK"' EXIT
# Exercise the production assertion in a separate errexit shell, so a failed
# assertion must stop execution, rather than merely return a false value.
{
  echo 'set -euo pipefail'
  sed -n '/^assert_hooks_absent() {/,/^}/p' "$ROOT/tests/codex-permissions-aws-mcp.sh"
  cat <<'ASSERT'
assert_hooks_absent "$1"
echo accepted
ASSERT
} > "$WORK/assert.sh"
printf '{"command":"safe"}\n' > "$WORK/good.json"
[[ $(bash "$WORK/assert.sh" "$WORK/good.json") == accepted ]]
for bad in '{"command":"protected-files-check.sh"}' '{"command":"sql-readonly-check.sh"}' '{broken' '' '{} {}' '{"command":"protected-files"} {}'; do
  printf '%s\n' "$bad" > "$WORK/bad.json"
  if bash "$WORK/assert.sh" "$WORK/bad.json" > "$WORK/output" 2>&1; then
    echo 'FAIL: invalid hooks accepted' >&2
    exit 1
  fi
  if grep -q accepted "$WORK/output"; then exit 1; fi
done
echo 'permission assertion: OK'
