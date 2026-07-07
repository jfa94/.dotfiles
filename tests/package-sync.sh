#!/usr/bin/env bash
# Checks that the "which tools does this repo install" fact stays in sync
# across Brewfile, setup.sh's APT_PACKAGES/PACMAN_PACKAGES, and the optional
# script-install loop. Run manually before committing a package change:
#   bash tests/package-sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$SCRIPT_DIR/setup.sh"
BREWFILE="$SCRIPT_DIR/Brewfile"

# Canonical manifest: name|brew|apt|pacman
# Sentinels: "-" = intentionally absent on that surface.
#            "optional" = installed via the deno/pnpm/.../supabase for-loop,
#              not the native package array.
#            "bootstrap" = apt-only; installed via install_<name>_apt(),
#              not the APT_PACKAGES array (name deltas are real per-OS names).
MANIFEST="
zsh|zsh|zsh|zsh
git|git|git|git
vim|vim|vim|vim
python|python|python3|python
cmake|cmake|cmake|cmake
go|go|golang-go|go
java|java|default-jdk|jdk-openjdk
build-essential|-|build-essential|base-devel
python3-dev|-|python3-dev|-
pipx|-|pipx|python-pipx
unzip|-|unzip|unzip
tmux|tmux|tmux|tmux
jq|jq|jq|jq
graphviz|graphviz|graphviz|graphviz
gh|gh|bootstrap|github-cli
node|node|bootstrap|nodejs
npm|-|-|npm
deno|deno|optional|optional
pnpm|pnpm|optional|optional
trufflehog|trufflehog|optional|optional
semgrep|semgrep|optional|optional
supabase|supabase/tap/supabase|optional|optional
docker|docker|-|-
docker-desktop|docker-desktop|-|-
"

# --- ponytail: single-line array/for-loop assumption; re-write this parser
# if setup.sh ever wraps these declarations across multiple lines. ---
apt_line=$(grep -m1 '^APT_PACKAGES=' "$SETUP")
apt_str="${apt_line#APT_PACKAGES=(}"; apt_str="${apt_str%)}"
read -ra ACTUAL_APT <<< "$apt_str"

pacman_line=$(grep -m1 '^PACMAN_PACKAGES=' "$SETUP")
pacman_str="${pacman_line#PACMAN_PACKAGES=(}"; pacman_str="${pacman_str%)}"
read -ra ACTUAL_PACMAN <<< "$pacman_str"

optional_str=$(sed -n 's/.*for tool in \(.*\); do.*/\1/p' "$SETUP" | head -1)
read -ra ACTUAL_OPTIONAL <<< "$optional_str"

mapfile -t ACTUAL_BREW < <(grep -oE '^(brew|cask) "[^"]+"' "$BREWFILE" | sed -E 's/^(brew|cask) "(.*)"/\2/')

contains() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# --- Forward: every manifest row must resolve on each surface ---
while IFS='|' read -r name brew apt pacman; do
  [[ -z "$name" ]] && continue

  case "$apt" in
    -) ;;
    optional) contains "$name" "${ACTUAL_OPTIONAL[@]}" || err "$name: manifest says apt=optional but not in setup.sh's optional-tool loop" ;;
    bootstrap) grep -q "^install_${name}_apt()" "$SETUP" || err "$name: manifest says apt=bootstrap but install_${name}_apt() not found in setup.sh" ;;
    *) contains "$apt" "${ACTUAL_APT[@]}" || err "$name: manifest says apt=$apt but not in APT_PACKAGES" ;;
  esac

  case "$pacman" in
    -) ;;
    optional) contains "$name" "${ACTUAL_OPTIONAL[@]}" || err "$name: manifest says pacman=optional but not in setup.sh's optional-tool loop" ;;
    bootstrap) grep -q "^install_${name}_apt()" "$SETUP" || err "$name: manifest says pacman=bootstrap but install_${name}_apt() not found in setup.sh" ;;
    *) contains "$pacman" "${ACTUAL_PACMAN[@]}" || err "$name: manifest says pacman=$pacman but not in PACMAN_PACKAGES" ;;
  esac

  case "$brew" in
    -) ;;
    *) contains "$brew" "${ACTUAL_BREW[@]}" || err "$name: manifest says brew=$brew but not in Brewfile" ;;
  esac
done <<< "$MANIFEST"

# --- Reverse: every surface entry must be claimed by some manifest row ---
check_reverse() {
  local surface_name="$1" col="$2"; shift 2
  local entry
  for entry in "$@"; do
    if ! awk -F'|' -v c="$col" -v e="$entry" '$c == e { found=1 } END { exit !found }' <<< "$MANIFEST"; then
      err "$surface_name has '$entry' with no manifest row (col $col)"
    fi
  done
}
check_reverse "APT_PACKAGES" 3 "${ACTUAL_APT[@]}"
check_reverse "PACMAN_PACKAGES" 4 "${ACTUAL_PACMAN[@]}"
check_reverse "optional-tool loop" 1 "${ACTUAL_OPTIONAL[@]}"
check_reverse "Brewfile" 2 "${ACTUAL_BREW[@]}"

if [[ "$fail" -eq 0 ]]; then
  echo "OK"
  exit 0
fi
exit 1
