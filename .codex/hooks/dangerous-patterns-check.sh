#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

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
# not shasum, .shell, etc. rm targeting / lives below, after the artifact/tmp
# exemption so that exemption gets first look.
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

# Regenerable caches / build / test artifacts: a single rm whose every operand
# is a known throwaway path. Anchored ^…$ so compounds, pipes, redirects and
# command substitution never reach it; path segments must start alphanumeric,
# which rules out `..` traversal. Absolute form is limited to tmp roots and
# requires a subpath, so bare /tmp still gates below. Plain exit 0 (no deny())
# — Codex "allow" hook output fails open anyway; the rules-layer prompt for
# ["rm","-rf"] still applies and is what auto_review resolves silently.
ARTIFACT='node_modules/\.cache|\.cache|\.turbo|\.vite|\.parcel-cache|\.eslintcache|coverage|\.nyc_output|\.stryker-tmp|\.vitest|test-results|playwright-report|blob-report|dist|build|out|\.next|\.output'
SEG='/[[:alnum:]][[:alnum:]._-]*'
SAFE_RM="(\"?((\./)?(${ARTIFACT})(${SEG})*|/(private/)?(tmp|var/tmp)(${SEG})+)/?\"?)"
if printf '%s' "$CMD" | grep -qE "^[[:space:]]*rm([[:space:]]+-[a-zA-Z]+)+([[:space:]]+${SAFE_RM})+[[:space:]]*$"; then
  exit 0
fi

# Recursive rm targeting any other absolute path (/etc, /usr, a resolved ~,
# …) — mirrors the Claude hook's absolute-path backstop. Split into command
# segments (on ; && || | & and newlines, after stripping quoted substrings)
# and only inspect segments that are themselves an rm invocation — otherwise
# an unrelated absolute path anywhere else on the line (an earlier `cd`, a
# `git log -- /abs/path`, even literal "rm -rf" text inside a search string)
# would falsely condemn a same-line rm targeting a perfectly safe operand.
# The one real cost: an rm target quoted for an embedded space loses its
# operand to the quote-strip too and falls through to the confirm-gated tier
# below instead of a hard deny.
STRIPPED_RM=$(printf '%s\n' "$CMD" | tr '\n' ';' | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
while IFS= read -r RM_SEG; do
  RM_SEG="${RM_SEG#"${RM_SEG%%[![:space:]]*}"}"
  case "$RM_SEG" in
    rm[[:space:]]*|sudo[[:space:]]rm[[:space:]]*) ;;
    *) continue ;;
  esac
  if printf '%s' "$RM_SEG" | grep -qE "^(sudo[[:space:]]+)?${RECURSIVE_RM}"; then
    IFS=' ' read -ra RM_TOKS <<< "$RM_SEG"
    for TOK in "${RM_TOKS[@]}"; do
      case "$TOK" in
        /tmp/?*|/private/tmp/?*|/var/tmp/?*) ;;
        /*)
          deny "Recursive rm targeting absolute path '$TOK' blocked. Retry only after the user confirms the exact target."
          exit 0
          ;;
      esac
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
