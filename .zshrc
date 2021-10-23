autoload -Uz vcs_info
precmd() { vcs_info }
precmd_functions+=( precmd_vcs_info )

zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' unstagedstr '*'
zstyle ':vcs_info:*' stagedstr '+'
zstyle ':vcs_info:*' formats '(%b%u%c)'

setopt PROMPT_SUBST
PROMPT='%F{208}%n%f in %F{247}${PWD/#HOME/~}%f ${vcs_info_msg_0_}> '
