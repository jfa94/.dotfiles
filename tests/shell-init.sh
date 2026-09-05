#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -r "$WORK"' EXIT
mkdir -p "$WORK/home/project/nested" "$WORK/home/project/space %name" "$WORK/home-other" "$WORK/bin" "$WORK/home/.local/bin" "$WORK/home/.deno/bin"
cp "$ROOT/.zprofile" "$WORK/home/.zprofile"
{ echo '(( RC_COUNT+=1 ))'; cat "$ROOT/.zshrc"; } > "$WORK/home/.zshrc"
printf '#!/bin/sh\necho Linux\n' > "$WORK/bin/uname"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/direnv"
chmod +x "$WORK/bin/"*
for mode in -lic -ic -lc; do
  expected=1
  [[ "$mode" == -lc ]] && expected=0
  # shellcheck disable=SC2016 # Expand in the isolated zsh, not the test runner.
  env -i HOME="$WORK/home" ZDOTDIR="$WORK/home" PATH="$WORK/bin:/usr/bin:/bin" EXPECTED="$expected" \
    /bin/zsh -d "$mode" '
      [[ ${RC_COUNT:-0} == $EXPECTED ]] || exit 10
      [[ $path[1] == $HOME/.local/bin ]] || exit 11
      source "$HOME/.zprofile"
      source "$HOME/.zshrc"
      first=$PATH
      source "$HOME/.zprofile"
      source "$HOME/.zshrc"
      [[ $PATH == $first && $#path == ${#${(u)path}} ]] || exit 12
      [[ -z ${(M)precmd_functions:#precmd_vcs_info} ]] || exit 13
      cd "$HOME"
      precmd
      rendered=$(print -P -- "$PROMPT")
      [[ $rendered == *"$HOME"* && $rendered != *"~"* ]] || exit 15
      cd "$HOME/project"
      precmd
      rendered=$(print -P -- "$PROMPT")
      [[ $rendered == *"~/project"* ]] || exit 14
      cd nested
      precmd
      rendered=$(print -P -- "$PROMPT")
      [[ $rendered == *"~/project/nested"* ]] || exit 16
      cd "$HOME/project/space %name"
      precmd
      rendered=$(print -P -- "$PROMPT")
      [[ $rendered == *"~/project/space %name"* ]] || exit 17
      cd "$HOME-other"
      precmd
      rendered=$(print -P -- "$PROMPT")
      [[ $rendered == *"$PWD"* && $rendered != *"~"* ]] || exit 18
      cd /
      precmd
      rendered=$(print -P -- "$PROMPT")
      [[ $rendered == *"/"* && $rendered != *"~"* ]] || exit 19
    '
done
echo 'shell initialization: OK'
