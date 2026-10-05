#!/usr/bin/env bash
# shellcheck disable=SC2016 # Command fixtures intentionally contain expansions.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.claude/hooks/git-c-allow.sh"
PASS=0

# expected: allow (hook emits allow) or pass (no output; normal permissions apply)
assert_hook() {
  local name=$1 command=$2 expected=$3 mode=${4:-default} output actual
  output=$("$HOOK" <<< "$(jq -cn --arg c "$command" --arg m "$mode" \
    '{permission_mode:$m,tool_input:{command:$c}}')")
  if [[ -n "$output" ]]; then
    actual=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  else
    actual=pass
  fi
  [[ "$actual" = "$expected" ]] || {
    echo "FAIL git-c-allow / $name: expected $expected, got $actual" >&2
    echo "  command: $command" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

assert_hook "status" "git -C /x status" allow
assert_hook "log" "git -C /x log --oneline" allow
assert_hook "remote -v" "git -C /x remote -v" allow
assert_hook "chained add and commit" "git -C /x add a && git -C /x commit -m y" allow
assert_hook "diff --exit-code" "git -C /x diff --exit-code" allow
assert_hook "fetch --unshallow" "git -C /x fetch --unshallow" allow

assert_hook "plan mode" "git -C /x status" pass plan
assert_hook "command substitution" 'git -C /x commit -m "$(id)"' pass
assert_hook "backticks" 'git -C /x commit -m `id`' pass
assert_hook "redirect" "git -C /x log > out" pass
assert_hook "mixed segment" "git -C /x status; rm y" pass
assert_hook "non-listed subcommand" "git -C /x clean -fd" pass
assert_hook "no -C" "git status" pass

assert_hook "rebase -x" "git -C /x rebase -x 'sh' main" pass
assert_hook "rebase -ix" "git -C /x rebase -ix sh main" pass
assert_hook "rebase --ex" "git -C /x rebase --ex=sh" pass
assert_hook "fetch --upl" "git -C /x fetch --upl=sh" pass
assert_hook "ls-remote --u" "git -C /x ls-remote --u=sh" pass
assert_hook "push --rece" "git -C /x push --rece=sh" pass
assert_hook "push --e" "git -C /x push --e=sh" pass
assert_hook "diff --output" "git -C /x diff --output=/tmp/f" pass
assert_hook "injected option in later segment" "git -C /x status && git -C /x rebase -x sh" pass

# The sibling dangerous-patterns hook denies the exec options and bundled flags.
DANGEROUS="$ROOT/.claude/hooks/dangerous-patterns-check.sh"
out=$("$DANGEROUS" <<< "$(jq -cn --arg c "git -C . push -fu" '{tool_input:{command:$c}}')")
[[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]] || {
  echo "FAIL git-c-allow / push -fu not denied by dangerous-patterns" >&2
  exit 1
}
PASS=$((PASS + 1))

echo "git-c-allow: $PASS checks passed"
