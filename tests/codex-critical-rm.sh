#!/usr/bin/env bash
# shellcheck disable=SC2016 # Command fixtures intentionally contain expansions.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.codex/hooks/critical-rm-check.sh"
PASS=0
SCRATCH=$(mktemp -d)
SIBLING=$(mktemp -d)
trap 'rm -rf "$SCRATCH" "$SIBLING"' EXIT

mkdir -p "$SCRATCH/repo/sub" "$SCRATCH/tmp"
ln -s /etc "$SCRATCH/final-link"
ln -s /etc "$SCRATCH/system-parent"

decision_for() {
  local command=$1 workdir=${2:-$SCRATCH/repo} output
  output=$(HOME="$HOME" bash "$HOOK" <<< "$(
    jq -cn --arg command "$command" --arg cwd "$workdir" \
      '{cwd:$cwd,tool_input:{command:$command,workdir:$cwd}}'
  )")
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"'
  else
    printf 'pass\n'
  fi
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
assert_decision "absolute rm executable" "/bin/rm -rf /etc" deny
assert_decision "quoted rm executable" '"rm" -rf /etc' deny

# Confirmable targets pass this hook and remain governed by chat/rules policy.
assert_decision "repository root" "rm -rf $SCRATCH/repo" pass
assert_decision "sibling project" "rm -rf $SIBLING" pass
assert_decision "home descendant" 'rm -rf ~/.codex-critical-rm-test' pass
assert_decision "ssh home descendant" 'rm -rf ~/.ssh' pass
assert_decision "tmp root" "rm -rf /tmp" pass
assert_decision "private tmp descendant" "rm -rf /private/tmp/work" pass
assert_decision "var tmp descendant" "rm -rf /var/tmp/work" pass
assert_decision "final symlink is not followed" "rm -rf $SCRATCH/final-link" pass
assert_decision "dynamic target" 'rm -rf $TARGET' pass
assert_decision "command substitution" 'rm -rf "$(target)"' pass
assert_decision "glob target" 'rm -rf /etc/*' pass

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

echo "dangerous patterns: $PASS checks passed"
