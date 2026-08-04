#!/usr/bin/env bash
# Tests for cloud-setup.sh: syntax, sandboxed happy path (symlinks, MCP merge,
# plugin install calls), and degraded run (missing tools/network -> still exit 0).
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
mkdir -p "$dot/.claude/hooks" "$dot/.codex/skills/demo"
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
echo '# claude rules' > "$dot/.claude/CLAUDE.md"
echo 'echo hook' > "$dot/.claude/hooks/sample.sh"
echo 'model = "gpt-5"' > "$dot/.codex/user-config.toml"
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
    CLOUD_SETUP_LOG="$tmp/setup.log" "$@" bash "$SCRIPT"
}

# --- happy path -------------------------------------------------------------

out="$(run_setup env SUPABASE_ACCESS_TOKEN=tok SUPABASE_PROJECT_REF=abc123 2>&1)" \
  || fail "happy path exited nonzero"

[[ -L "$home/.claude/CLAUDE.md" ]] || fail "CLAUDE.md not symlinked"
[[ "$(readlink "$home/.claude/CLAUDE.md")" == "$dot/.claude/CLAUDE.md" ]] \
  || fail "CLAUDE.md symlink target wrong"
[[ -L "$home/.codex/config.toml" ]] || fail "user-config.toml not linked as config.toml"
[[ ! -e "$home/.codex/skills/demo/SKILL.md" ]] || fail ".codex/skills should be excluded"
[[ ! -e "$home/.codex/user-config.toml" ]] || fail "user-config.toml should only exist as config.toml"
[[ -x "$home/.claude/hooks/sample.sh" ]] || fail "hook not chmod +x"

jq -e '.mcpServers.supabase.url == "https://mcp.supabase.com/mcp?project_ref=abc123"' \
  "$home/.claude.json" >/dev/null || fail "MCP url missing project_ref"
jq -e '.mcpServers.supabase.headersHelper | contains("SUPABASE_MCP_TOKEN:-$SUPABASE_ACCESS_TOKEN")' \
  "$home/.claude.json" >/dev/null || fail "headersHelper wrong"

grep -q 'plugin marketplace add github:acme/mp' "$tmp/claude.log" || fail "marketplace not added"
grep -q 'plugin install good@acme --scope user' "$tmp/claude.log" || fail "enabled plugin not installed"
grep -q 'disabled@acme' "$tmp/claude.log" && fail "disabled plugin should be skipped"
grep -q 'cloud-setup finished clean' <<< "$out" || fail "expected clean summary, got: $out"

# --- MCP merge preserves an existing ~/.claude.json, no project ref ---------

echo '{"existing": true}' > "$home/.claude.json"
run_setup env SUPABASE_ACCESS_TOKEN=tok >/dev/null 2>&1 || fail "second run exited nonzero"
jq -e '.existing == true' "$home/.claude.json" >/dev/null || fail "existing keys clobbered"
jq -e '.mcpServers.supabase.url == "https://mcp.supabase.com/mcp"' \
  "$home/.claude.json" >/dev/null || fail "MCP url without project_ref wrong"

# --- no token: MCP still written (env vars only reach the session, not setup)

rm -f "$home/.claude.json"
run_setup >/dev/null 2>&1 || fail "no-token run exited nonzero"
jq -e '.mcpServers.supabase.url == "https://mcp.supabase.com/mcp"' \
  "$home/.claude.json" >/dev/null || fail "MCP not written without token"

# --- degraded: tools missing + network dead -> reports issues, exits 0 ------
# restricted PATH so the host's real CLIs can't satisfy the command -v guards

realbin="$tmp/realbin"
mkdir -p "$realbin"
for c in bash sh git jq ln mkdir dirname basename find chmod uname whoami env \
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
grep -q 'issue(s)' "$tmp/setup-degraded.log" || fail "failures not mirrored to log file"

echo 'PASS: cloud-setup tests'
