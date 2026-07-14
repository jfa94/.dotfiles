# .dotfiles

1. Install Apple's Command Line Tools, which are prerequisites for Git and Homebrew.

```zsh
xcode-select --install
```

2. Clone repo into new hidden directory.

```zsh
# Use SSH (if set up)...
git clone git@github.com:jfa94/.dotfiles.git ~/.dotfiles

# ...or use HTTPS and switch remotes later.
git clone https://github.com/jfa94/.dotfiles.git ~/.dotfiles
```

3. Run the setup script.

```zsh
chmod +x ~/.dotfiles/setup.sh && ~/.dotfiles/setup.sh
```

The script:

- Symlinks the dotfiles (`.zshrc`, `.vimrc`, `.tmux.conf`, etc.) into `$HOME`.
- Symlinks Claude Code config into `~/.claude/` (settings, hooks, skills, agents, statusline), exposes compatible skills to Codex at `~/.agents/skills`, and symlinks XDG config into `~/.config/`, then marks hook scripts executable.
- Symlinks the authored `.codex/user-config.toml` to `~/.codex/config.toml`, including native TUI status-line settings.
- Installs Homebrew (if missing) and the `Brewfile` packages.
- Installs the Claude Code CLI and the plugins/marketplaces listed in `.claude/plugins.txt`.
- Installs Codex CLI with OpenAI's standalone installer, then installs the plugins listed in `.codex/plugins.txt`.
- Sets up vim plugin/undo directories.

It is idempotent — re-running skips anything already linked. If conflicts are detected, you’ll be prompted to replace, skip, or decide file-by-file. New files added to the repo are only deployed on a re-run.

### Shared Claude and Codex skills

Setup maintains a real `~/.agents/skills` directory containing individual
symlinks. Compatible shared skills link from `.claude/skills`; the Codex-only
`code-review` skill links from `.codex/skills/code-review`. Claude's
`comprehensive-code-review` and `focused-code-review` skills are deliberately
excluded because they depend on Claude Workflow APIs. Nothing is copied.

Unrelated entries in `~/.agents/skills` are preserved. Per-skill name conflicts
follow setup's replace, skip, or prompt policy. Setup also migrates its legacy
whole-tree symlink automatically and prunes only stale links it owns.

Codex normally detects skill changes automatically. Restart it if an update does
not appear. Discovery does not translate Claude-specific tools or metadata, so
skills that depend on Claude-only runtime features may need separate portability
work before Codex can execute every step.

## Linux (WSL2 / CachyOS)

The script also runs on Linux (`apt` on Ubuntu/Debian, `pacman` on Arch/CachyOS)
— no `xcode-select` step, but `sudo` and `curl` are required. Packages install
via the native package manager instead of Homebrew; a few tools not in the
default repos (`deno`, `pnpm`, `trufflehog`, `semgrep`, `supabase`) use their
official install scripts on both distros. Docker is installed from Docker's
official apt repo (Ubuntu/Debian/WSL2) or via `pacman` (Arch/CachyOS); setup
also adds the current user to the `docker` group (re-login required) and
starts the daemon (`systemctl`, or `service` when systemd is off, as on
default WSL2).

## Codex CLI

Codex uses OpenAI's standalone installer on macOS and Linux. It installs managed
releases under `~/.codex/packages/standalone`, exposes `codex` through
`~/.local/bin`, and owns future CLI updates; Codex is intentionally absent from
the `Brewfile` and Linux native package lists.

Setup refuses an active Homebrew or npm installation to avoid ambiguous duplicate
CLIs. Remove the old package first, then re-run setup:

```zsh
brew uninstall --cask codex
# or
npm uninstall -g @openai/codex
```
