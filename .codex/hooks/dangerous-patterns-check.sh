#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

WD_INPUT=$(project_dir "$INPUT")
if WD=$(cd -- "$WD_INPUT" 2>/dev/null && pwd -P); then
  RAW_REPO=$(git -C "$WD" rev-parse --show-toplevel 2>/dev/null || true)
else
  WD=''
  RAW_REPO=''
fi
if [[ -n "$RAW_REPO" ]]; then
  REPO=$(cd -- "$RAW_REPO" 2>/dev/null && pwd -P) || REPO=''
else
  REPO=''
fi

# Matches any rm whose flags include r, in any grouping/order
# (-rf, -fr, -Rf, -r -f, -f -r): flag groups may precede and follow the r-group.
RECURSIVE_RM='rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*r[a-zA-Z]*([[:space:]]+-[a-zA-Z]+)*'

# Policy denies — mirrored from rules/default.rules where prefix matching can't
# express them. The push-refspec pattern ([^;&|]* bounds it to the same command)
# catches `git push origin +branch` force-pushes flag rules miss.
for pat in \
  'git( -C [^[:space:]]+)? push[[:space:]].*--force' \
  'git( -C [^[:space:]]+)? push[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? push[[:space:]].*-f([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? push[[:space:]][^;&|]*[[:space:]]\+[^[:space:]]' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-verify' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*--no-gpg-sign' \
  'git( -C [^[:space:]]+)? commit[[:space:]].*-n([[:space:]]|$)' \
  'git( -C [^[:space:]]+)? rebase[[:space:]].*--no-verify' \
  "${RECURSIVE_RM}[[:space:]]+(~|\\\$HOME)" \
  '(pnpm|npm|yarn) publish'; do
  if printf '%s' "$CMD" | grep -qE "$pat"; then
    deny "Blocked by policy: $pat"
    exit 0
  fi
done

