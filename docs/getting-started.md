# Getting started

This tutorial provisions a new macOS machine with the dotfiles, Claude Code, and Codex. On Linux
(WSL2 / CachyOS), skip step 1; `sudo` and `curl` are required instead (see
[Linux](reference/setup.md#linux-wsl2--cachyos)).

## 1. Install Apple's Command Line Tools

They are prerequisites for Git and Homebrew.

```zsh
xcode-select --install
```

## 2. Clone the repository into a hidden directory

```zsh
# Use SSH (if set up)...
git clone git@github.com:jfa94/.dotfiles.git ~/.dotfiles

# ...or use HTTPS and switch remotes later.
git clone https://github.com/jfa94/.dotfiles.git ~/.dotfiles
```

## 3. Run the setup script

```zsh
chmod +x ~/.dotfiles/setup.sh && ~/.dotfiles/setup.sh
```

If conflicts are detected, you'll be prompted to replace, skip, or decide file-by-file. When the
script finishes, read its summary: Brewfile or plugin failures are reported there.

## 4. Open a new shell

Zsh loads `.zprofile` for login shells and `.zshrc` for interactive shells. The prompt displays the
absolute path at home (for example, `/Users/Javier`).

## 5. Set up agent credentials

Follow [Set up agent credentials on a new machine](guides/set-up-agent-credentials.md).

## Next steps

- What setup did: [setup reference](reference/setup.md).
- How the pieces fit: [architecture overview](architecture/overview.md).
- Cloud VMs: [Set up a Claude Code cloud environment](guides/set-up-cloud-environment.md).
