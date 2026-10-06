#!/bin/bash
set -euo pipefail
PAYLOAD=$(cat)
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')
RAW_WD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.workdir // empty')
case "$RAW_WD" in
  /*) WD_INPUT=$RAW_WD ;;
  '') WD_INPUT=${CWD:-$PWD} ;;
  *) WD_INPUT="${CWD:-$PWD}/$RAW_WD" ;;
esac
if WD=$(cd -- "$WD_INPUT" 2>/dev/null && pwd -P); then
  RAW_REPO=$(git -C "$WD" rev-parse --show-toplevel 2>/dev/null || true)
else
  WD=''
  RAW_REPO=''
fi
if [ -n "$RAW_REPO" ]; then
  REPO=$(cd -- "$RAW_REPO" 2>/dev/null && pwd -P) || REPO=''
else
  REPO=''
fi

# Matches any rm whose flags include r, in any grouping/order
# (-rf, -fr, -Rf, -r -f, -f -r): flag groups may precede and follow the r-group.
RECURSIVE_RM='rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]+-[a-zA-Z]+)*'

# Policy denies. Literal spellings mirror settings.json permissions.deny (the CLI
# can strip that array on auto-rewrite, so they are duplicated here as a backstop);
# bundled and abbreviated forms are enforced only here (see anthropics/claude-code#22659,
# #51843, #6699). The push-refspec pattern ([^;&|]* bounds it to the same
# command) catches `git push origin +branch` force-pushes flag rules miss.
# Backslash-newline is joined first (grep is line-based). Bundled shorts and
# abbreviated long options are segment-bounded; `-m "x -nothing"` over-matches (safe).
JOINED=${CMD//$'\\\n'/}
# GIT tolerates global options (-c k=v, -C dir, --no-pager) and repeated spaces.
GIT='git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+'
ARGS='([^;&|]*[[:space:]])?'
for PAT in \
  "${GIT}push[[:space:]].*--force" \
  "${GIT}push[[:space:]].*--no-verify" \
  "${GIT}push[[:space:]].*-f([[:space:]]|\$)" \
  "${GIT}push[[:space:]][^;&|]*[[:space:]]\\+[^[:space:]]" \
  "${GIT}commit[[:space:]].*--no-verify" \
  "${GIT}commit[[:space:]].*--no-gpg-sign" \
  "${GIT}commit[[:space:]].*-n([[:space:]]|\$)" \
  "${GIT}rebase[[:space:]].*--no-verify" \
  "${GIT}push[[:space:]]${ARGS}-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|\$)" \
  "${GIT}commit[[:space:]]${ARGS}-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|\$)" \
  "${GIT}(commit|push|rebase)[[:space:]]${ARGS}--no-veri" \
  "${GIT}commit[[:space:]]${ARGS}--no-g" \
  "${GIT}push[[:space:]]${ARGS}--m" \
  "${RECURSIVE_RM}[[:space:]]+(~|\\\$HOME)" \
  '(pnpm|npm|yarn) publish'; do
  if grep -qE "$PAT" <<< "$JOINED"; then
    jq -cn --arg r "Blocked by policy: $PAT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
done

# Options that make git run an arbitrary program. Case-sensitive: rebase -X is
# the harmless strategy option. Prefixes are the shortest git accepts per command.
for PAT in \
  "${GIT}rebase[[:space:]]${ARGS}--ex" \
  "${GIT}rebase[[:space:]]${ARGS}-[a-zA-Z]*x" \
  "${GIT}fetch[[:space:]]${ARGS}--upl" \
  "${GIT}ls-remote[[:space:]]${ARGS}--(u|exe)" \
  "${GIT}push[[:space:]]${ARGS}--(rece|e)"; do
  if grep -qE "$PAT" <<< "$JOINED"; then
    jq -cn '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"git option executes an arbitrary command — run it manually"}}'
    exit 0
  fi
done

# Dangerous patterns. chmod covers -R 777; curl/wget pipes only deny when the
# pipe target is an actual shell word (sh/bash/zsh/dash, optionally sudo) —
# not shasum, .shell, etc.
for PAT in \
  'DROP TABLE' \
  'DROP DATABASE' \
  'DROP SCHEMA' \
  'TRUNCATE[[:space:]]+TABLE' \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*777' \
  '(curl|wget)[^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'; do
  if grep -qiE "$PAT" <<< "$CMD"; then
    jq -cn --arg r "Blocked dangerous command pattern: $PAT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
done

# Auto-allow only literal operands that are physically contained in a tmp root,
# or are both git-ignored and beneath a known artifact directory in this repo.
# Ignore status alone is not enough: repos also ignore durable local state.
ARTIFACT_SEGMENT_RE='^(node_modules|\.cache|\.turbo|\.vite|\.parcel-cache|\.eslintcache|coverage|\.nyc_output|\.stryker-tmp|\.vitest|test-results|playwright-report|blob-report|dist|build|out|\.next|\.output|\.venv|target|tmp|\.pytest_cache)$'
SECRET_PATH_RE='(^|/)\.env[^/]*($|/)|(^|/)secrets(/|$)|\.(pem|key|p12|pfx)$|(^|/)(id_rsa|id_ed25519|id_ecdsa|id_dsa)$'
SECRET_EXEMPT_RE='\.env\.(example|sample|template)$'

TMP_ROOTS=()
for root in /tmp /private/tmp /var/tmp; do
  physical_root=$(cd -- "$root" 2>/dev/null && pwd -P) || continue
  case " ${TMP_ROOTS[*]-} " in *" $physical_root "*) ;; *) TMP_ROOTS+=("$physical_root") ;; esac
done

normalize_operand() {
  local operand=$1 absolute=0 part
  local -a parts=()
  NORMALIZED=''
  FOLLOW_FINAL=0
  case "$operand" in
    \"*\")
      operand=${operand:1:${#operand}-2}
      case "$operand" in *\"*|'') return 1 ;; esac
      ;;
    *\"*) return 1 ;;
  esac
  case "$operand" in */|*/.) FOLLOW_FINAL=1 ;; esac
  case "$operand" in /*) absolute=1 ;; esac
  IFS='/' read -ra parts <<< "$operand"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) continue ;;
      ..) return 2 ;;
      *) NORMALIZED+="/$part" ;;
    esac
  done
  if [ "$absolute" -eq 0 ]; then
    NORMALIZED=${NORMALIZED#/}
    [ -n "$NORMALIZED" ] || NORMALIZED='.'
  else
    [ -n "$NORMALIZED" ] || NORMALIZED='/'
  fi
}

physical_target() {
  local operand=$1 target parent leaf probe suffix='' piece physical_parent rc
  if normalize_operand "$operand"; then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] && return 2
    return 1
  fi
  case "$NORMALIZED" in
    /*) target=$NORMALIZED ;;
    *) [ -n "$WD" ] || return 2; target="$WD/$NORMALIZED" ;;
  esac
  if [ "$FOLLOW_FINAL" -eq 1 ] && [ -d "$target" ]; then
    PHYSICAL_TARGET=$(cd -- "$target" 2>/dev/null && pwd -P) || return 1
    return
  fi
  parent=${target%/*}
  leaf=${target##*/}
  [ -n "$parent" ] || parent='/'
  probe=$parent
  while [ ! -d "$probe" ]; do
    [ "$probe" != '/' ] || return 1
    piece=${probe##*/}
    suffix="/$piece$suffix"
    probe=${probe%/*}
    [ -n "$probe" ] || probe='/'
  done
  physical_parent=$(cd -- "$probe" 2>/dev/null && pwd -P) || return 1
  PHYSICAL_TARGET="${physical_parent%/}${suffix}/$leaf"
  [ -n "$PHYSICAL_TARGET" ] || PHYSICAL_TARGET='/'
}

has_artifact_segment() {
  local rel=$1 part
  local -a rel_parts=()
  IFS='/' read -ra rel_parts <<< "$rel"
  for part in "${rel_parts[@]}"; do
    [[ "$part" =~ $ARTIFACT_SEGMENT_RE ]] && return 0
  done
  return 1
}

classify_operand() {
  local operand=$1 root rel rc
  CLASS=unsafe
  physical_target "$operand" || { rc=$?; [ "$rc" -eq 2 ] && CLASS=outside; return; }
  if grep -qiE "$SECRET_PATH_RE" <<< "$PHYSICAL_TARGET" \
    && ! grep -qiE "$SECRET_EXEMPT_RE" <<< "$PHYSICAL_TARGET"; then
    return
  fi
  [ "$PHYSICAL_TARGET" = '/' ] && { CLASS=outside; return; }
  for root in "${TMP_ROOTS[@]}"; do
    [ "$PHYSICAL_TARGET" = "$root" ] && { CLASS=outside; return; }
    case "$PHYSICAL_TARGET" in "$root"/*) CLASS=safe; return ;; esac
  done
  if [ -n "$REPO" ]; then
    [ "$PHYSICAL_TARGET" = "$REPO" ] && return
    case "$PHYSICAL_TARGET" in
      "$REPO"/*)
        rel=${PHYSICAL_TARGET#"$REPO"/}
        if git -C "$REPO" check-ignore -q -- "$rel" \
          && has_artifact_segment "$rel"; then
          CLASS=safe
        fi
        return
        ;;
    esac
  fi
  CLASS=outside
}

parse_safe_rm() {
  local trimmed tok end_options=0 saw_flag=0 saw_operand=0
  local -a tokens=()
  RM_OPERANDS=()
  # shellcheck disable=SC1003
  case "$CMD" in
    *$'\n'*|*'$'*|*'`'*|*'<'*|*'>'*|*'|'*|*';'*|*'&'*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'\'*|*"'"*|*'~'*|*'('*|*')'*) return 1 ;;
  esac
  trimmed=${CMD#"${CMD%%[![:space:]]*}"}
  trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
  IFS=$' \t' read -ra tokens <<< "$trimmed"
  [ "${#tokens[@]}" -ge 3 ] && [ "${tokens[0]}" = rm ] || return 1
  for tok in "${tokens[@]:1}"; do
    if [ "$end_options" -eq 0 ]; then
      if [ "$tok" = -- ]; then
        [ "$saw_operand" -eq 0 ] || return 1
        end_options=1
        continue
      fi
      if [[ "$tok" =~ ^-[a-zA-Z]+$ ]]; then
        [ "$saw_operand" -eq 0 ] || return 1
        saw_flag=1
        continue
      fi
      end_options=1
    fi
    case "$tok" in -*) [ "$end_options" -eq 1 ] || return 1 ;; esac
    normalize_operand "$tok" >/dev/null 2>&1 || return 1
    RM_OPERANDS+=("$tok")
    saw_operand=1
  done
  [ "$saw_flag" -eq 1 ] && [ "$saw_operand" -eq 1 ]
}

if parse_safe_rm; then
  ALL_SAFE=1
  for operand in "${RM_OPERANDS[@]}"; do
    classify_operand "$operand"
    [ "$CLASS" = safe ] || { ALL_SAFE=0; break; }
  done
  if [ "$ALL_SAFE" -eq 1 ]; then
    jq -cn --arg r 'contained git-ignored artifact or tmp subpath — auto-allowed' \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$r}}'
    exit 0
  fi
fi

# Recursive rm targeting a physically outside path. Split compounds and inspect
# only rm segments; quoted substrings retain the existing ask-tier fallthrough.
STRIPPED_RM=$(printf '%s\n' "$CMD" | tr '\n' ';' | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
while IFS= read -r RM_SEG; do
  RM_SEG="${RM_SEG#"${RM_SEG%%[![:space:]]*}"}"
  case "$RM_SEG" in
    rm[[:space:]]*|sudo[[:space:]]rm[[:space:]]*) ;;
    *) continue ;;
  esac
  if grep -qE "^(sudo[[:space:]]+)?${RECURSIVE_RM}" <<< "$RM_SEG"; then
    IFS=' ' read -ra RM_TOKS <<< "$RM_SEG"
    END_OPTIONS=0
    for TOK in "${RM_TOKS[@]:1}"; do
      [ "$TOK" = rm ] && continue
      if [ "$END_OPTIONS" -eq 0 ]; then
        [ "$TOK" = -- ] && { END_OPTIONS=1; continue; }
        [[ "$TOK" =~ ^-[a-zA-Z]+$ ]] && continue
        END_OPTIONS=1
      fi
      classify_operand "$TOK"
      if [ "$CLASS" = outside ]; then
        jq -cn --arg r "recursive rm targeting outside/traversal path '$TOK' — blocked" \
          '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
        exit 0
      fi
    done
  fi
done < <(printf '%s\n' "$STRIPPED_RM" | sed -E 's/(&&|\|\||[;&|])/\n/g')

# Backstop for shell writes that bypass the Edit/Write protected-files gate:
# redirects, tee, sed -i, mv/cp/rm targeting .env* / credentials / secrets paths.
# Target-anchored: the secret path must be the write op's operand, so reads with
# incidental redirects (`source .env.e2e ... 2>&1 | tail`) pass silently.
# Ask (not deny): mirrors protected-files' confirm flow; example/sample/template exempt.
ENVBASE='\.env[.[:alnum:]_-]*'
PFX='[^[:space:]|;&<>]*'
SECRET="(${ENVBASE}|${PFX}/${ENVBASE}|secrets?/|${PFX}/secrets?/|${PFX}credentials)"
GAP='([^;&|<>]*[[:space:]])?'
if grep -qiE \
    ">>?[[:space:]]*${SECRET}|(^|[[:space:]|;&])tee[[:space:]]+${GAP}${SECRET}|(^|[[:space:]|;&])sed[[:space:]]+[^;&|<>]*-i${GAP}${SECRET}|(^|[[:space:]|;&])(mv|cp|rm)[[:space:]]+${GAP}${SECRET}" <<< "$CMD" \
  && ! grep -qiE '\.env[^[:space:]]*\.(example|sample|template)' <<< "$CMD"; then
  jq -cn --arg r 'shell write touching .env/credentials/secrets — confirm (protected-files backstop)' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
  exit 0
fi

# Ask tier: any recursive+force rm (flag order/grouping tolerant).
if grep -qiE "$RECURSIVE_RM" <<< "$CMD" \
  && grep -qiE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*f' <<< "$CMD"; then
  jq -cn --arg r 'recursive force rm detected — confirm before running' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
fi
