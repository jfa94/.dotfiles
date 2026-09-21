#!/usr/bin/env bash
# Tests for cloud-setup.sh: syntax, sandboxed happy path (symlinks and plugin
# install calls), and degraded run (missing tools/network -> still exit 0).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/cloud-setup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- static checks ----------------------------------------------------------

bash -n "$SCRIPT" || fail "bash -n"
if command -v shellcheck &>/dev/null; then
  shellcheck "$SCRIPT" || fail "shellcheck"
fi

# --- fixture: fake HOME with a committed dotfiles repo ----------------------

home="$tmp/home"
dot="$home/.dotfiles"
mkdir -p "$dot/.claude/hooks" "$dot/.codex/skills/demo" "$dot/instructions"
cat > "$dot/.claude/settings.json" <<'EOF'
{
  "extraKnownMarketplaces": {
    "acme": {"source": {"source": "github", "repo": "acme/mp"}}
  },
  "enabledPlugins": {
    "good@acme": true,
    "disabled@acme": false
  }
}
EOF
echo '# shared rules' > "$dot/instructions/AGENTS.md"
echo 'echo hook' > "$dot/.claude/hooks/sample.sh"
echo 'model = "gpt-5"' > "$dot/.codex/user-config.toml"
echo '{"hooks": {}}' > "$dot/.codex/user-hooks.json"
echo 'skill' > "$dot/.codex/skills/demo/SKILL.md"
git -C "$dot" init -q
git -C "$dot" -c user.email=t@t -c user.name=t add -A
git -C "$dot" -c user.email=t@t -c user.name=t commit -qm fixture

# --- stubs: pretend tools are preinstalled, network is dead -----------------

stubs="$tmp/stubs"
mkdir -p "$stubs"
for t in pnpm supabase trufflehog uv semgrep codex node gh perl npm; do
  printf '#!/bin/bash\nexit 0\n' > "$stubs/$t"
