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

if [[ -x "$ROOT/node_modules/.bin/prettier" ]]; then
  "$ROOT/node_modules/.bin/prettier" --write "${files[@]}" >/dev/null 2>&1 || true
elif command -v npx >/dev/null 2>&1; then
  npx --yes prettier@3 --write "${files[@]}" >/dev/null 2>&1 || true
fi
