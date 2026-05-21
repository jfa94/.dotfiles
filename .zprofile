# Homebrew (macOS only)
if [[ "$(uname -s)" == "Darwin" ]] && [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Load zshrc if present
if [[ -f "$HOME/.zshrc" ]]; then
  source "$HOME/.zshrc"
fi

# pipx path (Linux / WSL)
if [[ -d "$HOME/.local/bin" ]]; then
  export PATH="$PATH:$HOME/.local/bin"
fi
