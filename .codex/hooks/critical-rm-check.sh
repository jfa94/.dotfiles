#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088 # Literal shell syntax and HOME spellings are intentional.
set -euo pipefail

FAIL_CLOSED_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Critical rm safety check failed internally; command blocked."}}'

fail_closed() {
  printf '%s\n' "$FAIL_CLOSED_JSON"
  exit 0
}

emit_denial() {
  local reason=$1 output
  if output=$(jq -cn --arg r "$reason" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}' \
      2>/dev/null); then
    printf '%s\n' "$output"
  else
    printf '%s\n' "$FAIL_CLOSED_JSON"
  fi
}

command -v jq >/dev/null 2>&1 || fail_closed
if ! INPUT=$(cat); then
  fail_closed
fi
if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail_closed
fi
if ! CMD=$(printf '%s' "$INPUT" | jq -er \
    'if (.tool_input.command // "") | type == "string" then .tool_input.command // "" else error("invalid command") end' \
    2>/dev/null); then
  fail_closed
fi
[[ -z "$CMD" ]] && exit 0
if ! CWD_INPUT=$(printf '%s' "$INPUT" | jq -er \
    'if (.cwd // "") | type == "string" then .cwd // "" else error("invalid cwd") end' \
    2>/dev/null); then
  fail_closed
fi
if ! WORKDIR_INPUT=$(printf '%s' "$INPUT" | jq -er \
    'if (.tool_input.workdir // "") | type == "string" then .tool_input.workdir // "" else error("invalid workdir") end' \
    2>/dev/null); then
  fail_closed
fi

