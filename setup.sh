#!/usr/bin/env bash
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR"

# --- Backup suffix ---
BACKUP_SUFFIX=".backup.$(date +%Y%m%d%H%M%S)"

# --- Files to symlink: source (relative to DOTFILES_DIR) -> target (in HOME) ---
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
backed_up=()
skipped=()

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
# Section 2: Create Symlinks
# =============================================================================

info "Creating symlinks..."

for file in "${DOTFILES[@]}"; do
  src="$DOTFILES_DIR/$file"
  dest="$HOME/$file"

  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    skipped+=("$file")
    success "$file already linked"
    continue
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    backup="${dest}${BACKUP_SUFFIX}"
    mv "$dest" "$backup"
    backed_up+=("$file -> $backup")
    warn "$file backed up to $backup"
  fi

  ln -s "$src" "$dest"
  linked+=("$file")
  success "$file linked"
done

# =============================================================================
# Section 3: Create Required Directories
# =============================================================================

mkdir -p ~/.vim/undodir

# =============================================================================
# Section 4: Install Homebrew + Brewfile
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
# Section 5: Install Vim Plugins
# =============================================================================

info "Installing vim plugins..."
vim +PlugInstall +qall

ycm_status="installed"
ycm_dir="$HOME/.vim/plugged/YouCompleteMe"
if [[ -d "$ycm_dir" ]]; then
  info "Compiling YouCompleteMe..."
  python3 "$ycm_dir/install.py" --ts-completer
else
  warn "YouCompleteMe directory not found, skipping compilation"
  ycm_status="skipped (not found)"
fi

# =============================================================================
# Section 6: Summary
# =============================================================================

echo ""
echo "=== Summary ==="

if [[ ${#linked[@]} -gt 0 ]]; then
  echo "Linked:"
  for f in "${linked[@]}"; do echo "  + $f"; done
fi

if [[ ${#backed_up[@]} -gt 0 ]]; then
  echo "Backed up:"
  for f in "${backed_up[@]}"; do echo "  ~ $f"; done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Skipped (already correct):"
  for f in "${skipped[@]}"; do echo "  - $f"; done
fi

echo "Homebrew: $brew_status"
echo "Vim plugins: installed"
echo "YouCompleteMe: $ycm_status"
echo ""
echo "Done."
