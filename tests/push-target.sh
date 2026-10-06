#!/usr/bin/env bash
# shellcheck disable=SC2016 # Command fixtures intentionally contain expansions.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLAUDE_LIB="$ROOT/.claude/hooks/push-target.sh"
CODEX_LIB="$ROOT/.codex/hooks/push-target.sh"
PASS=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

cmp -s "$CLAUDE_LIB" "$CODEX_LIB" || { echo "FAIL push-target.sh copies differ between .claude and .codex" >&2; exit 1; }
PASS=$((PASS + 1))

ORIGIN="$TMP/origin.git"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$TMP/seed"
git -C "$TMP/seed" config user.email t@t.com
git -C "$TMP/seed" config user.name t
git -C "$TMP/seed" commit -q --allow-empty -m init
git -C "$TMP/seed" push -q "$ORIGIN" main

new_repo() { # name branch
  git clone -q "$ORIGIN" "$TMP/$1" 2>/dev/null
  git -C "$TMP/$1" config user.email t@t.com
  git -C "$TMP/$1" config user.name t
  [[ "$2" == main ]] || git -C "$TMP/$1" checkout -q -b "$2"
}

new_repo onfeat feat
new_repo onmain main
new_repo detached feat
git -C "$TMP/detached" checkout -q --detach
new_repo trackmain feat
git -C "$TMP/trackmain" config branch.feat.merge refs/heads/main
new_repo trackfeat feat
git -C "$TMP/trackfeat" config branch.feat.merge refs/heads/feat
CONFIGS=(push.default=matching push.default=upstream push.default=nothing remote.origin.push=refs/heads/feat:refs/heads/main remote.origin.mirror=true)
for i in "${!CONFIGS[@]}"; do
  new_repo "cfg$i" feat
  git -C "$TMP/cfg$i" config "${CONFIGS[$i]%%=*}" "${CONFIGS[$i]#*=}"
done
new_repo cfgcurrent feat
git -C "$TMP/cfgcurrent" config push.default current
mkdir -p "$TMP/notrepo" "$TMP/onfeat/sub"

# Run under macOS /bin/bash (3.2) with the callers' strict mode: the Claude
# hooks use that shebang, so newer-bash-only syntax must fail here.
classify() {
  local lib=$1 base=$2 cmd=$3
  /bin/bash -c 'set -euo pipefail; . "$1"; push_target_classify "$2" "$3"' _ "$lib" "$base" "$cmd"
}

expect() { # expected base command
  local expected=$1 base=$2 cmd=$3 actual
  actual=$(classify "$CLAUDE_LIB" "$base" "$cmd") || { echo "FAIL classifier exited non-zero for '$cmd'" >&2; exit 1; }
  [[ "$actual" == "$expected" ]] || { echo "FAIL expected $expected, got $actual for '$cmd' in $base" >&2; exit 1; }
  PASS=$((PASS + 1))
}

F=$TMP/onfeat
M=$TMP/onmain

# Feature branches.
expect unprotected "$F" "git push origin feat"
expect unprotected "$F" "git push -u origin HEAD"
expect unprotected "$F" "git push"
expect unprotected "$F" "git push origin"
expect unprotected "$F" "git push --set-upstream origin feat --dry-run"
expect unprotected "$F" "git push origin feat:feat2"
expect unprotected "$F" "git push origin feat:refs/heads/other"
expect unprotected "$F" "git push origin feature/main-menu"
expect unprotected "$F" "git push origin maintenance"
expect unprotected "$F" "git push origin main-fix"
expect unprotected "$F" "git push origin refs/tags/v1"
expect unprotected "$F" "git push origin feat:refs/tags/v1"
expect unprotected "$F" 'git add a && git commit -m "fix: x" && git push origin feat'
expect unprotected "$F" "git add a && git commit -m x && git push"
expect unprotected "$F" "git push origin feat 2>&1"
expect unprotected "$F" "git push origin feat 2>&1 | tail -5"
expect unprotected "$F" "git push origin feat && git push origin other"
expect unprotected "$F/sub" "git push origin feat"
expect unprotected "$TMP/trackfeat" "git push"
expect unprotected "$TMP/cfgcurrent" "git push origin feat"