case "$WORKDIR_INPUT" in
  '') WD_INPUT=${CWD_INPUT:-$(pwd)} ;;
  /*) WD_INPUT=$WORKDIR_INPUT ;;
  *) WD_INPUT="${CWD_INPUT:-$(pwd)}/$WORKDIR_INPUT" ;;
esac
if WD=$(cd -- "$WD_INPUT" 2>/dev/null && pwd -P); then
  :
else
  WD=''
fi
HOME_PHYSICAL=$(cd -- "$HOME" 2>/dev/null && pwd -P) || fail_closed
TMP_ROOTS=()
for tmp_candidate in /tmp /private/tmp /var/tmp; do
  tmp_physical=$(cd -- "$tmp_candidate" 2>/dev/null && pwd -P) || fail_closed
  TMP_ROOTS+=("$tmp_physical")
done
if [[ -n "${TMPDIR:-}" ]]; then
  tmp_physical=$(cd -- "$TMPDIR" 2>/dev/null && pwd -P) || fail_closed
  TMP_ROOTS+=("$tmp_physical")
fi

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

split_segments() {
  local i char next state=plain escaped=0 segment=''
  SEGMENTS=()
  for ((i = 0; i < ${#CMD}; i++)); do
    char=${CMD:i:1}
    if [[ "$escaped" -eq 1 ]]; then
      segment+=$char
      escaped=0
      continue
    fi
    case "$state:$char" in
      plain:\\) segment+=$char; escaped=1 ;;
      plain:\') segment+=$char; state=single ;;
      single:\') segment+=$char; state=plain ;;
      plain:\") segment+=$char; state=double ;;
      double:\") segment+=$char; state=plain ;;
      double:\\) segment+=$char; escaped=1 ;;
      plain:\;|plain:\&|plain:\||$'plain:\n')
        segment=$(trim "$segment")
        [[ -n "$segment" ]] && SEGMENTS+=("$segment")
        segment=''
        next=${CMD:i+1:1}
        [[ "$next" = "$char" ]] && ((i += 1))
        ;;
      *) segment+=$char ;;
    esac
  done
  [[ "$state" = plain && "$escaped" -eq 0 ]] || return 1
  segment=$(trim "$segment")
  [[ -n "$segment" ]] && SEGMENTS+=("$segment")
}

tokenize_segment() {
  local segment=$1 i char state=plain escaped=0 token='' started=0
  TOKENS=()
  for ((i = 0; i < ${#segment}; i++)); do
    char=${segment:i:1}
    if [[ "$escaped" -eq 1 ]]; then
      token+="\\$char"
      escaped=0
      started=1
      continue
    fi
    case "$state:$char" in
      plain:\\) escaped=1; started=1 ;;
      plain:\') token+=$char; state=single; started=1 ;;
      single:\') token+=$char; state=plain ;;
      plain:\") token+=$char; state=double; started=1 ;;
      double:\") token+=$char; state=plain ;;
      double:\\) escaped=1; started=1 ;;
      plain:' '|$'plain:\t')
        if [[ "$started" -eq 1 ]]; then
          TOKENS+=("$token")
          token=''
          started=0
        fi
        ;;
      *) token+=$char; started=1 ;;
    esac
  done
  [[ "$state" = plain && "$escaped" -eq 0 ]] || return 1
  [[ "$started" -eq 1 ]] && TOKENS+=("$token")
}

# Decode quote and backslash syntax without evaluating the word. Expansion- or
# glob-bearing command/option words remain ambiguous and are not classified.
decode_static_word() {
  local raw=$1 i char state=plain escaped=0
  STATIC_WORD=''
  for ((i = 0; i < ${#raw}; i++)); do
    char=${raw:i:1}
    if [[ "$escaped" -eq 1 ]]; then
      STATIC_WORD+=$char
      escaped=0
      continue
    fi
    case "$state:$char" in
      plain:\\|double:\\) escaped=1 ;;
      plain:\') state=single ;;
      single:\') state=plain ;;
      plain:\") state=double ;;
      double:\") state=plain ;;
      plain:'$'|double:'$'|plain:'`'|double:'`') return 1 ;;
      plain:'*'|double:'*'|plain:'?'|double:'?'|plain:'['|double:'['|plain:']'|double:']'|plain:'{'|double:'{'|plain:'}'|double:'}'|plain:'('|double:'('|plain:')'|double:')'|plain:'<'|double:'<'|plain:'>'|double:'>') return 1 ;;
      *) STATIC_WORD+=$char ;;
    esac
  done
  [[ "$state" = plain && "$escaped" -eq 0 ]]
}

literal_target() {
  local raw=$1 i char state=plain escaped=0 value='' expansion=0
  TARGET=''
  FOLLOW_FINAL=0
  for ((i = 0; i < ${#raw}; i++)); do
    char=${raw:i:1}
    if [[ "$escaped" -eq 1 ]]; then
      value+=$char
      escaped=0
      continue
    fi
    case "$state:$char" in
      plain:\\|double:\\) escaped=1 ;;
      plain:\') state=single ;;
      single:\') state=plain ;;
      plain:\") state=double ;;
      double:\") state=plain ;;
      plain:'$'|double:'$'|plain:'`'|double:'`') value+=$char; expansion=1 ;;
      plain:'*'|double:'*'|plain:'?'|double:'?'|plain:'['|double:'['|plain:']'|double:']'|plain:'{'|double:'{'|plain:'}'|double:'}'|plain:'('|double:'('|plain:')'|double:')'|plain:'<'|double:'<'|plain:'>'|double:'>') return 1 ;;
      *) value+=$char ;;
    esac
  done
  [[ "$state" = plain && "$escaped" -eq 0 && -n "$value" ]] || return 1
  if [[ "$expansion" -eq 1 ]]; then
    case "$value" in
      '$HOME') value=$HOME ;;
      '$HOME/'*) value="$HOME/${value#\$HOME/}" ;;
      *) return 1 ;;
    esac
  else
    case "$value" in
      '~') value=$HOME ;;
      '~/'*) value="$HOME/${value#'~/'}" ;;
    esac
  fi
  case "$value" in
    */|*/.) FOLLOW_FINAL=1 ;;
  esac
  TARGET=$value
}

