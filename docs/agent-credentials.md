# Agent credentials

Static agent tokens live in 1Password. Dotfiles tracks only the personal
default at `~/.config/agent-env/personal.env`. Projects with credentials own a
repository-local `.agent-env`; these files contain only `op://` references and
non-secret routing metadata and are never sourced into the parent shell.

## Local use

`.zshrc` defaults `AGENT_ENV_FILE` to `personal.env`. When `op` is available,
`codex`, `supabase`, and `posthog-cli` are aliases that launch the real command
through `op run --env-file "$AGENT_ENV_FILE" -- ...`. The `codex` alias adds
`--no-masking`: masking replaces the child's stdout/stderr with pipes and the
Codex TUI refuses non-terminal stdio (`Error: stdout is not a terminal`).
Masking stays on for `supabase` and `posthog-cli`, which are plain CLIs. Use
`command codex` as the no-secrets escape hatch when 1Password is unavailable.
Credentialed MCP servers are optional, so Codex still starts without their
variables.

Claude MCP `headersHelper` commands must call
`~/.config/agent-env/op-read-locked` (tracked in dotfiles, symlinked by
`setup.sh`) instead of `op read` directly. Claude launches all helpers
concurrently; on a cold 1Password terminal session each raw `op read` pops its
own authorization prompt. The wrapper serializes them behind a kernel file
lock so the first call prompts once and the rest reuse the cached per-TTY
authorization.

Project `.envrc` files select only an environment reference file and native
provider profiles. They must not call `op`, source a resolved file, or export a
token. Outsidey resolves its tracked file to an absolute path; Almunia uses an
explicit empty file because it currently has no agent service credentials:

```sh
# Outsidey
export AGENT_ENV_FILE="$(expand_path .agent-env)"
export AWS_PROFILE="Outsidey"

# Almunia
export AGENT_ENV_FILE=/dev/null
export AWS_PROFILE="Almunia"
```

After adding or changing a selector, run `direnv allow` in that repository.
For a non-interactive shell, use the explicit form:

```sh
op run --env-file "$AGENT_ENV_FILE" -- supabase projects list
op run --env-file "$AGENT_ENV_FILE" -- posthog-cli api --help
```

GitHub stays on `gh auth login`. AWS stays on native `aws login` profiles and
`AWS_PROFILE`; do not put AWS access keys in these files. Do not remove existing
shared credentials until `aws sts get-caller-identity` has succeeded for
`default`, `Outsidey`, and `Almunia`.

## Stripe

The Stripe CLI uses the official 1Password Shell Plugin. Outsidey tracks its
non-secret `.op/plugins/stripe.json` directory default. On each machine, run
`op plugin init stripe` from Outsidey if the transparent alias has not been
generated yet. Agents can invoke one command explicitly with `op plugin run --
stripe ...`; interactive shells use the generated alias sourced from the first
available XDG or `~/.op` plugin path.

Stripe MCP uses `Stripe Outsidey MCP Restricted Key`, intentionally an
`rk_live_*` key. Verify manually in Stripe Dashboard that every permission is
`Read` or `None`; never substitute an application `sk_live_*` key. The
Outsidey Codex MCP allowlist additionally omits write tools.

## PostHog and Supabase

Outsidey PostHog is fixed to EU host `https://eu.posthog.com` and project
`107700` for the CLI. Its MCP URL pins project `107700`, requests the
token-efficient CLI mode, and enables the server's read-only filter. The MCP
host routes to the correct data region based on the authenticated account.

Supabase MCP URLs must include both `project_ref` and `read_only=true`. Codex
receives bearer tokens from the process environment. Claude project MCP files
use `headersHelper` with a fixed `op://` reference resolved through
`op-read-locked`, so Claude itself does not need to launch under `op run`.

Application Stripe keys, webhook secrets, price IDs, and PostHog ingestion keys
remain in deployment secret stores and are not part of this system.

## New machine and rotation

1. Install and sign in to the 1Password desktop app.
2. Enable system authentication and **Integrate with 1Password CLI**.
3. Clone dotfiles and run `setup.sh`, then confirm `op account list`.
4. Clone the project repositories and run `direnv allow` once in each checkout.
5. In Outsidey, run `op plugin init stripe` if the transparent alias is absent.
6. Authenticate AWS profiles with `aws login` and GitHub with `gh auth login`.
7. Migrate the user-level Claude supabase server: with all Claude sessions
   closed, set `mcpServers.supabase.headersHelper` in `~/.claude.json` to
   `printf '{"Authorization":"Bearer %s"}' "$("$HOME/.config/agent-env/op-read-locked" 'op://Credentials/Supabase Access Token/credential')"`
   (that file is machine-local live state, not tracked here).

Rotate a credential by updating its existing 1Password item so references stay
stable. If an item is renamed or recreated, update every tracked reference. A
future Outsidey-specific PostHog key changes only Outsidey's `.agent-env` and
Claude `headersHelper`; the personal default remains unchanged. Keep legacy
Keychain copies until this checklist passes on every machine, then remove them
only as a separately approved cleanup.

Cloud and CI authentication are outside this local-workstation design. Managed
connectors remain authoritative there; do not copy personal `op://` references
into a headless environment.

## Verification

```sh
bash tests/agent-credentials.sh
aws sts get-caller-identity --profile default
aws sts get-caller-identity --profile Outsidey
aws sts get-caller-identity --profile Almunia
gh auth status
op plugin inspect stripe
```

Within Outsidey, verify that PostHog reports project `107700`, project-switching
and Supabase account tools are absent, and no Stripe/PostHog write tool is
exposed. Within Almunia, verify `AGENT_ENV_FILE=/dev/null` and that Codex lists
personal Supabase/PostHog servers as disabled. Run `env` in the parent shell
before and after a credentialed command to confirm tokens were not retained. Do
not print token-bearing child environments or enable shell tracing.
