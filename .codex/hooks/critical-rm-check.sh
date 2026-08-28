#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088 # Runtime source and literal shell syntax are intentional.
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

WD_INPUT=$(project_dir "$INPUT")
if WD=$(cd -- "$WD_INPUT" 2>/dev/null && pwd -P); then
  :
else
  WD=''
fi
HOME_PHYSICAL=$(cd -- "$HOME" 2>/dev/null && pwd -P) || HOME_PHYSICAL=$HOME
TMP_ROOTS=()
for tmp_candidate in /tmp /private/tmp /var/tmp; do
  if tmp_physical=$(cd -- "$tmp_candidate" 2>/dev/null && pwd -P); then
    TMP_ROOTS+=("$tmp_physical")
  fi
done
if [[ -n "${TMPDIR:-}" ]] && tmp_physical=$(cd -- "$TMPDIR" 2>/dev/null && pwd -P); then
  TMP_ROOTS+=("$tmp_physical")
fi

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

# Split only on unquoted shell control operators. Quoted examples and search
# arguments remain inert, while direct rm invocations in compounds are found.
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
  segment=$(trim "$segment")
  [[ -n "$segment" ]] && SEGMENTS+=("$segment")
}

# Tokenize one isolated segment without evaluating it. Raw spellings are kept
# so expansion is limited to the explicitly supported HOME forms.
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

unwrap_quotes() {
  local raw=$1
  UNWRAPPED=$raw
  QUOTE_KIND=none
  if [[ "$raw" == \"*\" && ${#raw} -ge 2 ]]; then
    UNWRAPPED=${raw:1:${#raw}-2}
    QUOTE_KIND=double
  elif [[ "$raw" == \'*\' && ${#raw} -ge 2 ]]; then
    UNWRAPPED=${raw:1:${#raw}-2}
    QUOTE_KIND=single
  elif [[ "$raw" = *\"* || "$raw" = *\'* ]]; then
    return 1
  fi
}

literal_target() {
  local raw=$1 value
  TARGET=''
  unwrap_quotes "$raw" || return 1
  value=$UNWRAPPED
  [[ -n "$value" ]] || return 1
  case "$value" in
    *'`'*|*'$('*|*'${'*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'('*|*')'*|*'<'*|*'>'*) return 1 ;;
  esac
  [[ "$value" != *\\* ]] || return 1
  if [[ "$QUOTE_KIND" = none ]]; then
    case "$value" in
      '~') value=$HOME ;;
      '~/'*) value="$HOME/${value#'~/'}" ;;
      '$HOME') value=$HOME ;;
      '$HOME/'*) value="$HOME/${value#\$HOME/}" ;;
    esac
  elif [[ "$QUOTE_KIND" = double ]]; then
    case "$value" in
      '$HOME') value=$HOME ;;
      '$HOME/'*) value="$HOME/${value#\$HOME/}" ;;
    esac
  fi
  [[ "$value" != *'$'* ]] || return 1
  TARGET=$value
}

# Resolve the parent physically without following the final component. A final
# symlink is classified by its link path, not its destination.
canonicalize_absolute() {
  local value=$1 part
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
    local joined
    joined=$(IFS=/; printf '%s' "${stack[*]}")
    CANONICAL="/$joined"
  fi
}

physical_target() {
  local value=$1 parent leaf physical_parent probe piece suffix=''
  PHYSICAL_TARGET=''
  case "$value" in
    /) PHYSICAL_TARGET=/; return ;;
    /*) ;;
    *) [[ -n "$WD" ]] || return 1; value="$WD/$value" ;;
  esac
  value=${value%/}
  [[ -n "$value" ]] || value=/
  [[ "$value" = / ]] && { PHYSICAL_TARGET=/; return; }
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
  local raw=$1
  unwrap_quotes "$raw" || return 1
  case "$UNWRAPPED" in rm|/bin/rm|/usr/bin/rm) return 0 ;; esac
  return 1
}

is_critical_target() {
  local target=$1 root
  [[ "$target" = / || "$target" = "$HOME_PHYSICAL" ]] && return 0

  # These exceptions precede the broader system-tree classification.
  case "$target" in "$HOME_PHYSICAL"/*) return 1 ;; esac
  for root in "${TMP_ROOTS[@]}"; do
    [[ "$target" = "$root" || "$target" = "$root"/* ]] && return 1
  done

  for root in /Applications /Library /System /bin /dev /etc /opt /sbin /usr /var /private /Volumes /Users; do
    [[ "$target" = "$root" || "$target" = "$root"/* ]] && return 0
  done
  return 1
}

inspect_segment() {
  local segment=$1 index=0 token raw saw_recursive=0 saw_force=0 end_options=0
  local -a operands=()
  tokenize_segment "$segment" || return
  [[ ${#TOKENS[@]} -gt 0 ]] || return

  if [[ "${TOKENS[0]}" = sudo ]]; then
    [[ ${#TOKENS[@]} -gt 1 ]] && is_rm_command "${TOKENS[1]}" || return
    index=2
  else
    is_rm_command "${TOKENS[0]}" || return
    index=1
  fi

  for raw in "${TOKENS[@]:index}"; do
    if [[ "$end_options" -eq 0 && "$raw" = -- ]]; then
      end_options=1
      continue
    fi
    if [[ "$end_options" -eq 0 && "$raw" = --recursive ]]; then
      saw_recursive=1
      continue
    fi
    if [[ "$end_options" -eq 0 && "$raw" = --force ]]; then
      saw_force=1
      continue
    fi
    if [[ "$end_options" -eq 0 && "$raw" =~ ^-[A-Za-z]+$ ]]; then
      token=${raw#-}
      [[ "$token" = *r* || "$token" = *R* ]] && saw_recursive=1
      [[ "$token" = *f* ]] && saw_force=1
      continue
    fi
    operands+=("$raw")
  done
  [[ "$saw_recursive" -eq 1 && "$saw_force" -eq 1 ]] || return

  for raw in "${operands[@]}"; do
    literal_target "$raw" || continue
    physical_target "$TARGET" || continue
    if is_critical_target "$PHYSICAL_TARGET"; then
      deny "Critical recursive-force deletion of '$raw' is blocked unconditionally."
      return
    fi
  done
}

split_segments
for segment in "${SEGMENTS[@]}"; do
  output=$(inspect_segment "$segment" || true)
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
    exit 0
  fi
done
