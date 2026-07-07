#!/usr/bin/env bash
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd -P)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"

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
Usage: ./configure.sh <frontend|node> <target-project-directory>

Bootstraps a JS/TS project with linting, formatting, and quality tooling
from the dotfiles repo.

Arguments:
  <frontend|node>               Which config bucket to install
  <target-project-directory>   Path to the project to configure (must contain package.json)

What gets copied:
  .prettierrc.json             Prettier config
  .prettierignore              Prettier ignore rules
  .stryker.config.json         Stryker mutation testing config
  .dependency-cruiser.cjs      Dependency-cruiser rules
  eslint.config.mjs            ESLint flat config
  tsconfig.json                TypeScript config
  vitest.config.ts             Vitest config
  .gitignore                   Git ignore rules
  + Merges scripts from package.scaffold.json into package.json
  + Installs the latest dev dependencies via `pnpm add -D` (needs network)

Conflict handling:
  If files already exist in the target, you'll be prompted to choose:
    1) Replace — overwrite conflicts and add new files
    2) Skip — add new files only, leave existing files untouched
    3) Prompt — decide file-by-file
  Replaced files are backed up to <file>.bak first.
  The mode also applies to the package.json scripts merge: Skip keeps your
  existing script entries; Replace/Prompt overwrite them (overwritten keys
  are reported).
  Set CONFIGURE_MODE=replace|skip|prompt to skip the prompt (non-interactive).

After installing, a smoke test (typecheck + lint) runs if the target has a
src/ directory, to catch configs incompatible with freshly resolved deps.

Prerequisites:
  node      Required to merge scripts into package.json
  pnpm      Required to install dev dependencies (needs network)
HELP
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

# --- Validate ---
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <frontend|node> <target-project-directory>"
  echo "Run with --help for more information."
  exit 1
fi

STACK="$1"

if [[ "$STACK" != "frontend" && "$STACK" != "node" ]]; then
  echo "Error: Unknown stack '$STACK' (expected 'frontend' or 'node')"
  exit 1
fi

SRC_DIR="$SCRIPT_DIR/$STACK"
TARGET="$2"

if [[ ! -d "$TARGET" ]]; then
  echo "Error: Target directory does not exist: $TARGET"
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"

if [[ ! -f "$TARGET/package.json" ]]; then
  echo "Error: No package.json found in $TARGET"
  exit 1
fi

for cmd in node pnpm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd not found; required (see --help prerequisites)"
    exit 1
  fi
done

# --- Detect conflicts ---
conflicts=()

for file in "${CONFIG_FILES[@]}"; do
  src="$SRC_DIR/$file"
  dest="$TARGET/$file"
  if [[ -e "$dest" && ! -L "$dest" ]] && diff -q "$src" "$dest" &>/dev/null; then
    continue
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    conflicts+=("$file")
  fi
done

# Check .gitignore (sourced from dotfiles root)
if [[ -e "$DOTFILES_DIR/.gitignore" ]]; then
  if ! { [[ -e "$TARGET/.gitignore" && ! -L "$TARGET/.gitignore" ]] && diff -q "$DOTFILES_DIR/.gitignore" "$TARGET/.gitignore" &>/dev/null; }; then
    if [[ -e "$TARGET/.gitignore" || -L "$TARGET/.gitignore" ]]; then
      conflicts+=(".gitignore")
    fi
  fi
fi

# --- Prompt (only if conflicts detected) ---
# CONFIGURE_MODE=replace|skip|prompt skips the interactive prompt.
MODE="${CONFIGURE_MODE:-replace}"

if [[ ! "$MODE" =~ ^(replace|skip|prompt)$ ]]; then
  echo "Error: invalid CONFIGURE_MODE '$MODE' (expected replace, skip, or prompt)"
  exit 1
fi

if [[ ${#conflicts[@]} -gt 0 && -z "${CONFIGURE_MODE:-}" ]]; then
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
    if [[ -L "$dest" ]]; then
      rm -f "$dest"
    else
      rm -rf "${dest}.bak"
      mv "$dest" "${dest}.bak"
    fi
  else
    copied+=("$label")
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
}

# --- Copy config files ---
for file in "${CONFIG_FILES[@]}"; do
  if [[ -e "$SRC_DIR/$file" ]]; then
    copy_file "$SRC_DIR/$file" "$TARGET/$file" "$file"
  else
    echo "Warning: Source config file not found: $file"
  fi
done

# --- Copy .gitignore ---
if [[ -e "$DOTFILES_DIR/.gitignore" ]]; then
  copy_file "$DOTFILES_DIR/.gitignore" "$TARGET/.gitignore" ".gitignore"
fi

# --- Merge scripts + install latest dev dependencies ---
# Merge the scaffold's scripts into package.json and print its dev-dependency
# names on stdout, then let pnpm resolve+install the latest versions (so new
# projects never inherit stale pins). pnpm add also writes the lockfile.
# The merge honors MODE: skip keeps existing script entries; replace/prompt
# let the scaffold win and report which keys were overwritten.
smoke_status="not run"
if [[ -f "$SRC_DIR/package.scaffold.json" ]]; then
  DEV_DEPS="$(TARGET_PATH="$TARGET" SCAFFOLD_PATH="$SRC_DIR" MERGE_MODE="$MODE" node -e "
    const fs = require('fs');
    const target = process.env.TARGET_PATH + '/package.json';
    const pkg = JSON.parse(fs.readFileSync(target, 'utf8'));
    const scaffold = JSON.parse(fs.readFileSync(process.env.SCAFFOLD_PATH + '/package.scaffold.json', 'utf8'));
    const existing = pkg.scripts || {};
    if (process.env.MERGE_MODE === 'skip') {
      pkg.scripts = Object.assign({}, scaffold.scripts, existing);
    } else {
      const overwritten = Object.keys(scaffold.scripts)
        .filter(k => k in existing && existing[k] !== scaffold.scripts[k]);
      if (overwritten.length) {
        process.stderr.write('Overwrote existing scripts: ' + overwritten.join(', ') + '\n');
      }
      pkg.scripts = Object.assign({}, existing, scaffold.scripts);
    }
    fs.writeFileSync(target, JSON.stringify(pkg, null, 2) + '\n');
    process.stdout.write((scaffold.scaffoldDevDependencies || []).join(' '));
  ")"
  echo "Merged scripts into package.json"
  if [[ -n "$DEV_DEPS" ]]; then
    echo "Installing latest dev dependencies with pnpm..."
    # shellcheck disable=SC2086 # intentional word-splitting: one arg per package
    pnpm --dir "$TARGET" add -D $DEV_DEPS
  fi

  # Smoke test: deps were just resolved to latest, so prove the copied configs
  # still work. Needs source files — tsc/eslint error on an empty project.
  if [[ -d "$TARGET/src" ]]; then
    echo "Running smoke test (typecheck + lint)..."
    if pnpm --dir "$TARGET" run typecheck && pnpm --dir "$TARGET" run lint; then
      smoke_status="ok"
    else
      smoke_status="FAILED (configs may be incompatible with latest deps)"
    fi
  else
    smoke_status="skipped (no src/)"
  fi
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

echo "Smoke test: $smoke_status"
echo ""
echo "Done."