canonicalize_absolute() {
  local value=$1 part joined
  local -a parts=() stack=()
  IFS=/ read -ra parts <<< "$value"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        if [[ ${#stack[@]} -gt 0 ]]; then
          unset 'stack[${#stack[@]}-1]'
        fi
        ;;
      *) stack+=("$part") ;;
    esac
  done
  CANONICAL=/
  if [[ ${#stack[@]} -gt 0 ]]; then
    joined=$(IFS=/; printf '%s' "${stack[*]}")
    CANONICAL="/$joined"
  fi
}

physical_target() {
  local value=$1 follow_final=$2 parent leaf physical_parent probe piece suffix=''
  PHYSICAL_TARGET=''
  case "$value" in
    /) PHYSICAL_TARGET=/; return 0 ;;
    /*) ;;
    *) [[ -n "$WD" ]] || return 1; value="$WD/$value" ;;
  esac
  if [[ "$follow_final" -eq 1 ]]; then
    physical_parent=$(cd -- "$value" 2>/dev/null && pwd -P) || return 1
    PHYSICAL_TARGET=$physical_parent
    return 0
  fi
  value=${value%/}
  [[ -n "$value" ]] || value=/
  [[ "$value" = / ]] && { PHYSICAL_TARGET=/; return 0; }
  parent=${value%/*}
  leaf=${value##*/}
  [[ -n "$parent" ]] || parent=/
  probe=$parent
  while [[ ! -d "$probe" ]]; do
    [[ "$probe" != / ]] || return 1
    piece=${probe##*/}
    suffix="/$piece$suffix"
    probe=${probe%/*}
    [[ -n "$probe" ]] || probe=/
  done
  physical_parent=$(cd -- "$probe" 2>/dev/null && pwd -P) || return 1
  canonicalize_absolute "${physical_parent%/}${suffix}/$leaf"
  PHYSICAL_TARGET=$CANONICAL
}

is_rm_command() {
  decode_static_word "$1" || return 1
  case "$STATIC_WORD" in rm|/bin/rm|/usr/bin/rm) return 0 ;; esac
  return 1
}

is_critical_target() {
  local target=$1 root i
  [[ "$target" = / || "$target" = "$HOME_PHYSICAL" ]] && return 0
  case "$target" in "$HOME_PHYSICAL"/*) return 1 ;; esac
  for ((i = 0; i < ${#TMP_ROOTS[@]}; i++)); do
    root=${TMP_ROOTS[i]}
    [[ "$target" = "$root" || "$target" = "$root"/* ]] && return 1
  done
  for root in /Applications /Library /System /bin /dev /etc /opt /sbin /usr /var /private /Volumes /Users; do
    [[ "$target" = "$root" || "$target" = "$root"/* ]] && return 0
  done
  return 1
}

# Return 0 with INSPECTION_OUTPUT for denial, 1 for no match, and 2 for error.
inspect_segment() {
  local segment=$1 index=0 raw token saw_recursive=0 saw_force=0 end_options=0 i
  local -a operands=()
  INSPECTION_OUTPUT=''
  tokenize_segment "$segment" || return 2
  [[ ${#TOKENS[@]} -gt 0 ]] || return 1
  if decode_static_word "${TOKENS[0]}" && [[ "$STATIC_WORD" = sudo ]]; then
    [[ ${#TOKENS[@]} -gt 1 ]] || return 1
    is_rm_command "${TOKENS[1]}" || return 1
    index=2
  else
    is_rm_command "${TOKENS[0]}" || return 1
    index=1
  fi
  for ((i = index; i < ${#TOKENS[@]}; i++)); do
    raw=${TOKENS[i]}
    if [[ "$end_options" -eq 0 ]] && decode_static_word "$raw"; then
      token=$STATIC_WORD
      if [[ "$token" = -- ]]; then end_options=1; continue; fi
      if [[ "$token" = --recursive ]]; then saw_recursive=1; continue; fi
      if [[ "$token" = --force ]]; then saw_force=1; continue; fi
      if [[ "$token" =~ ^-[A-Za-z]+$ ]]; then
        token=${token#-}
        [[ "$token" = *r* || "$token" = *R* ]] && saw_recursive=1
        [[ "$token" = *f* ]] && saw_force=1
        continue
      fi
    fi
    operands+=("$raw")
  done
  [[ "$saw_recursive" -eq 1 && "$saw_force" -eq 1 ]] || return 1
  for ((i = 0; i < ${#operands[@]}; i++)); do
    raw=${operands[i]}
    literal_target "$raw" || continue
    physical_target "$TARGET" "$FOLLOW_FINAL" || return 2
    if is_critical_target "$PHYSICAL_TARGET"; then
      INSPECTION_OUTPUT=$(emit_denial "Critical recursive-force deletion of '$raw' is blocked unconditionally.")
      return 0
    fi
  done
  return 1
}

split_segments || fail_closed
for ((segment_index = 0; segment_index < ${#SEGMENTS[@]}; segment_index++)); do
  segment=${SEGMENTS[segment_index]}
  if inspect_segment "$segment"; then
    printf '%s\n' "$INSPECTION_OUTPUT"
    exit 0
  else
    inspect_status=$?
    [[ "$inspect_status" -eq 1 ]] || fail_closed
  fi
done