# Protected destinations.
for dest in main develop HEAD:main HEAD:develop refs/heads/main refs/heads/develop heads/main heads/develop \
  feat:refs/heads/develop feat:heads/main feat:main Main DEVELOP :main :develop : refs/for/main refs/remotes/origin/main; do
  expect protected "$F" "git push origin $dest"
  expect protected "$F" "git push -u origin $dest"
done
expect protected "$F" "git push origin --delete main"
expect protected "$F" "git push origin -d develop"
expect protected "$F" "git push origin +feat:main"

# Implicit and HEAD pushes follow the current branch.
expect protected "$M" "git push"
expect protected "$M" "git push origin"
expect protected "$M" "git push -u origin HEAD"
expect protected "$M" "git push origin head"
expect protected "$M" "git push origin @"
expect protected "$TMP/detached" "git push"
expect protected "$TMP/detached" "git push origin HEAD"
expect protected "$TMP/trackmain" "git push"
expect protected "$F" "git checkout main && git push"
expect protected "$F" "git branch -m main && git push origin HEAD"
expect protected "$F" "git rebase x main && git push origin HEAD"
expect protected "$F" "pnpm test && git push"
# An explicit destination does not depend on the current branch.
expect unprotected "$F" "git checkout main && git push origin feat"

# Repository config that remaps destinations.
for i in "${!CONFIGS[@]}"; do
  expect protected "$TMP/cfg$i" "git push origin feat"
  expect protected "$TMP/cfg$i" "git push"
done

# Options.
for opt in --all --branches --mirror --repo=x "-o ci.skip" -un --force --receive-pack=sh; do
  expect protected "$F" "git push $opt origin feat"
done

# Shapes the parser does not trust.
expect protected "$F" "git -c x=y push origin feat"
expect protected "$F" "git --git-dir=x push origin feat"
expect protected "$F" "env A=1 git push origin feat"
expect protected "$F" "command git push origin feat"
expect protected "$F" "git -C a -C b push origin feat"
expect protected "$F" 'git push origin "feat"'
expect protected "$F" "git push origin 'feat'"
expect protected "$F" 'git push origin $BR'
expect protected "$F" 'git push origin $(echo main)'
expect protected "$F" 'git push origin `echo main`'
expect protected "$F" "git push origin {feat,main}"
expect protected "$F" "git push origin feat*"
expect protected "$F" "git push origin ma?n"
expect protected "$F" "git push origin ma[i]n"
expect protected "$F" "(git push origin main)"
expect protected "$F" "(git push origin feat)"
expect protected "$F" "git push origin main>log"
expect protected "$F" "git push origin feat > log"
expect protected "$F" $'git push origin\tmain'
expect protected "$F" $'git push origin feat \\\n main'
expect protected "$F" "git push origin feat#main"
expect protected "$F" "git push origin ~/x"
expect protected "$F" "git push origin HEAD~1:main"

# git -C.
expect unprotected "$TMP" "git -C $F push origin feat"
expect unprotected "$TMP" "git -C onfeat push origin feat"
expect unprotected "$TMP" "git -C ~/onfeat push origin feat"
expect protected "$TMP" "git -C ~other/onfeat push origin feat"
expect protected "$TMP" "git -C $M push"
expect protected "$TMP" "git -C $F push origin main"
expect protected "$TMP" "git -C $TMP/notrepo push origin feat"
expect protected "$TMP/notrepo" "git push origin feat"
expect protected "" "git push origin feat"

# Compounds and non-pushes.
expect protected "$F" "git push origin feat; git push origin main"
expect protected "$F" "git push origin main && git push origin feat"
expect unprotected "$F" "git push origin feat || git push origin other"
expect none "$F" "git status"
expect none "$F" ""
expect none "$F" 'grep -n "git push" notes.md'
expect none "$F" "git commit -m x"
expect none "$F" "echo pushed"

# Both copies behave identically.
[[ "$(classify "$CODEX_LIB" "$F" "git push origin main")" == protected ]]
[[ "$(classify "$CODEX_LIB" "$F" "git push origin feat")" == unprotected ]]
PASS=$((PASS + 2))

echo "push-target: $PASS checks passed"
