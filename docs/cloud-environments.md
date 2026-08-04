# Claude Code Cloud Environments

Replicates the local Claude Code workflow (CLAUDE.md, skills, hooks, plugins,
permission rules, Codex/Supabase toolchain) on claude.ai/code cloud VMs.

## How it works

Cloud environments run a per-environment setup script as root once per build
(cached ~7 days), **before** Claude Code launches. `cloud-setup.sh` clones this
repo and recreates `~/.claude` + `~/.codex` via symlinks — same mechanism as
`setup.sh` locally — then installs CLIs and plugins.

Key facts (spike-verified 2026-08):

- Build and session both run as root with `HOME=/root`; a `~/.claude` created
  at build time is fully honored (CLAUDE.md, skills, hooks, settings).
- The session harness sets `SKIP_PLUGIN_MARKETPLACE=true`, so plugins **must**
  be installed at build time — session-start auto-install never happens.
- The session repo checkout (`/home/user/<repo>`) is separate from
  `/root/.dotfiles`; the dotfiles clone is config-delivery only.
- Fresh VM per session: nothing persists mid-session → Codex auth repeats per
  session; env vars are the only durable per-environment state.
- Preinstalled: node, npm, pnpm, uvx, gh (auth injected via proxy), git, jq.

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

2. **Environment variables** — this is where per-account/per-project scoping
   happens (one environment per project, each with its own tokens):

   | Variable | Required | Purpose |
   |----------------------|----------|--------------------------------------------------|
   | `SUPABASE_ACCESS_TOKEN` | yes* | Scoped PAT for the right Supabase account; auths the CLI and (fallback) the MCP |
   | `SUPABASE_MCP_TOKEN` | no | Separate token for the MCP server, if you want it distinct from the CLI's |
   | `SUPABASE_PROJECT_REF` | no | Scopes the MCP to one project via `?project_ref=` |

   *Omit both tokens and the Supabase MCP/CLI are simply skipped.

3. **Network access** — Trusted. If the build log shows blocked installs,
   switch to Custom and allow: `raw.githubusercontent.com`, `astral.sh`,
   `chatgpt.com`, `claude.ai`, `mcp.supabase.com`, `api.supabase.com`,
   `github.com`, plus the supabase/trufflehog GitHub release hosts
   (`objects.githubusercontent.com`).

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
- **macOS Keychain secrecy** — the Supabase PAT sits in env config,
  agent-visible; mitigated by token scoping.

## Verification checklist (first session after changes)

1. `ls -la ~/.claude` shows symlinks into `~/.dotfiles`; Claude quotes a
   CLAUDE.md rule; skills appear under `/`; `/plugin` lists superpowers,
   factory, ponytail, codex, web-designer.
2. Hooks fire: `npm install x` → pnpm rewrite; no model-lock warning.
3. `supabase projects list` works; `/mcp` shows supabase connected;
   `mcp__supabase__list_projects` allowed silently; `execute_sql` gated by
   `sql-readonly-check.sh`.
4. Tool sweep:
   `for t in jq perl pnpm trufflehog semgrep supabase uvx shellcheck node gh codex; do command -v $t || echo MISSING $t; done`
5. `codex login --device-auth` end-to-end, then a codex-backed review skill.

## Maintenance

- `cloud-setup.sh` carries `# keep in sync with setup.sh <function>` markers —
  when those setup.sh functions change, update the cloud copies.
- Env cache is ~7 days: config changes land on next rebuild, or force one by
  editing the environment's setup script (any whitespace change).
- `tests/cloud-setup.sh` covers syntax, degraded-install behavior, symlinks,
  and the MCP jq-merge.
