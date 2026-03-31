#!/usr/bin/env bash
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd -P)"

# --- Config file list ---
CONFIG_FILES=(
  .prettierrc.json
  .prettierignore
  .stryker.config.json
  .dependency-cruiser.cjs
  eslint.config.mjs
  tsconfig.json
  vitest.config.ts
)

# --- Help ---
show_help() {
  cat <<'HELP'
Usage: ./configure.sh <target-project-directory>

Bootstraps a JS/TS project with linting, formatting, and quality tooling
from the dotfiles repo.

Arguments:
  <target-project-directory>   Path to the project to configure (must contain package.json)

What gets copied:
  .prettierrc.json             Prettier config
  .prettierignore              Prettier ignore rules
  .stryker.config.json         Stryker mutation testing config
  .dependency-cruiser.cjs      Dependency-cruiser rules
  eslint.config.mjs            ESLint flat config
  tsconfig.json                TypeScript config
  vitest.config.ts             Vitest config
  + Merges scripts and devDependencies from package.scaffold.json into package.json

Conflict handling:
  If files already exist in the target, you'll be prompted to choose:
    1) Replace — overwrite conflicts and add new files
    2) Skip — add new files only, leave existing files untouched
    3) Prompt — decide file-by-file

Prerequisites:
  node      Required for package.json scripts merge
HELP
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

# --- Validate ---
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <target-project-directory>"
  echo "Run with --help for more information."
  exit 1
fi

TARGET="$1"

if [[ ! -d "$TARGET" ]]; then
  echo "Error: Target directory does not exist: $TARGET"
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"

if [[ ! -f "$TARGET/package.json" ]]; then
  echo "Error: No package.json found in $TARGET"
  exit 1
fi

# --- Detect conflicts ---
conflicts=()

for file in "${CONFIG_FILES[@]}"; do
  src="$SCRIPT_DIR/$file"
  dest="$TARGET/$file"
  if [[ -e "$dest" && ! -L "$dest" ]] && diff -q "$src" "$dest" &>/dev/null; then
    continue
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    conflicts+=("$file")
  fi
done

# --- Prompt (only if conflicts detected) ---
MODE="replace"

if [[ ${#conflicts[@]} -gt 0 ]]; then
  echo "The following files already exist in the target:"
  for c in "${conflicts[@]}"; do
    echo "  - $c"
  done
  echo ""
  echo "How would you like to handle conflicts?"
  echo "  1) Replace — overwrite conflicts and add new files"
  echo "  2) Skip — add new files only, leave existing files untouched"
  echo "  3) Prompt — decide file-by-file"
  echo ""
  read -rp "Choose [1/2/3]: " choice < /dev/tty

  case "$choice" in
    1) MODE="replace" ;;
    2) MODE="skip" ;;
    3) MODE="prompt" ;;
    *)
      echo "Invalid choice. Aborting."
      exit 1
      ;;
  esac
fi

# --- Tracking ---
copied=()
skipped=()
replaced=()

# --- Helper: copy a file respecting conflict mode ---
copy_file() {
  local src="$1"
  local dest="$2"
  local label="$3"

  if [[ -e "$dest" && ! -L "$dest" ]] && diff -q "$src" "$dest" &>/dev/null; then
    skipped+=("$label (already up to date)")
    return
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$MODE" == "skip" ]]; then
      skipped+=("$label")
      return
    elif [[ "$MODE" == "prompt" ]]; then
      read -rp "  $label already exists. Replace? [y/n]: " answer < /dev/tty
      if [[ "$answer" != "y" ]]; then
        skipped+=("$label")
        return
      fi
      replaced+=("$label")
    else
      replaced+=("$label")
    fi
    rm -f "$dest"
  else
    copied+=("$label")
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
}

# --- Copy config files ---
for file in "${CONFIG_FILES[@]}"; do
  if [[ -e "$SCRIPT_DIR/$file" ]]; then
    copy_file "$SCRIPT_DIR/$file" "$TARGET/$file" "$file"
  else
    echo "Warning: Source config file not found: $file"
  fi
done

# --- Merge package.scaffold.json ---
if [[ -f "$SCRIPT_DIR/package.scaffold.json" ]]; then
  TARGET_PATH="$TARGET" SCAFFOLD_PATH="$SCRIPT_DIR" node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync(process.env.TARGET_PATH + '/package.json', 'utf8'));
    const scaffold = JSON.parse(fs.readFileSync(process.env.SCAFFOLD_PATH + '/package.scaffold.json', 'utf8'));
    pkg.scripts = Object.assign({}, pkg.scripts || {}, scaffold.scripts);
    pkg.devDependencies = Object.assign({}, pkg.devDependencies || {}, scaffold.devDependencies);
    fs.writeFileSync(process.env.TARGET_PATH + '/package.json', JSON.stringify(pkg, null, 2) + '\n');
  "
  echo "Merged scripts and devDependencies into package.json"
else
  echo "Warning: package.scaffold.json not found, skipping scripts merge"
fi

# --- Summary ---
echo ""
echo "=== Summary ==="

if [[ ${#copied[@]} -gt 0 ]]; then
  echo "Copied:"
  for f in "${copied[@]}"; do echo "  + $f"; done
fi

if [[ ${#replaced[@]} -gt 0 ]]; then
  echo "Replaced:"
  for f in "${replaced[@]}"; do echo "  ~ $f"; done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Skipped (conflict):"
  for f in "${skipped[@]}"; do echo "  - $f"; done
fi

if [[ ${#copied[@]} -eq 0 && ${#replaced[@]} -eq 0 && ${#skipped[@]} -eq 0 ]]; then
  echo "No files were processed."
fi

echo ""
echo "Done."
