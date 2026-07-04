#!/usr/bin/env bash
# Verifies ts/configure.sh merges the template `scripts` into the target
# package.json and calls `pnpm add -D` with the template's dependency NAMES
# (no versions), so new projects resolve latest at scaffold time. pnpm is
# stubbed, so nothing is installed and no network is touched. Run manually:
#   bash tests/configure-scaffold.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURE="$SCRIPT_DIR/ts/configure.sh"
FRONTEND_SCAFFOLD="$SCRIPT_DIR/ts/frontend/package.scaffold.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub pnpm: record argv, install nothing.
mkdir -p "$WORK/bin"
export PNPM_RECORD="$WORK/pnpm-argv"
cat > "$WORK/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$PNPM_RECORD"
STUB
chmod +x "$WORK/bin/pnpm"

# Minimal target project.
TARGET="$WORK/project"
mkdir -p "$TARGET"
echo '{"name":"scaffold-test","version":"1.0.0"}' > "$TARGET/package.json"

PATH="$WORK/bin:$PATH" bash "$CONFIGURE" frontend "$TARGET" >/dev/null

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# (a) scripts merged into package.json
grep -q '"quality"' "$TARGET/package.json" || err "scripts not merged (no quality script)"
grep -q '"typecheck"' "$TARGET/package.json" || err "scripts not merged (no typecheck script)"
# devDependencies must NOT be written by the merge anymore — pnpm owns them now
if grep -q '"devDependencies"' "$TARGET/package.json"; then
  err "devDependencies unexpectedly merged into package.json (should be installed via pnpm)"
fi

# (b) pnpm add -D called with exactly the template's names, in order, no versions.
# Match ignores the "--dir <path>" prefix so temp-path canonicalization can't flake it.
expected_names="$(node -e "const s=require('$FRONTEND_SCAFFOLD');process.stdout.write((s.scaffoldDevDependencies||[]).join(' '))")"
recorded="$(cat "$PNPM_RECORD" 2>/dev/null || true)"
if [[ "$recorded" != "--dir "*" add -D $expected_names" ]]; then
  err "pnpm argv mismatch
  expected: --dir <target> add -D $expected_names
  actual:   $recorded"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "OK"
  exit 0
fi
exit 1
