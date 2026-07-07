#!/usr/bin/env bash
# Verifies ts/configure.sh merges the template `scripts` into the target
# package.json (honoring skip vs replace mode) and calls `pnpm add -D` with
# the template's dependency names/pins verbatim, so new projects resolve
# latest at scaffold time. Also guards the intentionally-identical configs
# against drifting between the frontend/ and node/ buckets. pnpm is stubbed,
# so nothing is installed and no network is touched. Run manually:
#   bash tests/configure-scaffold.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURE="$SCRIPT_DIR/ts/configure.sh"
FRONTEND_SCAFFOLD="$SCRIPT_DIR/ts/frontend/package.scaffold.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# Stub pnpm: record argv, install nothing.
mkdir -p "$WORK/bin"
export PNPM_RECORD="$WORK/pnpm-argv"
cat > "$WORK/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$PNPM_RECORD"
STUB
chmod +x "$WORK/bin/pnpm"

new_target() {
  local dir="$1" pkg="$2"
  mkdir -p "$dir"
  printf '%s\n' "$pkg" > "$dir/package.json"
}

# --- Scenario A: fresh project — scripts merged, deps via pnpm, smoke skipped ---
TARGET="$WORK/fresh"
new_target "$TARGET" '{"name":"scaffold-test","version":"1.0.0"}'
: > "$PNPM_RECORD"
out="$(PATH="$WORK/bin:$PATH" bash "$CONFIGURE" frontend "$TARGET" 2>&1)"

grep -q '"quality"' "$TARGET/package.json" || err "A: scripts not merged (no quality script)"
grep -q '"typecheck"' "$TARGET/package.json" || err "A: scripts not merged (no typecheck script)"
# devDependencies must NOT be written by the merge — pnpm owns them.
if grep -q '"devDependencies"' "$TARGET/package.json"; then
  err "A: devDependencies unexpectedly merged into package.json (should be installed via pnpm)"
fi
# pnpm add -D called with exactly the template's names/pins, in order.
# Match ignores the "--dir <path>" prefix so temp-path canonicalization can't flake it.
expected_names="$(node -e "const s=require('$FRONTEND_SCAFFOLD');process.stdout.write((s.scaffoldDevDependencies||[]).join(' '))")"
recorded="$(head -1 "$PNPM_RECORD" 2>/dev/null || true)"
if [[ "$recorded" != "--dir "*" add -D $expected_names" ]]; then
  err "A: pnpm argv mismatch
  expected: --dir <target> add -D $expected_names
  actual:   $recorded"
fi
[[ "$out" == *"Smoke test: skipped (no src/)"* ]] || err "A: expected smoke-skip message in output"

# --- Scenario B: existing script + skip mode — existing wins, new keys still added ---
TARGET="$WORK/skipmode"
new_target "$TARGET" '{"name":"t","version":"1.0.0","scripts":{"test":"custom-test"}}'
: > "$PNPM_RECORD"
CONFIGURE_MODE=skip PATH="$WORK/bin:$PATH" bash "$CONFIGURE" frontend "$TARGET" >/dev/null 2>&1
grep -q '"test": "custom-test"' "$TARGET/package.json" || err "B: skip mode overwrote existing test script"
grep -q '"quality"' "$TARGET/package.json" || err "B: skip mode failed to add scaffold-only scripts"

# --- Scenario C: existing script + replace (default) — scaffold wins, report emitted ---
TARGET="$WORK/replacemode"
new_target "$TARGET" '{"name":"t","version":"1.0.0","scripts":{"test":"custom-test"}}'
: > "$PNPM_RECORD"
errout="$(PATH="$WORK/bin:$PATH" bash "$CONFIGURE" frontend "$TARGET" 2>&1 >/dev/null)"
grep -q '"test": "vitest run"' "$TARGET/package.json" || err "C: replace mode kept existing test script"
[[ "$errout" == *"Overwrote existing scripts: test"* ]] || err "C: missing overwritten-keys report (stderr: $errout)"

# --- Bucket sync: intentionally-identical configs must not drift ---
for f in .stryker.config.json .prettierignore; do
  cmp -s "$SCRIPT_DIR/ts/frontend/$f" "$SCRIPT_DIR/ts/node/$f" \
    || err "bucket drift: ts/frontend/$f != ts/node/$f"
done

if [[ "$fail" -eq 0 ]]; then
  echo "OK"
  exit 0
fi
exit 1
