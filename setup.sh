#!/usr/bin/env bash
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR"

# --- Files to symlink ---
DOTFILES=(
  .zshrc
  .zprofile
  .gitconfig
  .gitignore
  .vimrc
  .ideavimrc
  .tmux.conf
)

# --- Helpers ---
info()    { printf '[INFO] %s\n' "$1"; }
success() { printf '[OK]   %s\n' "$1"; }
warn()    { printf '[WARN] %s\n' "$1"; }
error()   { printf '[ERR]  %s\n' "$1" >&2; }

# --- Tracking ---
linked=()
replaced=()
skipped=()

# --- Mode-aware symlink creation ---
link_file() {
  local src="$1"
  local dest="$2"
  local label="$3"

  if [[ ! -e "$src" ]]; then
    warn "$label source not found, skipping"
    skipped+=("$label (source missing)")
    return
  fi

  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    skipped+=("$label")
    success "$label already linked"
    return
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$MODE" == "skip" ]]; then
      skipped+=("$label")
      success "$label skipped (conflict)"
      return
    elif [[ "$MODE" == "prompt" ]]; then
      read -rp "  $label already exists. Replace? [y/n]: " answer < /dev/tty
      if [[ "$answer" != "y" ]]; then
        skipped+=("$label")
        success "$label skipped (user chose)"
        return
      fi
    fi
    rm -f "$dest"
    replaced+=("$label")
  fi

  ln -s "$src" "$dest"
  linked+=("$label")
  success "$label linked"
}

# =============================================================================
# Section 1: Preflight Checks
# =============================================================================

if [[ "$(uname -s)" != "Darwin" ]]; then
  error "This script is intended for macOS only."
  exit 1
fi

if ! xcode-select -p &>/dev/null; then
  error "Xcode Command Line Tools not found. Install them with:"
  echo "  xcode-select --install"
  exit 1
fi

# =============================================================================
# Section 2: Conflict Detection
# =============================================================================

conflicts=()

for file in "${DOTFILES[@]}"; do
  src="$DOTFILES_DIR/$file"
  dest="$HOME/$file"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    continue
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    conflicts+=("$file")
  fi
done

while IFS= read -r -d '' file; do
  rel="${file#"$DOTFILES_DIR"/.claude/}"
  dest="$HOME/.claude/$rel"
  if [[ -L "$dest" && "$(readlink "$dest")" == "$file" ]]; then
    continue
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    conflicts+=("~/.claude/$rel")
  fi
done < <(find "$DOTFILES_DIR/.claude" -type f -not -name "*.local.*" -print0)

MODE="replace"
if [[ ${#conflicts[@]} -gt 0 ]]; then
  echo "The following files already exist and will need replacement:"
  for c in "${conflicts[@]}"; do
    echo "  - $c"
  done
  echo ""
  echo "How would you like to handle conflicts?"
  echo "  1) Replace — overwrite all conflicts"
  echo "  2) Skip — only link files that don't exist yet"
  echo "  3) Prompt — decide file-by-file"
  echo ""
  read -rp "Choose [1/2/3]: " choice < /dev/tty

  case "$choice" in
    1) MODE="replace" ;;
    2) MODE="skip" ;;
    3) MODE="prompt" ;;
    *)
      error "Invalid choice. Aborting."
      exit 1
      ;;
  esac
fi

# =============================================================================
# Section 3: Create Symlinks
# =============================================================================

info "Creating symlinks..."

for file in "${DOTFILES[@]}"; do
  link_file "$DOTFILES_DIR/$file" "$HOME/$file" "$file"
done

# =============================================================================
# Section 4: Claude Code Symlinks
# =============================================================================

info "Creating Claude Code symlinks..."
mkdir -p ~/.claude

while IFS= read -r -d '' file; do
  rel="${file#"$DOTFILES_DIR"/.claude/}"
  dest="$HOME/.claude/$rel"
  mkdir -p "$(dirname "$dest")"
  link_file "$file" "$dest" "~/.claude/$rel"
done < <(find "$DOTFILES_DIR/.claude" -type f -not -name "*.local.*" -print0)

# =============================================================================
# Section 5: Create Required Directories
# =============================================================================

mkdir -p ~/.vim/undodir

# =============================================================================
# Section 6: Install Homebrew + Brewfile
# =============================================================================

brew_status="already installed"

if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  brew_status="freshly installed"

  # Ensure brew is on PATH for the rest of this script
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

info "Running brew bundle..."
brew bundle --file="$DOTFILES_DIR/Brewfile"

# =============================================================================
# Section 7: Install Vim Plugins
# =============================================================================

plugged_dir="$HOME/.vim/plugged"
vim_plugins_status="installed"
if [[ -d "$plugged_dir" && -n "$(ls -A "$plugged_dir" 2>/dev/null)" ]]; then
  vim_plugins_status="already installed"
  success "Vim plugins already installed, skipping"
else
  info "Installing vim plugins..."
  vim +PlugInstall +qall
fi

ycm_status="installed"
ycm_dir="$HOME/.vim/plugged/YouCompleteMe"
if [[ -d "$ycm_dir" ]]; then
  if compgen -G "$ycm_dir/third_party/ycmd/ycm_core.*.so" > /dev/null 2>&1; then
    ycm_status="already compiled"
    success "YouCompleteMe already compiled, skipping"
  else
    info "Compiling YouCompleteMe..."
    python3 "$ycm_dir/install.py" --ts-completer
  fi
else
  warn "YouCompleteMe directory not found, skipping compilation"
  ycm_status="skipped (not found)"
fi

# =============================================================================
# Section 8: Summary
# =============================================================================

echo ""
echo "=== Summary ==="

if [[ ${#linked[@]} -gt 0 ]]; then
  echo "Linked:"
  for f in "${linked[@]}"; do echo "  + $f"; done
fi

if [[ ${#replaced[@]} -gt 0 ]]; then
  echo "Replaced:"
  for f in "${replaced[@]}"; do echo "  ~ $f"; done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Skipped (already correct):"
  for f in "${skipped[@]}"; do echo "  - $f"; done
fi

echo "Homebrew: $brew_status"
echo "Vim plugins: $vim_plugins_status"
echo "YouCompleteMe: $ycm_status"
echo ""
echo "Done."
