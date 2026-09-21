#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -r "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for path in instructions/AGENTS.md instructions/frontend.md instructions/backend.md CLAUDE.md; do
  git -C "$ROOT" ls-files --error-unmatch "$path" >/dev/null || fail "$path not tracked"
done
for path in .claude/CLAUDE.md .codex/AGENTS.md .claude/frontend.md .claude/backend.md; do
  if git -C "$ROOT" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    fail "$path still tracked"
  fi
done
[[ $(cat "$ROOT/CLAUDE.md") == '@AGENTS.md' ]] || fail 'root import stub changed'
[[ $(wc -c < "$ROOT/instructions/AGENTS.md") -lt 32768 ]] || fail 'global instructions too large'
grep -qx '## Claude Code' "$ROOT/instructions/AGENTS.md"
grep -qx '## Codex' "$ROOT/instructions/AGENTS.md"
sed -n '/^## Claude Code$/,/^## Codex$/p' "$ROOT/instructions/AGENTS.md" | grep -qF 'exploration or research spanning 3+ files or pages'
sed -n '/^## Codex$/,$p' "$ROOT/instructions/AGENTS.md" | grep -qF 'Use subagents only for independent, bounded work'
grep -qF 'This includes applying existing migrations' "$ROOT/instructions/AGENTS.md"
grep -qF 'Never drop a database table without explicit same-turn confirmation' "$ROOT/instructions/AGENTS.md"
grep -qF 'Supabase remains list/read-only' "$ROOT/instructions/AGENTS.md"

mkdir -p "$WORK/repo/instructions" "$WORK/repo/.claude" "$WORK/repo/.codex"
printf 'shared rules\n' > "$WORK/repo/instructions/AGENTS.md"
export DOTFILES_DIR="$WORK/repo"

# Exercise the production helpers, conflict detection, and pruning without installers.
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'linked=(); replaced=(); skipped=()'
  printf '%s\n' 'success() { echo "$*"; }' 'info() { echo "$*"; }' 'warn() { echo "$*" >&2; }' 'error() { echo "$*" >&2; }'
  sed -n '/^AGENT_INSTRUCTIONS=/p; /^AGENT_INSTRUCTION_DESTS=/p' "$ROOT/setup.sh"
  sed -n '/^link_file() {/,/^}/p' "$ROOT/setup.sh"
  sed -n '/^link_agent_instructions() {/,/^}/p' "$ROOT/setup.sh"
  cat <<'DRIVER'
MODE=$2
case "$1" in
conflicts)
conflicts=()
DRIVER
  sed -n '/^# Global instruction conflicts /,/^# End global instruction conflicts/p' "$ROOT/setup.sh"
  cat <<'DRIVER'
printf "%s\n" "${conflicts[@]-}"
;;
prune)
DRIVER
  # shellcheck disable=SC2016 # Match literal $HOME in the production source.
  sed -n '/^# Prune symlinks/,/^find "\$HOME\/.codex\/hooks"/{ /^find "\$HOME\/.codex\/hooks"/!p; }' "$ROOT/setup.sh"
  printf '%s\n' ';;' 'link) link_agent_instructions ;;' 'esac'
} > "$WORK/driver.sh"

run() { env HOME="$WORK/$1" bash "$WORK/driver.sh" "$2" "${3:-skip}"; }
check_links() {
  for path in .claude/CLAUDE.md .codex/AGENTS.md; do
    [[ $(readlink "$WORK/$1/$path") == "$DOTFILES_DIR/instructions/AGENTS.md" ]] || fail "$1: $path target"
    [[ -f "$WORK/$1/$path" ]] || fail "$1: $path dangling"
  done
}

run fresh link
check_links fresh
[[ -z $(run fresh conflicts) ]] || fail 'correct links reported as conflicts'
run fresh link > "$WORK/repeat"
[[ $(grep -c 'already linked' "$WORK/repeat") == 2 ]] || fail 'repeat not idempotent'

for state in valid dangling; do
  mkdir -p "$WORK/$state/.claude" "$WORK/$state/.codex"
  for path in .claude/CLAUDE.md .codex/AGENTS.md; do
    [[ "$state" != valid ]] || printf 'old\n' > "$DOTFILES_DIR/$path"
    ln -s "$DOTFILES_DIR/$path" "$WORK/$state/$path"
  done
  [[ -z $(run "$state" conflicts) ]] || fail 'legacy links treated as conflicts'
  run "$state" link > "$WORK/migration"
  check_links "$state"
  [[ $(grep -c 'legacy link migrated' "$WORK/migration") == 2 ]] || fail 'migration not reported'
  if [[ "$state" == valid ]]; then
    rm "$DOTFILES_DIR/.claude/CLAUDE.md" "$DOTFILES_DIR/.codex/AGENTS.md"
  fi
done

