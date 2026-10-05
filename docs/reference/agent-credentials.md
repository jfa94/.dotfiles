# Agent credentials

Static agent tokens live in 1Password. Dotfiles tracks only the personal
default at `~/.config/agent-env/personal.env`. Projects with credentials own a
repository-local `.agent-env`; these files contain only `op://` references and
non-secret routing metadata and are never sourced into the parent shell.

Tasks: [set up a new machine](../guides/set-up-agent-credentials.md),
[configure a project](../guides/configure-project-credentials.md),
[rotate a credential](../guides/rotate-agent-credential.md).

## Runner and shell integration

`.zshrc` defaults `AGENT_ENV_FILE` to `personal.env`. When `op` and the tracked
runner are available, thin `codex`, `supabase`, and `posthog-cli` functions call
`~/.config/agent-env/agent-env-run`. The external runner resolves references,
exports values only in its own process, and then replaces itself with the target
command. Secrets therefore never persist in the interactive parent shell. Use
`command codex` as the no-secrets escape hatch when 1Password is unavailable.
Credentialed MCP servers are optional, so Codex still starts without their
variables.

For a non-interactive shell, use the explicit runner. This also avoids Codex's
intentional filtering of `KEY`, `SECRET`, and `TOKEN` variables from tool
subprocess environments:

```sh
"$HOME/.config/agent-env/agent-env-run" supabase projects list
"$HOME/.config/agent-env/agent-env-run" posthog-cli api --help
```

## Executable ownership

On macOS, Homebrew owns the AWS, uv, Stripe, Supabase, and 1Password CLI
executables; Linux retains the documented native/official installers for them.
Codex and Claude Code are owned by their vendors' standalone installers on every
platform, so their built-in auto-updaters keep working. Package migration must
change only those executables: it must not rewrite this environment file,
`~/.codex`, `~/.claude`, AWS profiles, generated 1Password plugin aliases, or
project MCP files. Setup does not perform `op plugin init`, `direnv allow`,
provider login, or project-agent configuration.

## Keychain cache (macOS)

On macOS, resolved values are cached in the explicit login Keychain under
service `agent-env-cache`, with the full `op://` reference as the account. A
record is logically valid for a fixed 12 hours; timestamps at exactly 12 hours,
in the future, or malformed are misses. Expired records remain encrypted at
rest until refreshed or cleared. Run the following after rotating a value when
the old cached value must stop being used immediately:

```sh
"$HOME/.config/agent-env/op-read-locked" --clear
```

The cache is local to the login Keychain and does not sync through iCloud.
Writes enter `/usr/bin/security` through stdin, so values are absent from its
argv. This protects process listings, not the unlocked account boundary: any
process running as the same user can invoke `security` while the Keychain is
unlocked.

## `op-read-locked`

Claude MCP `headersHelper` commands must call
`~/.config/agent-env/op-read-locked` (tracked in dotfiles, symlinked by
`setup.sh`) instead of `op read` directly. Claude launches helpers concurrently;
the wrapper checks the Keychain and serializes cache misses behind a kernel file
lock. A waiter fails after 120 seconds instead of proceeding concurrently. The
timeout does not bound the first process's `op read`, which can remain in flight
indefinitely. A cold env-file fill batches unique references through one wrapper
process, so 1Password authorization is shared and duplicate references resolve
once.

Only single-line printable ASCII values and safe printable `op://` references
are cached. Other resolved values are returned with a warning. 1Password and
Keychain failures are surfaced; a cache-write failure warns but does not discard
a value already returned by 1Password. On Linux/WSL, `op-read-locked` retains
serialized `op read`, while `agent-env-run` delegates to `op run --no-masking`.
Output is intentionally unmasked on every platform so TTY applications keep
working; do not print token-bearing child environments or enable shell tracing.

## Project `.envrc` selectors

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

## Env-file format

The supported env-file format is deliberately strict: blank lines, comments
whose first character is `#`, or `NAME=value` with a valid shell variable name.
Values beginning with `op://` are references; every other value is literal.
Shell quoting, interpolation, `export`, inline comments, and leading whitespace
are not supported. `/dev/null` is a valid empty environment file.

## GitHub and AWS

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
`107700` for the CLI. MCP access is a single `posthog` server pinning project
`107700` and the token-efficient CLI mode, exposing the full catalogue behind
its single `exec` tool (no `readonly` URL param, no second write server).
Claude allow-lists `mcp__posthog__exec`, so every call — read or write — runs
silently; safety is the PostHog API key's own scopes, not a Claude permission
rule. Codex defines the same server with `bearer_token_env_var =
"POSTHOG_MCP_TOKEN"`; see [codex-claude-parity.md](codex-claude-parity.md) for
how gating differs there. The MCP host routes to the correct data region
based on the authenticated account.

Supabase MCP URLs must include both `project_ref` and `read_only=true`. Codex
receives bearer tokens from the process environment. Claude project MCP files
use `headersHelper` with a fixed `op://` reference resolved through
`op-read-locked`, so Claude itself does not need to launch under `op run`.
Supabase mutations have no MCP route: after explicit confirmation in the
current turn, use `agent-env-run` with the project-scoped Supabase CLI.
Destructive or unbounded SQL, schema changes, and migration application always
require that confirmation.

Application Stripe keys, webhook secrets, price IDs, and PostHog ingestion keys
remain in deployment secret stores and are not part of this system.

## Cloud and CI

Cloud and CI authentication are outside this local-workstation design. Managed
connectors remain authoritative there, and Claude Code cloud sessions load a
project's variables from its 1Password Environment through a project-scoped
service account (see
[cloud environments](cloud-environments.md#project-variables-from-1password)).
Do not copy personal `op://` references into a headless environment.
