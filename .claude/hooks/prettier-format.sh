#!/bin/bash
# PostToolUse(Edit|Write) formatter. Only formats file types prettier owns, and
# only in repos that opt in via a prettier config — never imposes prettier@3
# defaults on unconfigured projects (this is what used to re-pad markdown
# tables in every repo and cost an npx spin-up on every single edit).
set -uo pipefail
FILE=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo '{"suppressOutput": true}'
  exit 0
fi
case "$FILE" in
  *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.json|*.css|*.scss|*.md|*.mdx|*.yaml|*.yml|*.html) ;;
  *) echo '{"suppressOutput": true}'; exit 0 ;;
esac
DIR=$(dirname "$FILE")
ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || ROOT="$DIR"
CONFIG=0
for c in .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js \
         .prettierrc.cjs .prettierrc.mjs prettier.config.js prettier.config.cjs prettier.config.mjs; do
  if [ -f "$ROOT/$c" ]; then CONFIG=1; break; fi
done
# ponytail: grep for "prettier" catches the devDep too — treated as opt-in;
# preferring the local binary keeps the version honest.
if [ "$CONFIG" = 0 ] && [ -f "$ROOT/package.json" ] && grep -q '"prettier"' "$ROOT/package.json"; then
  CONFIG=1
fi
if [ "$CONFIG" = 1 ]; then
  if [ -x "$ROOT/node_modules/.bin/prettier" ]; then
    "$ROOT/node_modules/.bin/prettier" --write "$FILE" >/dev/null 2>&1
  else
    npx --yes prettier@3 --write "$FILE" >/dev/null 2>&1
  fi
fi
echo '{"suppressOutput": true}'