for kind in file directory symlink; do
  mkdir -p "$WORK/$kind/.claude" "$WORK/$kind/.codex"
  for path in .claude/CLAUDE.md .codex/AGENTS.md; do
    dest="$WORK/$kind/$path"
    case "$kind" in
      file) printf 'custom\n' > "$dest" ;;
      directory) mkdir "$dest"; printf 'custom\n' > "$dest/content" ;;
      symlink) ln -s "$WORK/unrelated" "$dest" ;;
    esac
  done
  [[ $(run "$kind" conflicts | grep -c '^~/') == 2 ]] || fail "$kind conflict not detected"
  run "$kind" link skip
  for path in .claude/CLAUDE.md .codex/AGENTS.md; do
    dest="$WORK/$kind/$path"
    case "$kind" in
      file) [[ $(cat "$dest") == custom ]] || fail 'custom file overwritten' ;;
      directory) [[ $(cat "$dest/content") == custom ]] || fail 'custom directory overwritten' ;;
      symlink) [[ $(readlink "$dest") == "$WORK/unrelated" ]] || fail 'custom symlink overwritten' ;;
    esac
  done
  run "$kind" link replace
  check_links "$kind"
  for path in .claude/CLAUDE.md .codex/AGENTS.md; do
    dest="$WORK/$kind/$path"
    case "$kind" in
      file) [[ $(cat "$dest.bak") == custom ]] || fail 'file backup lost' ;;
      directory) [[ $(cat "$dest.bak/content") == custom ]] || fail 'directory backup lost' ;;
      symlink) [[ ! -e "$dest.bak" && ! -L "$dest.bak" ]] || fail 'symlink unexpectedly backed up' ;;
    esac
  done
done

# A controlling terminal is necessary because the real prompt reads /dev/tty.
python3 - "$WORK" <<'PY'
import errno, os, pty, select, signal, sys, time
from pathlib import Path
work = Path(sys.argv[1])
for choice in ('n', 'y'):
    home = work / ('prompt-' + choice)
    for rel in ('.claude/CLAUDE.md', '.codex/AGENTS.md'):
        path = home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('custom\n')
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe('bash', ['bash', str(work / 'driver.sh'), 'link', 'prompt'], dict(os.environ, HOME=str(home)))
    output = b''
    prompts = 0
    deadline = time.monotonic() + 15
    try:
        while True:
            if time.monotonic() > deadline:
                os.kill(pid, signal.SIGKILL)
                raise AssertionError('prompt timed out: ' + repr(output))
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            try:
                data = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                break
            if not data:
                break
            output += data
            while output.count(b'Replace? [y/n]: ') > prompts:
                os.write(fd, (choice + '\n').encode())
                prompts += 1
    finally:
        os.close(fd)
        _, status = os.waitpid(pid, 0)
    assert status == 0 and prompts == 2, repr(output)
    for rel in ('.claude/CLAUDE.md', '.codex/AGENTS.md'):
        path = home / rel
        assert path.is_symlink() == (choice == 'y')
        saved = path.with_name(path.name + '.bak') if choice == 'y' else path
        assert saved.read_text() == 'custom\n'
PY

mkdir -p "$WORK/missing/.claude" "$WORK/missing/.codex"
ln -s "$DOTFILES_DIR/.claude/CLAUDE.md" "$WORK/missing/.claude/CLAUDE.md"
printf 'custom\n' > "$WORK/missing/.codex/AGENTS.md"
mv "$DOTFILES_DIR/instructions/AGENTS.md" "$DOTFILES_DIR/instructions/saved.md"
if run missing link replace > "$WORK/missing-output" 2>&1; then fail 'missing source succeeded'; fi
grep -qF 'source not found' "$WORK/missing-output"
[[ $(readlink "$WORK/missing/.claude/CLAUDE.md") == "$DOTFILES_DIR/.claude/CLAUDE.md" ]] || fail 'missing source changed legacy link'
[[ $(cat "$WORK/missing/.codex/AGENTS.md") == custom ]] || fail 'missing source replaced custom file'
mv "$DOTFILES_DIR/instructions/saved.md" "$DOTFILES_DIR/instructions/AGENTS.md"

mkdir -p "$WORK/prune/.claude" "$WORK/prune/.codex" "$WORK/prune/.config"
for name in frontend.md backend.md; do
  ln -s "$DOTFILES_DIR/.claude/$name" "$WORK/prune/.claude/$name"
done
ln -s "$WORK/unrelated" "$WORK/prune/.claude/custom-link"
printf 'custom\n' > "$WORK/prune/.claude/custom-file"
run prune prune
for name in frontend.md backend.md; do
  [[ ! -L "$WORK/prune/.claude/$name" ]] || fail 'retired link survived'
done
[[ -L "$WORK/prune/.claude/custom-link" ]] || fail 'unrelated link pruned'
[[ $(cat "$WORK/prune/.claude/custom-file") == custom ]] || fail 'custom file pruned'
printf 'custom\n' > "$WORK/prune/.claude/frontend.md"
ln -s "$WORK/unrelated" "$WORK/prune/.claude/backend.md"
run prune prune
[[ $(cat "$WORK/prune/.claude/frontend.md") == custom ]] || fail 'custom frontend guidance pruned'
[[ $(readlink "$WORK/prune/.claude/backend.md") == "$WORK/unrelated" ]] || fail 'custom backend guidance pruned'
echo 'agent instructions: layout, policy scope, migration, conflicts, prompts, and pruning passed'
