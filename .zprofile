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

# Optional-tool install dirs (Linux / WSL) - deno/pnpm/supabase land here;
# setup.sh installs them with rc-writing disabled, so this is their only PATH.
# PNPM_HOME export also matters on Homebrew-pnpm Mac: pnpm needs it set or
# `pnpm add -g` errors. pnpm v11 moved shims to $PNPM_HOME/bin (was $PNPM_HOME
# itself pre-v11) - same layout on both platforms.
export PNPM_HOME="$HOME/.local/share/pnpm"
for _d in "$HOME/.deno/bin" "$PNPM_HOME/bin" "$HOME/.supabase/bin"; do
  [[ -d "$_d" ]] && export PATH="$PATH:$_d"
done
unset _d
