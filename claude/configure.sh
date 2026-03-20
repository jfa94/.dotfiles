#!/usr/bin/env bash
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"

# --- Config file list ---
CONFIG_FILES=(
  .gitignore
  .prettierrc.json
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

Bootstraps a project with Claude Code configuration, linting, and
quality tooling from the dotfiles repo.

Arguments:
  <target-project-directory>   Path to the project to configure

What gets copied:
  .claude/*                    Claude Code settings, CLAUDE.md, run-factory.sh
  .github/workflows/quality-gate.yml  Quality gate CI workflow
  .gitignore                   Git ignore rules
  .prettierrc.json             Prettier config
  .stryker.config.json         Stryker mutation testing config
  .dependency-cruiser.cjs      Dependency-cruiser rules
  eslint.config.mjs            ESLint flat config
  tsconfig.json                TypeScript config
  vitest.config.ts             Vitest config

Additionally:
  - Merges scripts from package.scripts.json into the target's package.json
  - Makes run-factory.sh executable in the target

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

# Resolve to absolute path
TARGET="$(cd "$TARGET" && pwd)"

# --- Detect conflicts ---
conflicts=()

# Check .claude/ files
while IFS= read -r -d '' file; do
  rel="${file#"$SCRIPT_DIR"/}"
  if [[ -e "$TARGET/.claude/$rel" ]]; then
    conflicts+=(".claude/$rel")
  fi
done < <(find "$SCRIPT_DIR" -type f ! -name "configure.sh" -print0)

# Check config files
for file in "${CONFIG_FILES[@]}"; do
  if [[ -e "$TARGET/$file" ]]; then
    conflicts+=("$file")
  fi
done

# Check workflow file
if [[ -e "$TARGET/.github/workflows/quality-gate.yml" ]]; then
  conflicts+=(".github/workflows/quality-gate.yml")
fi

# --- Prompt (only if conflicts detected) ---
MODE="replace"  # default: no conflicts, copy everything

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
  read -rp "Choose [1/2/3]: " choice

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

  if [[ -e "$dest" ]]; then
    if [[ "$MODE" == "skip" ]]; then
      skipped+=("$label")
      return
    elif [[ "$MODE" == "prompt" ]]; then
      read -rp "  $label already exists. Replace? [y/n]: " answer
      if [[ "$answer" != "y" ]]; then
        skipped+=("$label")
        return
      fi
      replaced+=("$label")
    else
      replaced+=("$label")
    fi
  else
    copied+=("$label")
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
}

# --- Copy .claude/ directory ---
while IFS= read -r -d '' file; do
  rel="${file#"$SCRIPT_DIR"/}"
  copy_file "$file" "$TARGET/.claude/$rel" ".claude/$rel"
done < <(find "$SCRIPT_DIR" -type f ! -name "configure.sh" -print0)

# --- Make run-factory.sh executable ---
if [[ -f "$TARGET/.claude/run-factory.sh" ]]; then
  chmod +x "$TARGET/.claude/run-factory.sh"
fi

# --- Copy workflow file to .github/workflows/ ---
WORKFLOW_SRC="$SCRIPT_DIR/quality-gate.yml"
if [[ -f "$WORKFLOW_SRC" ]]; then
  copy_file "$WORKFLOW_SRC" "$TARGET/.github/workflows/quality-gate.yml" ".github/workflows/quality-gate.yml"
fi

# --- Copy config files ---
for file in "${CONFIG_FILES[@]}"; do
  if [[ -e "$DOTFILES_DIR/$file" ]]; then
    copy_file "$DOTFILES_DIR/$file" "$TARGET/$file" "$file"
  else
    echo "Warning: Source config file not found: $file"
  fi
done

# --- Replace package.json scripts ---
if [[ -f "$TARGET/package.json" ]]; then
  if [[ -f "$DOTFILES_DIR/package.scripts.json" ]]; then
    node -e "
      const fs = require('fs');
      const pkg = JSON.parse(fs.readFileSync('$TARGET/package.json', 'utf8'));
      const scripts = JSON.parse(fs.readFileSync('$DOTFILES_DIR/package.scripts.json', 'utf8'));
      pkg.scripts = scripts.scripts;
      fs.writeFileSync('$TARGET/package.json', JSON.stringify(pkg, null, 2) + '\n');
    "
    echo "Updated scripts in package.json"
  else
    echo "Warning: package.scripts.json not found, skipping scripts update"
  fi
else
  echo "Warning: No package.json found in target, skipping scripts update"
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
