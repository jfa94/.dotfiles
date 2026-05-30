#!/usr/bin/env bash
set -uo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CWD=$(project_dir "$INPUT")
[[ -f "$CWD/package.json" ]] || exit 0

if ! command -v pnpm >/dev/null 2>&1; then
  exit 0
fi

if [[ ! -x "$CWD/node_modules/.bin/prettier" ]] && ! grep -q '"prettier"' "$CWD/package.json"; then
  exit 0
fi

files=()
while IFS= read -r fp; do
  [[ -z "$fp" ]] && continue
  case "$fp" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.json|*.css|*.scss|*.md|*.mdx|*.yml|*.yaml)
      case "$fp" in
        /*) files+=("$fp") ;;
        *) files+=("$CWD/$fp") ;;
      esac
      ;;
  esac
done < <(extract_paths "$INPUT")

[[ ${#files[@]} -gt 0 ]] || exit 0

(cd "$CWD" && pnpm exec prettier --write "${files[@]}") >/dev/null 2>&1 || true
