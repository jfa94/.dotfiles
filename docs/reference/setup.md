# Setup reference

Behavior of `setup.sh` (local) and its relationship to `cloud-setup.sh`. For first-time use, see
[Getting started](../getting-started.md).

## What `setup.sh` does

- Symlinks the dotfiles (`.zshrc`, `.vimrc`, `.tmux.conf`, etc.) into `$HOME`.
- Symlinks Claude Code config into `~/.claude/` (settings, hooks, agents, statusline per file; each `.claude/skills/<name>` as one directory link, so new skill files need no re-run), exposes compatible skills to Codex at `~/.agents/skills`, and symlinks XDG config into `~/.config/`, then marks hook scripts executable.
- Links the single global `instructions/AGENTS.md` to `~/.claude/CLAUDE.md`
  and `~/.codex/AGENTS.md`. Tool-specific policies stay in their named sections;
  frontend/backend guidance lives alongside the canonical file and loads on demand.
  Root `CLAUDE.md` imports the separate dotfiles project `AGENTS.md`.
- Symlinks the authored `.codex/user-config.toml` and `.codex/user-hooks.json`
  to `~/.codex/config.toml` and `~/.codex/hooks.json`. The non-discovered
  source names prevent this repository from loading user-level configuration
  a second time as project-local configuration.
- Installs Homebrew (if missing) and the `Brewfile` packages.
- Installs Claude Code and Codex through their official standalone installers
  on every platform (self-updating), then installs their declared plugins.
- Sets up vim plugin/undo directories.

Agent credentials use tracked 1Password references with process-scoped
injection; see [agent credentials](agent-credentials.md). No
plaintext provider token is sourced into the interactive shell.

## Idempotency and conflicts

It is idempotent — re-running skips anything already linked and runs
`brew bundle install --no-upgrade`, so it installs missing Brewfile entries
without upgrading existing ones. If conflicts are detected, you'll be prompted
to replace, skip, or decide file-by-file. New files added to the repo are only
deployed on a re-run. Replaced regular files or directories retain one backup at
`<path>.bak`; setup warns before replacing an existing backup. Replaced symlinks
are removed without a backup. The TypeScript scaffold uses the same policy for
copied config files; package.json script merging does not create a backup.

## Plugins and exit status

Local setup reads Claude marketplace sources from `.claude/settings.json`,
checks installed inventories, registers only missing marketplaces, and verifies
all plugins declared in `.claude/plugins.txt` at user scope. It preserves existing
plugin enablement values and never upgrades marketplaces. Brewfile or plugin
failures are reported in the summary and return nonzero after independent setup
steps finish. Cloud setup retains its documented best-effort, zero-exit behavior.
Scaffold typecheck or lint failures likewise return 1 after the summary; successful
validation and the intentional no-`src/` skip return 0.

## Shell startup

Zsh loads `.zprofile` for login shells and `.zshrc` for interactive shells;
the profile does not source the interactive configuration itself. Both keep
`~/.local/bin` first and deduplicate PATH when re-sourced. The prompt displays
the absolute path at home (for example, `/Users/Javier`) and home-relative paths
in its subdirectories (for example, `~/Projects`).

## Shared skill links

Setup links each `.claude/skills/<name>` into `~/.claude/skills` as a single
directory symlink, and maintains a real `~/.agents/skills` directory containing
individual symlinks. Compatible shared skills link from `.claude/skills`; the Codex-only
`code-review` skill links from `.codex/skills/code-review`. Claude's
`comprehensive-code-review` and `focused-code-review` skills are deliberately
excluded because they depend on Claude Workflow APIs. Nothing is copied.

Unrelated entries in `~/.agents/skills` are preserved. Per-skill name conflicts
follow setup's replace, skip, or prompt policy. Setup also migrates its legacy
whole-tree symlink automatically and prunes only stale links it owns.

Rationale: [shared skills](../explanation/shared-skills.md).

## Claude Code and Codex CLIs

Both CLIs are owned by their vendors' standalone installers on every platform,
so their built-in auto-updaters work (Homebrew casks block them). OpenAI's
installer owns releases under `~/.codex/packages/standalone`; both expose their
binaries through `~/.local/bin`. Changing the executable owner does not move or
recreate `~/.codex` or `~/.claude`, which hold configuration and auth state.

Setup refuses an active Homebrew or npm installation to avoid ambiguous
duplicate CLIs; see [Replace a Homebrew or npm CLI install](../guides/replace-duplicate-cli-install.md).

## Linux (WSL2 / CachyOS)

The script also runs on Linux (`apt` on Ubuntu/Debian, `pacman` on Arch/CachyOS)
— no `xcode-select` step, but `sudo` and `curl` are required. Packages install
via the native package manager instead of Homebrew; a few tools not in the
default repos use their official installers. TypeScript, its language server,
npm-check-updates, and PostHog CLI install through pnpm only when their
executables are missing. This includes a signed 1Password CLI install and a
checksum-verified Stripe CLI release; the 1Password desktop app and CLI
integration remain per-machine interactive steps. Docker is
installed from Docker's official apt repo (Ubuntu/Debian/WSL2) or via `pacman`
(Arch/CachyOS); setup also adds the current user to the `docker` group (re-login
required) and starts the daemon (`systemctl`, or `service` when systemd is off,
as on default WSL2).

## Cloud setup

`cloud-setup.sh` replicates the full Claude Code workflow (shared global instructions, skills,
hooks, plugins, and Codex/Supabase CLIs) on claude.ai/code cloud VMs. Managed PostHog/Supabase
connectors remain authoritative when their project binding is verified; setup
does not add duplicate unscoped MCP servers. Project variables load at session
start from the project's 1Password Environment (inputs `OP_SERVICE_ACCOUNT_TOKEN`
and `OP_ENVIRONMENT_ID`). AWS CLI is deliberately excluded; Codex re-auths per
session via `codex login --device-auth`. See [cloud environments](cloud-environments.md).
