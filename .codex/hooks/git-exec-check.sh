#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=hook-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

# Options that make git run an arbitrary program; prefix rules cannot match them
# in arbitrary positions or as --opt=value. Same patterns as the Claude
# dangerous-patterns hook (parity-checked by tests/codex-parity.sh).
JOINED=${CMD//$'\\\n'/}
GIT='git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+'
ARGS='([^;&|]*[[:space:]])?'
for PAT in \
  "${GIT}rebase[[:space:]]${ARGS}--ex" \
  "${GIT}rebase[[:space:]]${ARGS}-[a-zA-Z]*x" \
  "${GIT}fetch[[:space:]]${ARGS}--upl" \
  "${GIT}ls-remote[[:space:]]${ARGS}--(u|exe)" \
  "${GIT}push[[:space:]]${ARGS}--(rece|e)"; do
  if grep -qE "$PAT" <<< "$JOINED"; then
    deny "git option executes an arbitrary command — run it manually"
    exit 0
  fi
done
