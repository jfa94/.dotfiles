# Set up a Claude Code cloud environment

Background and behavior: [cloud environments reference](../reference/cloud-environments.md).

## One-time account steps

- **ChatGPT** → Settings → Security → enable **Allow device code login**
  (needed for `codex login --device-auth`).
- Optional: add the hosted AWS MCP connector on claude.ai
  (`https://aws-mcp.eu-central-1.api.aws/mcp`). Single-account only — AWS
  OAuth can't multi-account and claude.ai rejects duplicate connector URLs.

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
   verifying their project binding. For project variables, set the two inputs
   described in [Project variables from 1Password](../reference/cloud-environments.md#project-variables-from-1password):
   `OP_SERVICE_ACCOUNT_TOKEN` and `OP_ENVIRONMENT_ID`. Never paste provider
   tokens directly.

   1. In 1Password → Developer → Environments, keep the project's variables in one Environment.
   2. Create a service account with read access to that Environment only. Access is fixed when the account is created.
   3. Copy the ID from Developer → View Environments → Manage environment → Copy environment ID.

3. **Network access** — Trusted covers everything except Codex. For Codex,
   switch to Custom and allow at least: `chatgpt.com`, `auth.openai.com`,
   `releases.openai.com` (codex binary host — without it the installer falls
   back to rate-limited api.github.com and 403s), `raw.githubusercontent.com`,
   `astral.sh`, `claude.ai`, `mcp.supabase.com`, `api.supabase.com`,
   `github.com`, `release-assets.githubusercontent.com`,
   `objects.githubusercontent.com`. Every Custom environment also needs
   `registry.npmjs.org` at build time (the 1Password SDK install; without it each
   build reports one setup issue) and the account's 1Password host
   (`my.1password.com` for this account) for the session read.

To stop loading project variables, remove both inputs; sessions created afterwards no longer load them.

## Per-session ritual

- Codex-backed skills (`/focused-code-review`, etc.): run
  `codex login --device-auth` first — ~30s, opens a URL + code you approve on
  your own machine. Repeats every session (fresh VM).

## Verification checklist (first session after changes)

0. `cat /tmp/cloud-setup.log` — full build output, per-plugin install results,
   `claude plugin list` ground truth, and the failure summary.
1. `ls -la ~/.claude` shows symlinks into `~/.dotfiles`; Claude quotes a
   rule from `instructions/AGENTS.md`; skills appear under `/`; `/plugin` lists superpowers,
   factory, ponytail, codex, web-designer.
2. Hooks fire: `npm install x` → denied with a `pnpm install x` suggestion; no model-lock warning.
3. `/mcp` shows only project-bound Supabase/PostHog connectors (PostHog as one
   `posthog` server, full catalogue); `mcp__supabase__list_projects` and
   `mcp__posthog__exec` allowed silently. Supabase is project-scoped and
   read-only. Claude's own SQL hook remains separate; Codex mutations require
   current-turn confirmation and use the CLI route.
4. Tool sweep (`gh` intentionally absent — GitHub via MCP):
   `for t in jq perl pnpm trufflehog semgrep supabase uvx shellcheck node codex; do command -v $t || echo MISSING $t; done`
5. `codex login --device-auth` end-to-end, then a codex-backed review skill.
6. With the 1Password inputs set: the session opens with "Loaded N project
   variables from 1Password." in its context, and each expected variable is
   present: `[ -n "${NAME:-}" ] && echo "NAME set"`. Check presence only; never print values.
