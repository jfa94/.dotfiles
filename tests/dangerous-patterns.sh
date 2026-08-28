#!/usr/bin/env bash
# shellcheck disable=SC2016 # Command fixtures intentionally contain expansions.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLAUDE_HOOK="$ROOT/.claude/hooks/dangerous-patterns-check.sh"
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
  local command=$1 workdir=$2 cwd=$3 output status
  if output=$(HOME="$HOME" "$CLAUDE_HOOK" <<< "$(
      jq -cn --arg command "$command" --arg cwd "$cwd" --arg workdir "$workdir" \
        '{cwd:$cwd,tool_input:{command:$command,workdir:$workdir}}'
    )"); then
    :
  else
    status=$?
    echo "FAIL claude hook exited with status $status" >&2
    echo "  command: $command" >&2
    exit 1
  fi
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"'
  else
    printf 'pass\n'
  fi
}

assert_claude() {
  local name=$1 command=$2 claude_expected=$3
  local workdir=${4:-$SCRATCH} cwd=${5:-$SCRATCH} actual
  actual=$(decision_for "$command" "$workdir" "$cwd")
  [[ "$actual" = "$claude_expected" ]] || {
    echo "FAIL claude / $name: expected $claude_expected, got $actual" >&2
    echo "  command: $command" >&2
    exit 1
  }
  PASS=$((PASS + 1))
}

# Ordinary commands pass through after tmp-root initialization without output.
assert_claude "ordinary command" "printf hello" pass

# Exact named artifacts are allowed only when Git also classifies them ignored.
assert_claude "ignored artifact" "rm -rf coverage" allow
assert_claude "dot-relative artifact" "rm -rf ./coverage" allow
assert_claude "non-recursive artifact" "rm -f coverage" allow
assert_claude "nested artifact segment" "rm -rf packages/core/dist" allow
assert_claude "absolute in-repo artifact" "rm -rf $SCRATCH/coverage" allow
assert_claude "multiple ignored artifacts" "rm -rf coverage node_modules" allow
assert_claude "double-quoted literal" 'rm -rf "coverage"' allow
assert_claude "option separator" "rm -rf -- coverage" allow
assert_claude "tab-separated command" $'rm\t-rf\tcoverage' allow
for artifact in node_modules .venv target tmp .pytest_cache; do
  assert_claude "additional artifact $artifact" "rm -rf $artifact" allow
done

# Physical tmp subpaths remain allowed, but the roots themselves do not.
assert_claude "tmp subpath" "rm -rf /tmp/dangerous-patterns-test/work" allow
assert_claude "bare tmp" "rm -rf /tmp" deny
assert_claude "normalized bare tmp" "rm -rf /tmp/." deny
assert_claude "plain final symlink unlinks only the link" "rm -rf $TMP_LINK_ROOT/link" allow
assert_claude "trailing slash follows final symlink" "rm -rf $TMP_LINK_ROOT/link/" deny
assert_claude "final dot follows final symlink" "rm -rf $TMP_LINK_ROOT/link/." deny
assert_claude "symlinked intermediate escapes tmp" "rm -rf $TMP_LINK_ROOT/link/coverage" deny

# Neither half of the repository rule is sufficient by itself.
assert_claude "tracked artifact" "rm -rf dist" ask
assert_claude "named but unignored" "rm -rf build" ask
assert_claude "ignored but unnamed" "rm -rf state.db" ask
assert_claude "tracked source" "rm -rf src" ask

# Secret-shaped paths never enter the allow tier, even below artifacts.
assert_claude "ignored env file" "rm -rf .env" ask
assert_claude "uppercase env below artifact" "rm -rf coverage/.ENV" ask
assert_claude "private key below artifact" "rm -rf coverage/key.pem" ask

# Non-literal or multi-command shapes retain confirmation or denial behavior.
assert_claude "glob" 'rm -rf coverage/*' ask
assert_claude "brace expansion" 'rm -rf coverage/{a,b}' ask
assert_claude "safe compound" "rm -rf coverage && rm -rf node_modules" ask
assert_claude "compound outside target" "rm -rf coverage && rm -rf /etc" deny
assert_claude "multiline command" $'rm -rf coverage\nprintf done' ask

# Traversal and every outside/home spelling remain hard denials.
assert_claude "relative traversal" "rm -rf coverage/../src" deny
assert_claude "parent traversal" "rm -rf ../../etc" deny
assert_claude "outside absolute" "rm -rf /etc" deny
assert_claude "quoted outside keeps confirmation fallback" 'rm -rf "/etc"' ask
assert_claude "filesystem root" "rm -rf /" deny
assert_claude "bare tilde" 'rm -rf ~' deny
assert_claude "tilde subpath" 'rm -rf ~/Documents' deny
assert_claude "HOME spelling" 'rm -rf $HOME/.worktrees/task-1' deny

# Per-command relative workdirs resolve against the payload cwd.
assert_claude "relative workdir" "rm -rf coverage" allow \
  "$(basename "$SCRATCH")" "$(dirname "$SCRATCH")"
assert_claude "workdir fallback" "rm -rf coverage" allow "" "$SCRATCH"

echo "dangerous patterns: $PASS checks passed"
