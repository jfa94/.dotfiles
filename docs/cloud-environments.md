# Claude Code Cloud Environments

Replicates the local Claude Code workflow (CLAUDE.md, skills, hooks, plugins,
permission rules, Codex/Supabase toolchain) on claude.ai/code cloud VMs.

## How it works

Cloud environments run a per-environment setup script as root once per build
(cached ~7 days), **before** Claude Code launches. `cloud-setup.sh` clones this
repo and recreates `~/.claude` + `~/.codex` via symlinks — same mechanism as
`setup.sh` locally — then installs CLIs and plugins.

Codex user configuration is stored in the clone under the non-discovered
source names `.codex/user-config.toml` and `.codex/user-hooks.json`, then linked
to the runtime paths `~/.codex/config.toml` and `~/.codex/hooks.json`. This keeps
the delivery clone from also treating the same files as project-local config.

Claude skills are an exception to the path-for-path file linking. Section 3 of
`cloud-setup.sh` skips every tracked path under `.claude/skills/*/*`, then links
each skill directory containing a `SKILL.md` as one symlink into
`~/.claude/skills/<name>` (mirroring `link_claude_skills` in `setup.sh`). Files
added to a skill after the last setup run therefore appear at runtime without
re-running setup.

Key facts (spike-verified 2026-08):

- Build and session both run as root with `HOME=/root`; a `~/.claude` created
  at build time is fully honored (CLAUDE.md, skills, hooks, settings).
- The session harness sets `SKIP_PLUGIN_MARKETPLACE=true`, so plugins **must**
  be installed at build time — session-start auto-install never happens.
- **Environment UI env vars reach the session only, NOT the setup script.**
  Anything needing a token at build time can't have it; `cloud-setup.sh`
  therefore never writes credentialed MCP entries from setup-time variables.
  Managed connectors or project-native MCP files are authoritative.
- Setup-script stdout is **not persisted** anywhere on the VM — the script
  tees everything to `/tmp/cloud-setup.log`; read that in-session to diagnose
  build failures.
- Anonymous `api.github.com` is rate-limited (403) from shared cloud egress
  IPs — installers that resolve "latest" via the API fail. Direct
  `github.com/.../releases/download/...` URLs work fine, hence the pinned
  supabase version in `cloud-setup.sh`.
- Under Trusted network access, `chatgpt.com` is blocked at the gateway
  (CONNECT 403) → **Codex CLI cannot install** unless the environment uses a
  Custom allowlist including `chatgpt.com` (and `auth.openai.com` for login).
- The session injects its own MCP servers (github, Supabase connector scoped
  to the claude.ai project, PostHog, Google suite) from a per-session config;
  the user-scope `supabase` entry in `~/.claude.json` coexists with these.
- The session repo checkout (`/home/user/<repo>`) is separate from
  `/root/.dotfiles`; the dotfiles clone is config-delivery only.
- Fresh VM per session: nothing persists mid-session → Codex auth repeats per
  session; env vars are the only durable per-environment state.
- Preinstalled: node, npm, pnpm, uvx, git, jq, claude
  (`/opt/node22/bin/claude`). No `gh` — GitHub access goes through the
  session-injected github MCP server instead.
- Sessions reuse the cached env snapshot — a dotfiles push does NOT reach
  cloud sessions until the env rebuilds. Force a rebuild by editing the
  environment config (e.g. bump the cache-bust comment in the shim).
- Hook `systemMessage` output is not rendered by the cloud UI (cosmetic only —
  the npm→pnpm rewrite itself works; verify via `npm --version` printing
  pnpm's version).

## One-time setup per project

On claude.ai → Code → your repo → environment settings:

1. **Setup script** — paste the shim:

   ```bash
   #!/bin/bash
   git clone --depth 1 https://github.com/jfa94/.dotfiles.git "$HOME/.dotfiles" 2>/dev/null \
     || git -C "$HOME/.dotfiles" pull --ff-only || true
   [ -f "$HOME/.dotfiles/cloud-setup.sh" ] && bash "$HOME/.dotfiles/cloud-setup.sh"
   exit 0
   ```

   The shim stays tiny so all real logic lives (and evolves) in this repo.

2. **Environment variables** — prefer managed Supabase/PostHog connectors after
   verifying their project binding. If the image provides `op`, set a
   vault-restricted `OP_SERVICE_ACCOUNT_TOKEN` plus `AGENT_ENV_FILE` for
   project-native 1Password references. Never paste provider tokens directly.

3. **Network access** — Trusted covers everything except Codex. For Codex,
   switch to Custom and allow at least: `chatgpt.com`, `auth.openai.com`,
   `releases.openai.com` (codex binary host — without it the installer falls
   back to rate-limited api.github.com and 403s), `raw.githubusercontent.com`,
   `astral.sh`, `claude.ai`, `mcp.supabase.com`, `api.supabase.com`,
   `github.com`, `release-assets.githubusercontent.com`,
   `objects.githubusercontent.com`.

## One-time account steps

- **ChatGPT** → Settings → Security → enable **Allow device code login**
  (needed for `codex login --device-auth`).
- Optional: add the hosted AWS MCP connector on claude.ai
  (`https://aws-mcp.eu-central-1.api.aws/mcp`). Single-account only — AWS
  OAuth can't multi-account and claude.ai rejects duplicate connector URLs.

## Per-session ritual

- Codex-backed skills (`/focused-code-review`, etc.): run
  `codex login --device-auth` first — ~30s, opens a URL + code you approve on
  your own machine. Repeats every session (fresh VM).

## Deliberately not replicated

- **AWS CLI** — SSO creds last 12–24h; per-session ritual judged not worth it.
  AWS work stays local.
- **claude-in-chrome** — no browser on the VM.
- **Local 1Password injection** — cloud uses managed connectors unless the
  image supplies `op` and a vault-restricted service-account token.

## Verification checklist (first session after changes)

0. `cat /tmp/cloud-setup.log` — full build output, per-plugin install results,
   `claude plugin list` ground truth, and the failure summary.
1. `ls -la ~/.claude` shows symlinks into `~/.dotfiles`; Claude quotes a
   CLAUDE.md rule; skills appear under `/`; `/plugin` lists superpowers,
   factory, ponytail, codex, web-designer.
2. Hooks fire: `npm install x` → pnpm rewrite; no model-lock warning.
3. `/mcp` shows only project-bound Supabase/PostHog connectors (PostHog as two
   servers, `posthog` and `posthog_write`); `mcp__supabase__list_projects` and
   `mcp__posthog__exec` allowed silently; `execute_sql` gated by
   `sql-readonly-check.sh`; `mcp__posthog_write__exec` prompts on every call.
4. Tool sweep (`gh` intentionally absent — GitHub via MCP):
   `for t in jq perl pnpm trufflehog semgrep supabase uvx shellcheck node codex; do command -v $t || echo MISSING $t; done`
5. `codex login --device-auth` end-to-end, then a codex-backed review skill.

## Maintenance

- `cloud-setup.sh` carries `# keep in sync with setup.sh <function>` markers —
  when those setup.sh functions change, update the cloud copies.
- Env cache is ~7 days: config changes land on next rebuild, or force one by
  editing the environment's setup script (any whitespace change).
- `tests/cloud-setup.sh` covers syntax, degraded-install behavior, symlinks,
  and the MCP jq-merge.
