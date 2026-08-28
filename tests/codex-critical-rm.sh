#!/usr/bin/env bash
# shellcheck disable=SC2016 # Command fixtures intentionally contain expansions.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.codex/hooks/critical-rm-check.sh"
HOOK_SHELL=${HOOK_SHELL:-/bin/bash}
PASS=0
SCRATCH=$(mktemp -d)
SIBLING=$(mktemp -d)
trap 'rm -rf "$SCRATCH" "$SIBLING"' EXIT

mkdir -p "$SCRATCH/repo/sub" "$SCRATCH/tmp" "$SCRATCH/no-jq" "$SCRATCH/failing-jq" "$SCRATCH/serialize-jq"
ln -s /etc "$SCRATCH/final-link"
ln -s /etc "$SCRATCH/system-parent"
ln -s /etc "$SCRATCH/repo/relative-link"
ln -s /tmp "$SCRATCH/tmp-link"
ln -s "$HOME/.codex" "$SCRATCH/home-descendant-link"
ln -s /does/not/exist "$SCRATCH/broken-link"

REAL_JQ=$(command -v jq)
cat > "$SCRATCH/failing-jq/jq" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$SCRATCH/serialize-jq/jq" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" -cn "*) exit 1 ;;
esac
exec "$REAL_JQ" "\$@"
STUB
chmod +x "$SCRATCH/failing-jq/jq" "$SCRATCH/serialize-jq/jq"

decision_for() {
  local command=$1 workdir=${2:-$SCRATCH/repo} output
  output=$(HOME="$HOME" "$HOOK_SHELL" "$HOOK" <<< "$(
    jq -cn --arg command "$command" --arg cwd "$workdir" \
      '{cwd:$cwd,tool_input:{command:$command,workdir:$cwd}}'
  )")
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"'
  else
    printf 'pass\n'
  fi
}

