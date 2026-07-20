#!/bin/bash
set -euo pipefail
CMD=$(cat | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# Matches any rm whose flags include r, in any grouping/order
# (-rf, -fr, -Rf, -r -f, -f -r): flag groups may precede and follow the r-group.
RECURSIVE_RM='rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*r[a-zA-Z]*([[:space:]]+-[a-zA-Z]+)*'

# Policy denies — mirrored from settings.json permissions.deny. They live in BOTH:
# settings.json is primary, but the CLI can strip that array on auto-rewrite, so
# these are duplicated here as a backstop (see anthropics/claude-code#22659,
# #51843, #6699). The push-refspec pattern ([^;&|]* bounds it to the same
# command) catches `git push origin +branch` force-pushes flag rules miss.
for PAT in \
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
  if printf '%s' "$CMD" | grep -qE "$PAT"; then
    jq -cn --arg r "Blocked by policy: $PAT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
done

# Dangerous patterns. rm targeting / tolerates any flag order; chmod covers
# -R 777; curl/wget pipes only deny when the pipe target is an actual shell
# word (sh/bash/zsh/dash, optionally sudo) — not shasum, .shell, etc.
for PAT in \
  "${RECURSIVE_RM}[[:space:]]+/([[:space:]]|\$|\\*)" \
  'DROP TABLE' \
  'DROP DATABASE' \
  'DROP SCHEMA' \
  'TRUNCATE[[:space:]]+TABLE' \
  'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*777' \
  '(curl|wget)[^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'; do
  if printf '%s' "$CMD" | grep -qiE "$PAT"; then
    jq -cn --arg r "Blocked dangerous command pattern: $PAT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
done

# Backstop for shell writes that bypass the Edit/Write protected-files gate:
# redirects, tee, sed -i, mv/cp/rm targeting .env* / credentials / secrets paths.
# Target-anchored: the secret path must be the write op's operand, so reads with
# incidental redirects (`source .env.e2e ... 2>&1 | tail`) pass silently.
# Ask (not deny): mirrors protected-files' confirm flow; example/sample/template exempt.
ENVBASE='\.env[.[:alnum:]_-]*'
PFX='[^[:space:]|;&<>]*'
SECRET="(${ENVBASE}|${PFX}/${ENVBASE}|secrets?/|${PFX}/secrets?/|${PFX}credentials)"
GAP='([^;&|<>]*[[:space:]])?'
if printf '%s' "$CMD" | grep -qiE \
    ">>?[[:space:]]*${SECRET}|(^|[[:space:]|;&])tee[[:space:]]+${GAP}${SECRET}|(^|[[:space:]|;&])sed[[:space:]]+[^;&|<>]*-i${GAP}${SECRET}|(^|[[:space:]|;&])(mv|cp|rm)[[:space:]]+${GAP}${SECRET}" \
  && ! printf '%s' "$CMD" | grep -qiE '\.env[^[:space:]]*\.(example|sample|template)'; then
  jq -cn --arg r 'shell write touching .env/credentials/secrets — confirm (protected-files backstop)' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
  exit 0
fi

# Ask tier: any recursive+force rm (flag order/grouping tolerant).
if printf '%s' "$CMD" | grep -qiE "$RECURSIVE_RM" \
  && printf '%s' "$CMD" | grep -qiE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*f'; then
  jq -cn --arg r 'recursive force rm detected — confirm before running' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$r}}'
fi
