autoload -Uz vcs_info
precmd() { vcs_info }
precmd_functions+=( precmd_vcs_info )

alias python='python3'
alias pip='pip3'

export TERM="xterm-256color"
export COLORTERM="truecolor"
#if which tmux >/dev/null 2>&1; then
#    test -z "$TMUX" && (tmux attach || tmux new-session)
#fi

zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' unstagedstr '*'
zstyle ':vcs_info:*' stagedstr '+'
zstyle ':vcs_info:*' formats '(%b%u%c)'

setopt PROMPT_SUBST
PROMPT='%F{208}%n%f in %F{247}${PWD/#HOME/~}%f ${vcs_info_msg_0_}> '

# User-local binaries take precedence over system-wide installs.
export PATH="$HOME/.local/bin:$PATH"

command -v direnv &>/dev/null && eval "$(direnv hook zsh)"

# Secret references are resolved only inside commands launched through 1Password.
export AGENT_ENV_FILE="${AGENT_ENV_FILE:-$HOME/.config/agent-env/personal.env}"
if command -v op &>/dev/null; then
  alias codex='op run --env-file "$AGENT_ENV_FILE" -- codex'
  alias supabase='op run --env-file "$AGENT_ENV_FILE" -- supabase'
  alias posthog-cli='op run --env-file "$AGENT_ENV_FILE" -- posthog-cli'
fi

# Ctrl+Left/Right word-jump. Windows Terminal sends the native Ctrl-arrow
# CSI sequence (1;5D/C) normally, and the Alt-arrow one (1;3D/C) once Ctrl+Left/
# Right is remapped to it in WT settings.json (done for Claude Code, which has
# no rebindable word-motion action). Bind both so word-jump works either way.
bindkey '^[[1;5D' backward-word
bindkey '^[[1;5C' forward-word
bindkey '^[[1;3D' backward-word
bindkey '^[[1;3C' forward-word

# 1Password Shell Plugins choose their config root per platform. Source the
# first generated alias file that exists without making shell startup depend on it.
for _op_plugins in "${XDG_CONFIG_HOME:-$HOME/.config}/op/plugins.sh" "$HOME/.op/plugins.sh"; do
  if [[ -r "$_op_plugins" ]]; then
    source "$_op_plugins"
    break
  fi
done
unset _op_plugins
