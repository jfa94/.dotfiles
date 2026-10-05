# Replace a Homebrew or npm CLI install

Setup refuses an active Homebrew or npm installation of Claude Code or Codex to avoid ambiguous
duplicate CLIs.

1. Remove the old package:

   ```zsh
   brew uninstall --cask codex claude-code@latest
   # or
   npm uninstall -g @openai/codex
   ```

2. Re-run setup:

   ```zsh
   ~/.dotfiles/setup.sh
   ```

Configuration and auth state in `~/.codex` and `~/.claude` are not moved or recreated.