assert_raw_decision() {
  local name=$1 input=$2 expected=$3 path=${4:-$PATH} home=${5:-$HOME} output actual
  output=$(PATH="$path" HOME="$home" "$HOOK_SHELL" "$HOOK" <<< "$input")
  if [[ -n "$output" ]]; then
    actual=$(printf '%s' "$output" | "$REAL_JQ" -r '.hookSpecificOutput.permissionDecision // "pass"')
  else
    actual=pass
  fi
  [[ "$actual" = "$expected" ]] || {
    echo "FAIL $name: expected $expected, got $actual" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

assert_decision() {
  local name=$1 command=$2 expected=$3 workdir=${4:-$SCRATCH/repo} actual
  actual=$(decision_for "$command" "$workdir")
  [[ "$actual" = "$expected" ]] || {
    echo "FAIL $name: expected $expected, got $actual" >&2
    echo "  command: $command" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

# Only literal critical recursive-force targets are denied.
assert_decision "filesystem root" "rm -rf /" deny
assert_decision "home root" 'rm -rf $HOME' deny
assert_decision "quoted home root" 'rm -rf "$HOME"' deny
assert_decision "etc subtree" "rm -rf /etc/ssh" deny
assert_decision "nonexistent etc subtree" "rm -rf /etc/not-created/deeper" deny
assert_decision "system subtree" "rm -rf /System/Library" deny
assert_decision "system traversal" "rm -rf /tmp/../etc" deny
assert_decision "physical parent enters system tree" "rm -rf $SCRATCH/system-parent/ssh" deny

# Flag spelling and order are recognized, including direct sudo forms.
assert_decision "combined reversed flags" "rm -fr /etc" deny
assert_decision "separate flags" "rm -r -f /etc" deny
assert_decision "reversed separate flags" "rm -f -r /etc" deny
assert_decision "long flags" "rm --recursive --force /etc" deny
assert_decision "reversed long flags" "rm --force --recursive /etc" deny
assert_decision "sudo rm" "sudo rm -Rf /etc" deny
assert_decision "quoted sudo" "'sudo' 'rm' '-Rf' /etc" deny
assert_decision "absolute rm executable" "/bin/rm -rf /etc" deny
assert_decision "quoted rm executable" '"rm" -rf /etc' deny
assert_decision "whole quoted flags" "rm '-rf' /etc" deny
assert_decision "partially quoted flags" 'rm -"r"f /etc' deny
assert_decision "separately quoted flags" "rm '-r' '-f' /etc" deny
assert_decision "quoted long flags" "rm '--recursive' '--force' /etc" deny
assert_decision "partially quoted long flags" 'rm --recurs"ive" --for"ce" /etc' deny
assert_decision "escaped flag letters" 'rm -\r\f /etc' deny
assert_decision "quoted absolute executable" "'/bin/rm' -rf /etc" deny
assert_decision "option separator" "rm '-rf' '--' /etc" deny

# Confirmable targets pass this hook and remain governed by chat/rules policy.
assert_decision "repository root" "rm -rf $SCRATCH/repo" pass
assert_decision "sibling project" "rm -rf $SIBLING" pass
assert_decision "home descendant" 'rm -rf ~/.codex-critical-rm-test' pass
assert_decision "ssh home descendant" 'rm -rf ~/.ssh' pass
assert_decision "tmp root" "rm -rf /tmp" pass
assert_decision "private tmp descendant" "rm -rf /private/tmp/work" pass
assert_decision "var tmp descendant" "rm -rf /var/tmp/work" pass
assert_decision "final symlink is not followed" "rm -rf $SCRATCH/final-link" pass
assert_decision "trailing slash follows final symlink" "rm -rf $SCRATCH/final-link/" deny
assert_decision "final dot follows final symlink" "rm -rf $SCRATCH/final-link/." deny
assert_decision "repeated slash follows final symlink" "rm -rf $SCRATCH/final-link//" deny
assert_decision "relative trailing slash follows final symlink" "rm -rf ../final-link/" deny
assert_decision "relative final dot follows final symlink" "rm -rf relative-link/." deny
assert_decision "intermediate symlink is followed" "rm -rf $SCRATCH/system-parent/ssh" deny
assert_decision "trailing link into tmp stays exempt" "rm -rf $SCRATCH/tmp-link/" pass
assert_decision "trailing link into home descendant stays exempt" "rm -rf $SCRATCH/home-descendant-link/" pass
assert_decision "plain broken symlink is not followed" "rm -rf $SCRATCH/broken-link" pass
assert_decision "trailing broken symlink fails closed" "rm -rf $SCRATCH/broken-link/" deny
assert_decision "dynamic target" 'rm -rf $TARGET' pass
assert_decision "dynamic option word" 'rm -$FLAGS /etc' pass
assert_decision "expansion-bearing option word" 'rm -r${FLAGS}f /etc' pass
assert_decision "command substitution" 'rm -rf "$(target)"' pass
assert_decision "glob target" 'rm -rf /etc/*' pass
assert_decision "empty operand" 'rm -rf ""' pass

# Missing either destructive flag is outside this hook's responsibility.
assert_decision "recursive only" "rm -r /etc" pass
assert_decision "force only" "rm -f /etc" pass
assert_decision "ordinary rm" "rm /etc/example" pass

# Raw dangerous-looking text is not an invocation.
assert_decision "quoted force push" "printf '%s' 'git push --force origin main'" pass
assert_decision "quoted rm" "printf '%s' 'rm -rf /'" pass
assert_decision "quoted SQL" "printf '%s' 'DROP TABLE users'" pass
assert_decision "quoted publish" "printf '%s' 'pnpm publish'" pass
assert_decision "execpolicy diagnostic" "codex execpolicy check --pretty 'rm -rf /'" pass
assert_decision "search argument" "rg -n 'rm -rf /' docs tests" pass
assert_decision "env source and redirect" "source .env.e2e && pnpm e2e 2>&1" pass

# Direct invocations are still found after unquoted compound separators.
assert_decision "compound critical rm" "printf done && rm -rf /etc" deny

# Parser, dependency, serialization, and candidate-resolution errors fail closed.
valid_input=$(jq -cn --arg command 'rm -rf /etc' --arg cwd "$SCRATCH/repo" \
  '{cwd:$cwd,tool_input:{command:$command,workdir:$cwd}}')
invalid_workdir_input=$(jq -cn --arg command 'rm -rf relative-target' --arg cwd "$SCRATCH/repo" \
  '{cwd:$cwd,tool_input:{command:$command,workdir:"/does/not/exist"}}')
unterminated_command='rm -rf "/etc'
assert_raw_decision "malformed JSON" '{bad' deny
assert_raw_decision "non-string command" '{"tool_input":{"command":42}}' deny
assert_raw_decision "unterminated quote" \
  "$(jq -cn --arg command "$unterminated_command" --arg cwd "$SCRATCH/repo" '{cwd:$cwd,tool_input:{command:$command,workdir:$cwd}}')" deny
assert_raw_decision "missing jq" "$valid_input" deny "$SCRATCH/no-jq"
assert_raw_decision "failing jq" "$valid_input" deny "$SCRATCH/failing-jq:/bin:/usr/bin"
assert_raw_decision "denial serialization failure" "$valid_input" deny "$SCRATCH/serialize-jq:/bin:/usr/bin"
assert_raw_decision "invalid workdir candidate resolution" "$invalid_workdir_input" deny
assert_raw_decision "failed home resolution" "$valid_input" deny "$PATH" "$SCRATCH/missing-home"

echo "critical rm: $PASS checks passed"
