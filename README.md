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
- Symlinks Claude Code config into `~/.claude/` (settings, hooks, skills, agents, statusline), exposes the same skill tree to Codex at `~/.agents/skills`, and symlinks XDG config into `~/.config/`, then marks hook scripts executable.
- Symlinks Codex config into `~/.codex/`, including native TUI status-line settings from `.codex/config.toml`.
- Installs Homebrew (if missing) and the `Brewfile` packages.
- Installs the Claude Code CLI and the plugins/marketplaces listed in `.claude/plugins.txt`.
- Installs Codex CLI with OpenAI's standalone installer, then installs the plugins listed in `.codex/plugins.txt`.
- Sets up vim plugin/undo directories.

It is idempotent — re-running skips anything already linked. If conflicts are detected, you’ll be prompted to replace, skip, or decide file-by-file. New files added to the repo are only deployed on a re-run.

### Shared Claude and Codex skills

`.claude/skills` is the only authored skill tree. Setup links the whole directory
to `~/.agents/skills`, Codex's user-level discovery location, so new or removed
skills are visible to both tools without copies or per-skill link maintenance.
This reserves `~/.agents/skills` for the shared tree; existing content follows
setup's normal replace, skip, or prompt conflict policy.

Codex normally detects skill changes automatically. Restart it if an update does
not appear. Discovery does not translate Claude-specific tools or metadata, so
skills that depend on Claude-only runtime features may need separate portability
work before Codex can execute every step.

## Linux (WSL2 / CachyOS)

The script also runs on Linux (`apt` on Ubuntu/Debian, `pacman` on Arch/CachyOS)
— no `xcode-select` step, but `sudo` and `curl` are required. Packages install
via the native package manager instead of Homebrew; a few tools not in the
default repos (`deno`, `pnpm`, `trufflehog`, `semgrep`, `supabase`) use their
official install scripts on both distros. Docker is **not** managed on Linux —
install it yourself (Docker Desktop's WSL integration, or natively on Arch).

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
