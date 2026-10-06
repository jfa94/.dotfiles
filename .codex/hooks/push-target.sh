# Sourced library, not a hook. Classifies the git pushes in a command as
# none | unprotected | protected (main/develop, or anything it cannot prove safe).
# Kept byte-identical in .claude/hooks and .codex/hooks (tests/push-target.sh).
# Runs under macOS bash 3.2: no ${x,,}, declare -A, mapfile.

PT_GIT_RE='[[:space:]({]*((env|command|exec|nice|nohup|sudo|time|xargs)([[:space:]]+[^;&|]*)?[[:space:]]+)?git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+'

_pt_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# $1 repo, $2 prefix_ok, $3 include upstream branch. Returns 0 when the current branch is protected/unknown.
_pt_current_protected() {
  local cur merge
  [ "$2" = 1 ] || return 0
  cur=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null) || true
  [ -n "$cur" ] || return 0
  case $(_pt_lc "$cur") in main|develop) return 0;; esac
  [ "$3" = 1 ] || return 1
  merge=$(git -C "$1" config --get "branch.$cur.merge" 2>/dev/null) || true
  case $(_pt_lc "${merge#refs/heads/}") in main|develop) return 0;; esac
  return 1
}

# $1 repo, $2 refspec, $3 prefix_ok. Returns 0 when the destination is protected/unknown.
_pt_dest_protected() {
  local ref=${2#+} dest lc
  case $ref in
    *:*:*) return 0;;
    *:*) dest=${ref#*:};;
    *) dest=$ref;;
  esac
  [ -n "$dest" ] || return 0
  lc=$(_pt_lc "$dest")
  case $lc in
    head|@) _pt_current_protected "$1" "$3" 0; return;;
    refs/heads/*) lc=${lc#refs/heads/};;
    refs/tags/*) return 1;;
    refs/*) return 0;;
    heads/*) lc=${lc#heads/};;
  esac
  case $lc in main|develop) return 0;; esac
  return 1
}

# $1 base dir, $2 trimmed push segment, $3 prefix_ok. Returns 0 when protected/unknown.
_pt_segment_protected() {
  local base=$1 seg=$2 prefix_ok=$3
  local toks i n repo dir tok pd seen_remote=0 nref=0
  case $seg in
    *\\*|*\'*|*\"*|*\$*|*\`*|*\**|*\?*|*\[*|*\{*|*\}*|*\(*|*\)*|*\<*|*\>*|*,*|*\#*) return 0;;
  esac
  read -r -a toks <<< "$seg"
  [ "${toks[0]:-}" = git ] || return 0
  i=1
  [ -n "$base" ] || return 0
  repo=$base
  if [ "${toks[1]:-}" = -C ]; then
    dir=${toks[2]:-}
    [ -n "$dir" ] || return 0
    case $dir in
      '~') dir=${HOME:-/nonexistent};;
      '~/'*) dir=${HOME:-/nonexistent}/${dir#\~/};;
      *'~'*) return 0;;
    esac
    case $dir in /*) repo=$dir;; *) repo=$base/$dir;; esac
    i=3
  fi
  [ "${toks[$i]:-}" = push ] || return 0
  i=$((i + 1))

  [ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 0
  pd=$(git -C "$repo" config --get push.default 2>/dev/null) || true
  case $pd in ''|simple|current) ;; *) return 0;; esac
  git -C "$repo" config --get-regexp '^remote\..*\.(push|mirror)$' >/dev/null 2>&1 && return 0

  n=${#toks[@]}
  while [ "$i" -lt "$n" ]; do
    tok=${toks[$i]}
    i=$((i + 1))
    case $tok in
      -u|--set-upstream|-q|--quiet|-v|--verbose|--tags|--follow-tags|--no-follow-tags|--dry-run|-n|--atomic|--porcelain|--progress|--no-progress|-d|--delete) ;;
      -*|*'~'*) return 0;;
      *)
        if [ "$seen_remote" = 0 ]; then
          seen_remote=1
        else
          nref=$((nref + 1))
          _pt_dest_protected "$repo" "$tok" "$prefix_ok" && return 0
        fi;;
    esac
  done
  if [ "$nref" = 0 ]; then
    _pt_current_protected "$repo" "$prefix_ok" 1 && return 0
  fi
  return 1
}

# $1 base dir, $2 command. Prints one word; always returns 0.
push_target_classify() {
  local base=$1 cmd=$2 seg trimmed found=0 verdict=unprotected prefix_ok=1
  # fd duplications (2>&1) are not redirects to files; drop them before splitting on '&'.
  cmd=$(printf '%s' "$cmd" | sed -E 's/[0-9]*>&[0-9]*/ /g' | tr ';&|' '\n\n\n')
  while IFS= read -r seg; do
    trimmed=$(printf '%s' "$seg" | sed -E 's/^[[:space:]({]+//; s/[[:space:]]+$//')
    [ -n "$trimmed" ] || continue
    if printf '%s' "$seg" | grep -qE "^${PT_GIT_RE}push"; then
      found=1
      if _pt_segment_protected "$base" "$trimmed" "$prefix_ok"; then verdict=protected; fi
    elif ! printf '%s' "$trimmed" | grep -qE '^git( -C [^ ]+)? (add|commit)( |$)'; then
      prefix_ok=0
    fi
  done <<< "$cmd"
  if [ "$found" = 0 ]; then echo none; else echo "$verdict"; fi
  return 0
}
