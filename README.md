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
- Symlinks Claude Code config into `~/.claude/` (settings, hooks, skills, agents, statusline) and XDG config into `~/.config/`, then marks hook scripts executable.
- Installs Homebrew (if missing) and the `Brewfile` packages.
- Installs the Claude Code CLI and the plugins/marketplaces listed in `.claude/plugins.txt`.
- Sets up vim plugin/undo directories.

It is idempotent — re-running skips anything already linked. If conflicts are detected, you’ll be prompted to replace, skip, or decide file-by-file. New files added to the repo are only deployed on a re-run.
