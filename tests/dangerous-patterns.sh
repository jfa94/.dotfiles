#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLAUDE_HOOK="$ROOT/.claude/hooks/dangerous-patterns-check.sh"
CODEX_HOOK="$ROOT/.codex/hooks/dangerous-patterns-check.sh"
PASS=0

SCRATCH=$(mktemp -d)
TMP_LINK_ROOT=$(mktemp -d /tmp/dangerous-patterns.XXXXXX)
trap 'rm -rf "$SCRATCH" "$TMP_LINK_ROOT"' EXIT

git -C "$SCRATCH" init -q
git -C "$SCRATCH" config user.email test@example.com
git -C "$SCRATCH" config user.name test
cat > "$SCRATCH/.gitignore" <<'EOF'
coverage/
dist/
node_modules/
.cache/
.venv/
target/
tmp/
.pytest_cache/
.env
state.db
EOF
mkdir -p \
  "$SCRATCH/src" \
  "$SCRATCH/dist" \
  "$SCRATCH/coverage" \
  "$SCRATCH/node_modules" \
  "$SCRATCH/.cache" \
  "$SCRATCH/.venv" \
  "$SCRATCH/target" \
  "$SCRATCH/tmp" \
  "$SCRATCH/.pytest_cache" \
  "$SCRATCH/packages/core/dist"
touch "$SCRATCH/src/index.ts" "$SCRATCH/dist/tracked.js"
git -C "$SCRATCH" add .gitignore src/index.ts
git -C "$SCRATCH" add -f dist/tracked.js
git -C "$SCRATCH" commit -q -m init
ln -s /etc "$TMP_LINK_ROOT/link"

decision_for() {
  local runtime=$1 command=$2 workdir=$3 cwd=$4 hook output status
  if [[ "$runtime" = claude ]]; then
    hook=$CLAUDE_HOOK
  else
    hook=$CODEX_HOOK
  fi
  if output=$(HOME="$HOME" "$hook" <<< "$(
      jq -cn --arg command "$command" --arg cwd "$cwd" --arg workdir "$workdir" \
        '{cwd:$cwd,tool_input:{command:$command,workdir:$workdir}}'
    )"); then
    :
  else
    status=$?
    echo "FAIL $runtime hook exited with status $status" >&2
    echo "  command: $command" >&2
    exit 1
  fi
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"'
  else
    printf 'pass\n'
  fi
}

assert_pair() {
  local name=$1 command=$2 claude_expected=$3 codex_expected=$4
  local workdir=${5:-$SCRATCH} cwd=${6:-$SCRATCH} runtime expected actual
  for runtime in claude codex; do
    if [[ "$runtime" = claude ]]; then
      expected=$claude_expected
    else
      expected=$codex_expected
    fi
    actual=$(decision_for "$runtime" "$command" "$workdir" "$cwd")
    [[ "$actual" = "$expected" ]] || {
      echo "FAIL $runtime / $name: expected $expected, got $actual" >&2
      echo "  command: $command" >&2
      exit 1
    }
    PASS=$((PASS + 1))
  done
}

# Ordinary commands pass through after tmp-root initialization without output.
assert_pair "ordinary command" "printf hello" pass pass

# Exact named artifacts are allowed only when Git also classifies them ignored.
assert_pair "ignored artifact" "rm -rf coverage" allow pass
assert_pair "dot-relative artifact" "rm -rf ./coverage" allow pass
assert_pair "non-recursive artifact" "rm -f coverage" allow pass
assert_pair "nested artifact segment" "rm -rf packages/core/dist" allow pass
assert_pair "absolute in-repo artifact" "rm -rf $SCRATCH/coverage" allow pass
assert_pair "multiple ignored artifacts" "rm -rf coverage node_modules" allow pass
assert_pair "double-quoted literal" 'rm -rf "coverage"' allow pass
assert_pair "option separator" "rm -rf -- coverage" allow pass
assert_pair "tab-separated command" $'rm\t-rf\tcoverage' allow pass
for artifact in node_modules .venv target tmp .pytest_cache; do
  assert_pair "additional artifact $artifact" "rm -rf $artifact" allow pass
done

# Physical tmp subpaths remain allowed, but the roots themselves do not.
assert_pair "tmp subpath" "rm -rf /tmp/dangerous-patterns-test/work" allow pass
assert_pair "bare tmp" "rm -rf /tmp" deny deny
assert_pair "normalized bare tmp" "rm -rf /tmp/." deny deny
assert_pair "plain final symlink unlinks only the link" "rm -rf $TMP_LINK_ROOT/link" allow pass
assert_pair "trailing slash follows final symlink" "rm -rf $TMP_LINK_ROOT/link/" deny deny
assert_pair "final dot follows final symlink" "rm -rf $TMP_LINK_ROOT/link/." deny deny
assert_pair "symlinked intermediate escapes tmp" "rm -rf $TMP_LINK_ROOT/link/coverage" deny deny

# Neither half of the repository rule is sufficient by itself.
assert_pair "tracked artifact" "rm -rf dist" ask deny
assert_pair "named but unignored" "rm -rf build" ask deny
assert_pair "ignored but unnamed" "rm -rf state.db" ask deny
assert_pair "tracked source" "rm -rf src" ask deny

# Secret-shaped paths never enter the allow tier, even below artifacts.
assert_pair "ignored env file" "rm -rf .env" ask deny
assert_pair "uppercase env below artifact" "rm -rf coverage/.ENV" ask deny
assert_pair "private key below artifact" "rm -rf coverage/key.pem" ask deny

# Non-literal or multi-command shapes retain confirmation or denial behavior.
assert_pair "glob" 'rm -rf coverage/*' ask deny
assert_pair "brace expansion" 'rm -rf coverage/{a,b}' ask deny
assert_pair "safe compound" "rm -rf coverage && rm -rf node_modules" ask deny
assert_pair "compound outside target" "rm -rf coverage && rm -rf /etc" deny deny
assert_pair "multiline command" $'rm -rf coverage\nprintf done' ask deny

# Traversal and every outside/home spelling remain hard denials.
assert_pair "relative traversal" "rm -rf coverage/../src" deny deny
assert_pair "parent traversal" "rm -rf ../../etc" deny deny
assert_pair "outside absolute" "rm -rf /etc" deny deny
assert_pair "quoted outside keeps confirmation fallback" 'rm -rf "/etc"' ask deny
assert_pair "filesystem root" "rm -rf /" deny deny
assert_pair "bare tilde" 'rm -rf ~' deny deny
assert_pair "tilde subpath" 'rm -rf ~/Documents' deny deny
assert_pair "HOME spelling" 'rm -rf $HOME/.worktrees/task-1' deny deny

# Per-command relative workdirs resolve against the payload cwd.
assert_pair "relative workdir" "rm -rf coverage" allow pass \
  "$(basename "$SCRATCH")" "$(dirname "$SCRATCH")"
assert_pair "workdir fallback" "rm -rf coverage" allow pass "" "$SCRATCH"

echo "dangerous patterns: $PASS checks passed"
