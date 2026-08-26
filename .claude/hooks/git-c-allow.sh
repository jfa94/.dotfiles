#!/bin/bash
set -euo pipefail
# Replaces the 32 `Bash(git -C * <sub> *)` allow rules, which the startup linter
# flags: a wildcard before the subcommand also matches injected options such as
# `-c core.fsmonitor=…` or `--exec-path`, i.e. arbitrary command execution. This
# hook allows only commands where EVERY chained segment is exactly
# `git -C <dir> <sub> …` with an allow-listed subcommand — nothing between `git`
# and `-C`, nothing between <dir> and <sub>.
#
# Safe by precedence, not trust: settings deny/ask rules and sibling hook
# deny/ask (dangerous-patterns-check, pre-commit-check, pre-push-check) always
# beat a hook allow. Anything this hook doesn't match falls through to the
# normal permission prompt — the failure mode is a prompt, never a false allow.
PAYLOAD=$(cat)
# A hook allow resolves on a path with no plan-mode branch (see
# posthog-readonly-allow.sh), so without this guard `git -C … commit` would run
# during plan mode. Fall through instead.
MODE=$(jq -r '.permission_mode // empty' <<<"$PAYLOAD")
[ "$MODE" = "plan" ] && exit 0
CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD")
[ -n "$CMD" ] || exit 0

# Substitution/redirect can smuggle side effects past the per-segment match.
case $CMD in (*'$('*|*'`'*|*'>'*|*'<'*) exit 0;; esac

SUBS='add|mv|commit|checkout|branch|stash|push|diff|log|show|check-ignore|blame|fetch|rev-parse|shortlog|reflog|describe|ls-files|ls-remote|ls-tree|merge-base|rebase|worktree|status'
TWO='remote -v|config --get|config --list|cherry -v|tag -l'

# Split on chain operators (&&, ||, ;, |, &, newline — tr splits doubles into
# an empty segment, skipped); every non-empty segment must match. An operator
# inside quotes mangles its segment, which then fails the match and falls
# through — a prompt, never a false allow.
MATCHED=0
while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  [ -n "$seg" ] || continue
  printf '%s' "$seg" | grep -qE "^git -C [^- ][^ ]* (($SUBS)|($TWO))( |\$)" || exit 0
  MATCHED=1
done < <(printf '%s\n' "$CMD" | tr ';|&\n' '\n\n\n\n')
[ "$MATCHED" -eq 1 ] || exit 0

jq -cn '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"git -C with allow-listed subcommand in every segment (replaces linted wildcard rules)."}}'
