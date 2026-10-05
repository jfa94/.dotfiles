# Claude Code Cloud Environments

Replicates the local Claude Code workflow (shared global instructions, skills, hooks, plugins,
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

Global instructions are authored once in `instructions/AGENTS.md` and linked to
both `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. Frontend/backend guidance
stays alongside the canonical file and is referenced on demand. Repeat setup
replaces legacy instruction links and removes only dangling stack-guidance links
owned by the old setup. Missing sources, destination directories, and failed
instruction links are reported in the failure summary; cloud setup still exits 0.

Claude skills are an exception to the path-for-path file linking. Section 3 of
`cloud-setup.sh` skips every tracked path under `.claude/skills/*/*`, then links
each skill directory containing a `SKILL.md` as one symlink into
`~/.claude/skills/<name>` (mirroring `link_claude_skills` in `setup.sh`). Files
added to a skill after the last setup run therefore appear at runtime without
re-running setup.

Key facts (spike-verified 2026-08):

- Build and session both run as root with `HOME=/root`; a `~/.claude` created
  at build time is fully honored (CLAUDE.md, skills, hooks, settings).
  Re-checked 2026-10-05 on Claude Code 2.1.289 despite Anthropic's docs saying
  cloud sessions run hooks only from the repo and server-managed settings:
  user-level hooks run (`npm install x` is denied) and a plugin SessionStart hook's
  `CLAUDE_ENV_FILE` export reaches Bash.
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
  to the claude.ai project, PostHog, Google suite) from a per-session config.
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
- Hook `systemMessage` output is not rendered by the cloud UI (cosmetic only).
  The npm→pnpm hook denies `npm`/`npx` and suggests the pnpm command; verify by
  running `npm install x` and checking the deny reason.

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
   described in [Project variables from 1Password](#project-variables-from-1password):
   `OP_SERVICE_ACCOUNT_TOKEN` and `OP_ENVIRONMENT_ID`. Never paste provider
   tokens directly.

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

## Project variables from 1Password

A project's variables live in one 1Password Environment (1Password → Developer →
Environments), which stays the single source of truth. A cloud environment (the
claude.ai/code settings above) needs two inputs, set as its environment variables:

- `OP_SERVICE_ACCOUNT_TOKEN` — a service account with read access to that
  1Password Environment only. Access is fixed when the account is created.
- `OP_ENVIRONMENT_ID` — Developer → View Environments → Manage environment →
  Copy environment ID.

`.claude/hooks/sessionstart-op-env.sh` (cloud only; matcher
`startup|resume|clear|fork`) runs `cloud/op-env/fetch-variables.mjs`, which reads
the Environment with the pinned `@1password/sdk` that `cloud-setup.sh` installs
from `cloud/op-env/pnpm-lock.yaml`. The hook atomically replaces one per-VM file,
`~/.local/state/claude-op-env/exports.sh` (mode 0600), and adds a single line to
the session's `CLAUDE_ENV_FILE` that sources it. Values reach every Bash command.
The file is referenced rather than appended because Claude Code writes one env
file per hook and concatenates them by index, so an older appended block could
override a refresh.

- **Refresh.** On startup, resume, `/clear` and fork; not on compaction, where
  the session's env files persist. One read costs 2 of the token's 1000 hourly reads.
- **Failure.** The session continues with a warning in its context. A failed
  refresh keeps the last values ("may be stale"); a fresh VM has none ("no
  project variables are loaded"). The read times out after 45 s (hook timeout
  60 s). Setting only one of the two inputs is a failure ("configuration
  incomplete"), not an opt-out. A successful refresh removes variables deleted
  in 1Password, so a same-named variable in the cloud UI reappears: remove duplicates.
- **Validation is all-or-nothing.** Names must match `[A-Za-z_][A-Za-z0-9_]*`
  and be unique; `OP_*`, `CLAUDE_*`, `HOME`, `PATH`, `BASH_ENV`, `ENV`,
  `SHELLOPTS` and `BASHOPTS` are reserved; values may not contain NUL. The
  warning reports only a count, never names or values. Values round-trip exactly
  (newlines, quotes, `$(…)`, backticks, non-ASCII, empty).
- **Opting out.** Removing both inputs stops loading in sessions created afterwards.
- **Scope.** Values reach Bash commands and their children, not MCP servers. The
  token itself is visible to Bash, like every cloud UI variable. Codex still drops
  `*KEY*`/`*SECRET*`/`*TOKEN*` names from its tool subprocesses. `printenv` and
  `env` are allow-listed, so values can be printed without a prompt.
- **SDK status.** `@1password/sdk` is 0.x, its README labels Environments reading
  beta, and it publishes no support policy, so the version is pinned exactly in
  `cloud/op-env/package.json`. To bump it: change the pin, regenerate the lockfile
  with the cloud's pnpm major (`pnpm dlx pnpm@<version>`), run
  `bash tests/cloud-op-env.sh`, and repeat the pilot checks against a synthetic
  Environment.
- **Build time.** The SDK install uses no credentials. Failures appear in the
  setup summary as "1Password SDK install failed" or "1Password SDK skipped (no pnpm)".

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
- **Local 1Password injection** — personal `op://` references, `agent-env-run`
  and the `op` CLI are not used in cloud. Project variables come from a
  project-scoped 1Password Environment (see above); everything else uses
  managed connectors.

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

## Maintenance

- `cloud-setup.sh` carries `# keep in sync with setup.sh <function>` markers —
  when those setup.sh functions change, update the cloud copies.
- Env cache is ~7 days: config changes land on next rebuild, or force one by
  editing the environment's setup script (any whitespace change).
- `tests/cloud-setup.sh` covers syntax, degraded-install behavior, symlinks,
  and the SDK install (arguments, failure, no pnpm).
- `tests/cloud-op-env.sh` covers the 1Password hook and fetcher with fake
  tools: hook registration, gating, dependencies, value round trips, refresh,
  failures, secrecy; it also runs the fetcher's `node --test` suite
  (`cloud/op-env/fetch-variables.test.mjs`).
