#!/usr/bin/env bash
# PostToolUse(Edit|Write|apply_patch) formatter. Only formats file types
# prettier owns, and only in repos that opt in via a prettier config or a
# "prettier" entry in package.json — never imposes prettier@3 defaults on
# unconfigured projects.
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CWD=$(project_dir "$INPUT")

ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || ROOT="$CWD"
CONFIG=0
for c in .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js \
         .prettierrc.cjs .prettierrc.mjs prettier.config.js prettier.config.cjs prettier.config.mjs; do
  if [[ -f "$ROOT/$c" ]]; then CONFIG=1; break; fi
done
# grep for "prettier" catches the devDep too — treated as opt-in;
# preferring the local binary below keeps the version honest.
if [[ "$CONFIG" -eq 0 && -f "$ROOT/package.json" ]] && grep -q '"prettier"' "$ROOT/package.json"; then
  CONFIG=1
fi
[[ "$CONFIG" -eq 1 ]] || exit 0

files=()
while IFS= read -r fp; do
  [[ -z "$fp" ]] && continue
  case "$fp" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.json|*.css|*.scss|*.md|*.mdx|*.yml|*.yaml|*.html)
      case "$fp" in
        /*) files+=("$fp") ;;
        *) files+=("$CWD/$fp") ;;
      esac
      ;;
  esac
done < <(extract_paths "$INPUT")

[[ ${#files[@]} -gt 0 ]] || exit 0

BIN="$ROOT/node_modules/.bin/prettier"
if [[ ! -x "$BIN" ]]; then
  # In a git worktree, ROOT is the worktree (no node_modules of its own).
  # Borrow the main checkout's prettier *binary*, but keep running from ROOT
  # (below) so the worktree's own .prettierignore/.prettierrc apply and
  # config-declared plugins resolve up the tree into the main's node_modules.
  # ponytail: assumes the worktree nests under the main checkout (factory
  # layout: <repo>/.claude/worktrees/*). A worktree created outside the repo
  # with a plugin-based config would fail plugin resolution — install deps
  # in that worktree if that ever comes up.
  MAIN=$(dirname "$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
  [[ -n "$MAIN" && -x "$MAIN/node_modules/.bin/prettier" ]] && BIN="$MAIN/node_modules/.bin/prettier"
fi

if [[ -x "$BIN" ]]; then
  # Run from ROOT so ignore/config scope is the worktree, not the main checkout
  # (whose .prettierignore may exclude .claude/worktrees/*).
  if ! OUTPUT=$(cd "$ROOT" && "$BIN" --write "${files[@]}" 2>&1); then
    post_error "Prettier failed: ${OUTPUT:0:1000}"
    exit 1
  fi
else
  post_error "Prettier is configured but the project-local formatter is unavailable. Install dependencies and retry."
  exit 1
fi
