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

# Capital -R is recursive too.
assert_claude "capital R home" 'rm -Rf ~' deny
assert_claude "capital R after f" 'rm -fR $HOME/x' deny
assert_claude "capital R outside repo" "rm -Rf /etc/foo" deny

# Bundled short flags and abbreviated long options are policy denies.
assert_claude "commit -nm" "git commit -nm x" deny
assert_claude "commit -anm" "git commit -anm x" deny
assert_claude "commit --no-veri" "git commit -am x --no-veri" deny
assert_claude "commit --no-gp" "git commit --no-gp -m x" deny
assert_claude "push -fu" "git push -fu origin main" deny
assert_claude "push -fu with -C" "git -C . push -fu" deny
assert_claude "rebase --no-veri" "git rebase --no-veri main" deny
assert_claude "push -f after continuation" $'git push origin x \\\n -f' deny
assert_claude "push --follow-tags" "git push --follow-tags" pass
assert_claude "push -u" "git push -u origin x" pass
assert_claude "commit --amend --no-edit" "git commit --amend --no-edit" pass
assert_claude "plain commit" "git commit -m x" pass
assert_claude "later segment -lf" "git push origin x && ls -lf" pass

# Options that execute arbitrary programs.
assert_claude "rebase -x" "git rebase -x 'sh' main" deny
assert_claude "rebase -ix" "git rebase -ix sh main" deny
assert_claude "rebase --exec" "git rebase --exec=sh main" deny
assert_claude "rebase --ex" "git -C . rebase --ex=sh" deny
assert_claude "fetch --upload-pack" "git fetch --upload-pack=sh origin" deny
assert_claude "fetch --upl" "git -C . fetch --upl=sh" deny
assert_claude "ls-remote --u" "git ls-remote --u=sh origin" deny
assert_claude "push --receive-pack" "git push --receive-pack=sh origin" deny
assert_claude "ls-remote --exe" "git ls-remote --exe=sh origin" deny
assert_claude "ls-remote --exec" "git ls-remote --exec=sh origin" deny
assert_claude "-C ls-remote --exec" "git -C /x ls-remote --exec=sh origin" deny
assert_claude "ls-remote --exit-code" "git ls-remote --exit-code origin main" pass
assert_claude "push --mirror" "git push --mirror origin" deny
assert_claude "push --m" "git push --m origin" deny
assert_claude "push trailing --mirror" "git push origin --mirror" deny
assert_claude "-C push --mirror" "git -C /x push --mirror origin" deny
assert_claude "-c push --mirror" "git -c advice.x=1 push --mirror origin" deny
assert_claude "--no-pager push --force" "git --no-pager push --force origin" deny
assert_claude "double-space push -f" "git  push -f origin" deny
assert_claude "--git-dir commit --no-verify" "git --git-dir /x/.git commit --no-verify -m x" deny
assert_claude "-c log mentioning push" "git -c core.pager=cat log --oneline push --mirror-ish" pass
# Longer than a pipe buffer: an early match must not be lost to SIGPIPE.
assert_claude "push --mirror before many lines" "git push --mirror origin
$(seq 1 30000)" deny
assert_claude "push --rece" "git push --rece=sh origin" deny
assert_claude "push --exec" "git -C . push --e=sh origin" deny
assert_claude "rebase -X strategy" "git rebase -X theirs main" pass
assert_claude "rebase --no-exec" "git rebase --no-exec main" pass

echo "dangerous patterns: $PASS checks passed"