done
printf '#!/bin/bash\nexit 0\n' > "$stubs/apt-get"
printf '#!/bin/bash\nexit 1\n' > "$stubs/curl"
# claude stub records its invocations
# shellcheck disable=SC2016  # stub body must expand when the stub runs
printf '#!/bin/bash\necho "$@" >> "$CLAUDE_LOG"\n' > "$stubs/claude"
chmod +x "$stubs"/*

run_setup() {
  HOME="$home" PATH="$stubs:$PATH" CLAUDE_LOG="$tmp/claude.log" \
    CLOUD_SETUP_LOG="$tmp/setup.log" bash "$SCRIPT"
}

# --- happy path -------------------------------------------------------------

out="$(run_setup 2>&1)" \
  || fail "happy path exited nonzero"

[[ -L "$home/.claude/CLAUDE.md" ]] || fail "CLAUDE.md not symlinked"
[[ "$(readlink "$home/.claude/CLAUDE.md")" == "$dot/instructions/AGENTS.md" ]] \
  || fail "CLAUDE.md symlink target wrong"
[[ "$(readlink "$home/.codex/AGENTS.md")" == "$dot/instructions/AGENTS.md" ]] \
  || fail "AGENTS.md symlink target wrong"
[[ -L "$home/.codex/config.toml" ]] || fail "user-config.toml not linked as config.toml"
[[ -L "$home/.codex/hooks.json" ]] || fail "user-hooks.json not linked as hooks.json"
[[ "$(readlink "$home/.codex/hooks.json")" == "$dot/.codex/user-hooks.json" ]] \
  || fail "hooks.json symlink target wrong"
[[ ! -e "$home/.codex/skills/demo/SKILL.md" ]] || fail ".codex/skills should be excluded"
[[ ! -e "$home/.codex/user-config.toml" ]] || fail "user-config.toml should only exist as config.toml"
[[ ! -e "$home/.codex/user-hooks.json" ]] || fail "user-hooks.json should only exist as hooks.json"
[[ -x "$home/.claude/hooks/sample.sh" ]] || fail "hook not chmod +x"

[[ ! -e "$home/.claude.json" ]] || fail "setup wrote an unscoped user MCP config"

grep -q 'plugin marketplace add anthropics/claude-plugins-official' "$tmp/claude.log" \
  || fail "official marketplace not added"
grep -q 'plugin marketplace add acme/mp' "$tmp/claude.log" || fail "marketplace not added"
grep -q 'github:acme/mp' "$tmp/claude.log" && fail "github: prefix rejected by CLI, must be plain owner/repo"
grep -q 'plugin install good@acme --scope user' "$tmp/claude.log" || fail "enabled plugin not installed"
grep -q 'disabled@acme' "$tmp/claude.log" && fail "disabled plugin should be skipped"
grep -q 'cloud-setup finished clean' <<< "$out" || fail "expected clean summary, got: $out"

# --- setup preserves an existing ~/.claude.json -----------------------------

echo '{"existing": true}' > "$home/.claude.json"
run_setup >/dev/null 2>&1 || fail "second run exited nonzero"
jq -e '.existing == true' "$home/.claude.json" >/dev/null || fail "existing keys clobbered"

# Migrate old instruction links and prune only retired managed stack links.
for path in .claude/CLAUDE.md .codex/AGENTS.md; do
  ln -sfn "$dot/$path" "$home/$path"
done
for name in frontend.md backend.md; do
  ln -s "$dot/.claude/$name" "$home/.claude/$name"
done
ln -s "$tmp/unrelated" "$home/.claude/custom-link"
echo custom > "$home/.claude/custom-file"
run_setup >/dev/null 2>&1 || fail 'migration exited nonzero'
for path in .claude/CLAUDE.md .codex/AGENTS.md; do
  [[ "$(readlink "$home/$path")" == "$dot/instructions/AGENTS.md" ]] || fail 'legacy link not migrated'
done
for name in frontend.md backend.md; do
  [[ ! -L "$home/.claude/$name" ]] || fail 'retired stack link not pruned'
done
[[ -L "$home/.claude/custom-link" ]] || fail 'unrelated link pruned'
[[ $(cat "$home/.claude/custom-file") == custom ]] || fail 'custom file changed'
echo custom > "$home/.claude/frontend.md"
ln -s "$tmp/unrelated" "$home/.claude/backend.md"
run_setup >/dev/null 2>&1 || fail 'custom stack guidance run failed'
[[ $(cat "$home/.claude/frontend.md") == custom ]] || fail 'custom frontend guidance pruned'
[[ $(readlink "$home/.claude/backend.md") == "$tmp/unrelated" ]] || fail 'custom backend guidance pruned'

# Missing source preserves destinations and reports degraded setup.
mv "$dot/instructions/AGENTS.md" "$dot/instructions/saved.md"
out="$(run_setup 2>&1)" || fail 'missing source changed zero-exit contract'
grep -q 'global agent instructions source not found' <<< "$out" || fail 'missing source not reported'
grep -q 'issue(s)' <<< "$out" || fail 'missing source absent from summary'
[[ "$(readlink "$home/.claude/CLAUDE.md")" == "$dot/instructions/AGENTS.md" ]] || fail 'missing source changed link'
mv "$dot/instructions/saved.md" "$dot/instructions/AGENTS.md"

# A directory must not receive an accidental nested AGENTS.md symlink.
rm "$home/.codex/AGENTS.md"
mkdir "$home/.codex/AGENTS.md"
out="$(run_setup 2>&1)" || fail 'directory conflict changed zero-exit contract'
grep -q 'global agent instructions destination is a directory' <<< "$out" || fail 'directory conflict not reported'
[[ ! -e "$home/.codex/AGENTS.md/AGENTS.md" ]] || fail 'link created inside directory'
rmdir "$home/.codex/AGENTS.md"

# A failed link is named in the summary while the other link still succeeds.
real_ln=$(command -v ln)
cat > "$stubs/ln" <<'STUB'
#!/bin/bash
if [[ "$*" == *".codex/AGENTS.md" ]]; then exit 1; fi
exec "$REAL_LN" "$@"
STUB
chmod +x "$stubs/ln"
out="$(REAL_LN="$real_ln" run_setup 2>&1)" || fail 'link failure changed zero-exit contract'
grep -q 'global agent instructions link failed' <<< "$out" || fail 'link failure not reported'
grep -q 'issue(s)' <<< "$out" || fail 'link failure absent from summary'
rm "$stubs/ln"
run_setup >/dev/null 2>&1 || fail 'recovery failed'
[[ -f "$home/.codex/AGENTS.md" ]] || fail 'recovery did not restore link'

# --- degraded: tools missing + network dead -> reports issues, exits 0 ------
# restricted PATH so the host's real CLIs can't satisfy the command -v guards

realbin="$tmp/realbin"
mkdir -p "$realbin"
for c in bash sh git jq ln readlink mkdir dirname basename find chmod uname whoami env \
         mv rm cat grep sed timeout printf echo tee mktemp; do
  p="$(command -v "$c" 2>/dev/null)" || continue
  [[ "$p" == /* ]] && ln -s "$p" "$realbin/$c"
done

for t in supabase trufflehog uv semgrep codex claude; do rm "$stubs/$t"; done
out="$(HOME="$home" PATH="$stubs:$realbin" CLAUDE_LOG="$tmp/claude.log" \
  CLOUD_SETUP_LOG="$tmp/setup-degraded.log" bash "$SCRIPT" 2>&1)" \
  || fail "degraded run exited nonzero"
grep -q 'issue(s)' <<< "$out" || fail "degraded run should report issues"
grep -q 'supabase CLI install failed' <<< "$out" || fail "vacuous curl not caught (supabase)"
grep -q 'codex CLI install failed' <<< "$out" || fail "vacuous curl not caught (codex)"
grep -Eq 'failed|not found' "$tmp/setup-degraded.log" \
  || fail "failures not mirrored to log file"

echo 'PASS: cloud-setup tests'
