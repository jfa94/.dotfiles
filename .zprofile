# The following lines were added by Docker Desktop to add commands to your PATH.
export PATH="$PATH:/Users/Javier/.docker/bin"
# End of Docker Desktop section.

# Homebrew (macOS only)
if [[ "$(uname -s)" == "Darwin" ]] && [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Keep user-local binaries first, including in non-interactive login shells.
typeset -U path PATH
export PATH="$HOME/.local/bin:$PATH"

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