# Dangerous patterns. chmod covers -R 777; curl/wget pipes only deny when the
# pipe target is an actual shell word (sh/bash/zsh/dash, optionally sudo) —
# not shasum, .shell, etc.
for pat in \
  'DROP TABLE' \
  'DROP DATABASE' \
  'DROP SCHEMA' \
  'TRUNCATE[[:space:]]+TABLE' \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*777' \
  '(curl|wget)[^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'; do
  if printf '%s' "$CMD" | grep -qiE "$pat"; then
    deny "Blocked dangerous command pattern: $pat"
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
  if [[ "$absolute" -eq 0 ]]; then
    NORMALIZED=${NORMALIZED#/}
    [[ -n "$NORMALIZED" ]] || NORMALIZED='.'
  else
    [[ -n "$NORMALIZED" ]] || NORMALIZED='/'
  fi
}

physical_target() {
  local operand=$1 target parent leaf probe suffix='' piece physical_parent rc
  if normalize_operand "$operand"; then
    :
  else
    rc=$?
    [[ "$rc" -eq 2 ]] && return 2
    return 1
  fi
  case "$NORMALIZED" in
    /*) target=$NORMALIZED ;;
    *) [[ -n "$WD" ]] || return 2; target="$WD/$NORMALIZED" ;;
  esac
  if [[ "$FOLLOW_FINAL" -eq 1 && -d "$target" ]]; then
    PHYSICAL_TARGET=$(cd -- "$target" 2>/dev/null && pwd -P) || return 1
    return
  fi
  parent=${target%/*}
  leaf=${target##*/}
  [[ -n "$parent" ]] || parent='/'
  probe=$parent
  while [[ ! -d "$probe" ]]; do
    [[ "$probe" != '/' ]] || return 1
    piece=${probe##*/}
    suffix="/$piece$suffix"
    probe=${probe%/*}
    [[ -n "$probe" ]] || probe='/'
  done
  physical_parent=$(cd -- "$probe" 2>/dev/null && pwd -P) || return 1
  PHYSICAL_TARGET="${physical_parent%/}${suffix}/$leaf"
  [[ -n "$PHYSICAL_TARGET" ]] || PHYSICAL_TARGET='/'
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
  physical_target "$operand" || { rc=$?; [[ "$rc" -eq 2 ]] && CLASS=outside; return; }
  if printf '%s' "$PHYSICAL_TARGET" | grep -qiE "$SECRET_PATH_RE" \
    && ! printf '%s' "$PHYSICAL_TARGET" | grep -qiE "$SECRET_EXEMPT_RE"; then
    return
  fi
  [[ "$PHYSICAL_TARGET" = '/' ]] && { CLASS=outside; return; }
  for root in "${TMP_ROOTS[@]}"; do
    [[ "$PHYSICAL_TARGET" = "$root" ]] && { CLASS=outside; return; }
    case "$PHYSICAL_TARGET" in "$root"/*) CLASS=safe; return ;; esac
  done
  if [[ -n "$REPO" ]]; then
    [[ "$PHYSICAL_TARGET" = "$REPO" ]] && return
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
  [[ "${#tokens[@]}" -ge 3 && "${tokens[0]}" = rm ]] || return 1
  for tok in "${tokens[@]:1}"; do
    if [[ "$end_options" -eq 0 ]]; then
      if [[ "$tok" = -- ]]; then
        [[ "$saw_operand" -eq 0 ]] || return 1
        end_options=1
        continue
      fi
      if [[ "$tok" =~ ^-[a-zA-Z]+$ ]]; then
        [[ "$saw_operand" -eq 0 ]] || return 1
        saw_flag=1
        continue
      fi
      end_options=1
    fi
    normalize_operand "$tok" >/dev/null 2>&1 || return 1
    RM_OPERANDS+=("$tok")
    saw_operand=1
  done
  [[ "$saw_flag" -eq 1 && "$saw_operand" -eq 1 ]]
}

# Plain exit 0: Codex allow-hook output fails open, while the rules-layer prompt
# remains available for auto_review.
if parse_safe_rm; then
  ALL_SAFE=1
  for operand in "${RM_OPERANDS[@]}"; do
    classify_operand "$operand"
    [[ "$CLASS" = safe ]] || { ALL_SAFE=0; break; }
  done
  [[ "$ALL_SAFE" -eq 1 ]] && exit 0
fi

# Recursive rm targeting a physically outside path. Split compounds and inspect
# only rm segments; quoted substrings retain the existing deny-tier fallthrough.
STRIPPED_RM=$(printf '%s\n' "$CMD" | tr '\n' ';' | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
while IFS= read -r RM_SEG; do
  RM_SEG="${RM_SEG#"${RM_SEG%%[![:space:]]*}"}"
  case "$RM_SEG" in
    rm[[:space:]]*|sudo[[:space:]]rm[[:space:]]*) ;;
    *) continue ;;
  esac
  if printf '%s' "$RM_SEG" | grep -qE "^(sudo[[:space:]]+)?${RECURSIVE_RM}"; then
    IFS=' ' read -ra RM_TOKS <<< "$RM_SEG"
    END_OPTIONS=0
    for TOK in "${RM_TOKS[@]:1}"; do
      [[ "$TOK" = rm ]] && continue
      if [[ "$END_OPTIONS" -eq 0 ]]; then
        [[ "$TOK" = -- ]] && { END_OPTIONS=1; continue; }
        [[ "$TOK" =~ ^-[a-zA-Z]+$ ]] && continue
        END_OPTIONS=1
      fi
      classify_operand "$TOK"
      if [[ "$CLASS" = outside ]]; then
        deny "Recursive rm targeting outside/traversal path '$TOK' blocked. Retry only after the user confirms the exact target."
        exit 0
      fi
    done
  fi
done < <(printf '%s\n' "$STRIPPED_RM" | sed -E 's/(&&|\|\||[;&|])/\n/g')

# Backstop for shell writes that bypass the Edit/Write protected-files gate:
# redirects, sed -i, tee, cp/mv onto .env* / credentials / secrets paths.
# Claude uses an ask tier here; Codex PreToolUse has no ask, so deny with a
# confirm instruction. example/sample/template exempt.
if printf '%s' "$CMD" | grep -qiE '(^|[[:space:]/=("'"'"'])\.env([.[:alnum:]_-]*)?|credentials|(^|[[:space:]/])secrets?/' \
  && printf '%s' "$CMD" | grep -qE '>|[[:space:]]tee[[:space:]]|sed[[:space:]]+[^;&|]*-i|(^|[[:space:]])(mv|cp)[[:space:]]' \
  && ! printf '%s' "$CMD" | grep -qiE '\.env[^[:space:]]*\.(example|sample|template)'; then
  deny "Shell write touching .env/credentials/secrets blocked (protected-files backstop). Retry only after the user confirms the exact target."
  exit 0
fi

# Any recursive+force rm (flag order/grouping tolerant) — confirm-gated.
if printf '%s' "$CMD" | grep -qiE "$RECURSIVE_RM" \
  && printf '%s' "$CMD" | grep -qiE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*f'; then
  deny "Recursive force rm requires explicit user confirmation in the current turn. Retry only after the user confirms the exact target."
fi
