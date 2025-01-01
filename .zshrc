autoload -Uz vcs_info
precmd() { vcs_info }
precmd_functions+=( precmd_vcs_info )

alias python='python3'

#export TERM="xterm-256color"
export TERM="screen-256color"
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
