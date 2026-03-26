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


3. Run the setup script to create symlinks, install Homebrew & Brewfile packages, and set up vim plugins.

```zsh
chmod +x ~/.dotfiles/setup.sh && ~/.dotfiles/setup.sh
```

The script is idempotent — re-running it skips anything already set up. If conflicts are detected, you’ll be prompted to replace, skip, or decide file-by-file.

# Claude files

1. Link project config by running the ‘.claude/configure.sh’ script

```zsh
chmod +x ./.claude/configure.sh && ./.claude/configure.sh ~/Projects/<Project Name>
```
