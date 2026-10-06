#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/repo"
cat > "$STUB_DIR/pnpm" <<'EOF'
#!/bin/bash
echo "noisy pnpm output: $*"
exit "${FAKE_PNPM_RC:-0}"
EOF
chmod +x "$STUB_DIR/pnpm"
echo '{"scripts":{"quality":"x"}}' > "$TMP/repo/package.json"

# Prints raw stdout; the hook must emit exactly one JSON object or nothing.
run_hook() {
  local runtime=$1 cmd=${2:-git push}
  if [[ "$runtime" == claude ]]; then
    CLAUDE_PROJECT_DIR="$TMP/repo" PATH="$STUB_DIR:$PATH" bash "$ROOT/.claude/hooks/pre-push-check.sh" \
      <<< "$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')" 2>/dev/null
  else
    PATH="$STUB_DIR:$PATH" bash "$ROOT/.codex/hooks/pre-push-check.sh" \
      <<< "$(jq -cn --arg cwd "$TMP/repo" --arg c "$cmd" '{cwd:$cwd,tool_input:{command:$c}}')" 2>/dev/null
  fi
}

for rt in claude codex; do
  output=$(FAKE_PNPM_RC=1 run_hook $rt)
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" >/dev/null \
    || { echo "FAIL $rt: failing quality gate must emit one deny JSON object, got: $output" >&2; exit 1; }
  output=$(FAKE_PNPM_RC=0 run_hook $rt)
  [[ -z "$output" ]] || { echo "FAIL $rt: passing quality gate must print nothing, got: $output" >&2; exit 1; }
  PASS=$((PASS + 2))
  for cmd in "(git push)" "{ git push; }" "env A=1 git push" "command git push origin"; do
    output=$(FAKE_PNPM_RC=1 run_hook $rt "$cmd")
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$output" >/dev/null \
      || { echo "FAIL $rt: '$cmd' must trigger the gate, got: $output" >&2; exit 1; }
    PASS=$((PASS + 1))
  done
  output=$(FAKE_PNPM_RC=1 run_hook $rt 'grep -n "git push" notes.md')
  [[ -z "$output" ]] || { echo "FAIL $rt: a quoted mention must not trigger the gate, got: $output" >&2; exit 1; }
  PASS=$((PASS + 1))
done

echo "pre-push-check: $PASS checks passed"
