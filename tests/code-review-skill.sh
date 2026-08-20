#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/.codex/skills/code-review"
CLAUDE_REVIEW="$ROOT/.claude/skills/comprehensive-code-review"
TILDE='~'

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$SKILL/SKILL.md" ]] || fail 'Codex skill missing'
[[ -f "$SKILL/agents/openai.yaml" ]] || fail 'Codex UI metadata missing'
[[ -f "$SKILL/references/orchestration.md" ]] || fail 'Codex orchestration reference missing'
[[ -f "$CLAUDE_REVIEW/references/reviewer-profiles.json" ]] || fail 'shared reviewer profiles missing'
[[ -f "$CLAUDE_REVIEW/scripts/validate-workflow-launch.mjs" ]] || fail 'workflow launch validator missing'

jq -e '.version == 1 and .focused == ["security-reviewer","quality-reviewer","simplification-reviewer","silent-failure-hunter","systemic-failure-reviewer"]' \
  "$CLAUDE_REVIEW/references/reviewer-profiles.json" >/dev/null \
  || fail 'focused reviewer profile drifted'

reviewers=(
  architecture-reviewer security-reviewer quality-reviewer test-coverage-reviewer
  type-design-reviewer comment-accuracy-reviewer documentation-reviewer
  silent-failure-hunter simplification-reviewer systemic-failure-reviewer
  implementation-reviewer
)
for reviewer in "${reviewers[@]}"; do
  [[ -f "$CLAUDE_REVIEW/agents/$reviewer.md" ]] || fail "missing Claude reviewer: $reviewer"
  grep -Fq "${TILDE}/.claude/skills/comprehensive-code-review/agents/$reviewer.md" "$SKILL/SKILL.md" \
    || fail "skill does not reference installed Claude reviewer: $reviewer"
done

grep -Fq "${TILDE}/.claude/skills/comprehensive-code-review/scripts/verify-citations.mjs" "$SKILL/SKILL.md" \
  || fail 'installed verifier reference missing'
grep -Fq "${TILDE}/.claude/skills/comprehensive-code-review/scripts/review-run.mjs" "$SKILL/SKILL.md" \
  || fail 'installed run-state helper reference missing'
grep -Fq "${TILDE}/.claude/skills/comprehensive-code-review/references/report-format.md" "$SKILL/SKILL.md" \
  || fail 'installed report reference missing'
if grep -Fq '../../../.claude/' "$SKILL/SKILL.md"; then
  fail 'checkout-relative Claude reference remains'
fi

if find "$SKILL" -type f -path '*/agents/*.md' | grep -q .; then
  fail 'Claude reviewer prompts duplicated under .codex'
fi

grep -Fq '.code-review/runs/<UTC-basic>-<profile>-<random>/' "$SKILL/references/orchestration.md" \
  || fail 'shared run layout missing'
grep -Fq 'Never invoke Claude' "$SKILL/SKILL.md" || fail 'Claude Workflow prohibition missing'
grep -Fq 'recursively launch another Codex CLI' "$SKILL/SKILL.md" || fail 'recursive Codex prohibition missing'
grep -Fq 'path-only documentation manifest' "$SKILL/references/orchestration.md" \
  || fail 'native docs manifest contract missing'
grep -Fq 'Open Questions — intent rulings needed' "$SKILL/references/orchestration.md" \
  || fail 'native Open Questions routing missing'
grep -Fq 'never re-emit charter bodies' "$SKILL/references/orchestration.md" \
  || fail 'native path-only charter contract missing'
grep -Fq 'validate-workflow-launch.mjs' "$CLAUDE_REVIEW/SKILL.md" \
  || fail 'comprehensive skill-scoped Workflow validator missing'
grep -Fq 'validate-workflow-launch.mjs' "$ROOT/.claude/skills/focused-code-review/SKILL.md" \
  || fail 'focused skill-scoped Workflow validator missing'

# Preflight era: both Claude skills call the deterministic preflight script and
# no longer carry the hand-executed EXCLUDES gathering.
for skill_md in \
  "$CLAUDE_REVIEW/SKILL.md" \
  "$ROOT/.claude/skills/focused-code-review/SKILL.md"; do
  grep -Fq 'review-preflight.mjs' "$skill_md" \
    || fail "$skill_md does not invoke review-preflight.mjs"
  if grep -Fq 'EXCLUDES=(' "$skill_md"; then
    fail "$skill_md still carries the hand-executed EXCLUDES array (script owns it now)"
  fi
done

# Codex-native skill: preflight-scripted scope, path-only charters (validated
# readable, never read into the main agent).
grep -Fq 'review-preflight.mjs' "$SKILL/references/orchestration.md" \
  || fail 'Codex orchestration does not invoke review-preflight.mjs'
grep -Fq -- '--runtime codex' "$SKILL/references/orchestration.md" \
  || fail 'Codex orchestration missing --runtime codex preflight flag'
if grep -Fq 'then read every selected reviewer charter completely' "$SKILL/SKILL.md"; then
  fail 'Codex SKILL.md still mandates main-agent charter reads'
fi
grep -Fq 'never read or re-emit their bodies' "$SKILL/SKILL.md" \
  || fail 'Codex SKILL.md missing path-only charter validation wording'

for skill_md in \
  "$CLAUDE_REVIEW/SKILL.md" \
  "$ROOT/.claude/skills/focused-code-review/SKILL.md"; do
  if grep -Fq 'printf '"'"'%s\n'"'"' "$CHANGED_FILES" > ' "$skill_md"; then
    fail "$skill_md still overwrites raw/changed-files.txt late in the citation phase"
  fi
done

# Positive fixture: prove the printf guard's grep actually matches the old
# offending line, so future pattern drift (e.g. quoting changes) is caught.
printf_guard_fixture="$(mktemp)"
printf '%s\n' 'printf '"'"'%s\n'"'"' "$CHANGED_FILES" > "$RUN_DIR/raw/changed-files.txt"' > "$printf_guard_fixture"
grep -Fq 'printf '"'"'%s\n'"'"' "$CHANGED_FILES" > ' "$printf_guard_fixture" \
  || fail 'printf guard grep failed to match its own positive fixture'
rm -f "$printf_guard_fixture"

# Settings guard: check every settings file whose permissions/env are
# actually effective for this user, not just the (gitignored/absent)
# repo-local settings.local.json. The user-level settings.json symlinks into
# the repo, so dedupe by realpath to avoid checking the same file twice.
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings_candidates=(
  "$ROOT/.claude/settings.json"
  "$config_dir/settings.json"
  "$config_dir/settings.local.json"
)
declare -a settings_files=()
declare -a seen_realpaths=()
for settings_file in "${settings_candidates[@]}"; do
  [[ -f "$settings_file" ]] || continue
  real="$(realpath "$settings_file")"
  dup=0
  for s in "${seen_realpaths[@]:-}"; do
    [[ "$s" == "$real" ]] && dup=1 && break
  done
  [[ $dup -eq 1 ]] && continue
  seen_realpaths+=("$real")
  settings_files+=("$settings_file")
done
for settings_file in "${settings_files[@]}"; do
  if jq -e '.permissions.allow[]? | select(type == "string" and (. == "Workflow" or startswith("Workflow(")))' "$settings_file" >/dev/null; then
    fail "effective Workflow permission in $settings_file is forbidden; use the skill-scoped validator"
  fi
  if jq -e '.env["VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT"] != null' "$settings_file" >/dev/null 2>&1; then
    fail "$settings_file sets VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT; this overrides the Codex cache root security boundary"
  fi
done

# Prove the jq expressions themselves catch both rule shapes, fail closed on
# non-string allow entries, and catch the cache-root env override, in isolation.
workflow_guard_fixture="$(mktemp)"
trap 'rm -f "$workflow_guard_fixture"' EXIT
for shape in '"Workflow"' '"Workflow(Bash)"'; do
  printf '{"permissions":{"allow":[%s]}}\n' "$shape" > "$workflow_guard_fixture"
  jq -e '.permissions.allow[]? | select(type == "string" and (. == "Workflow" or startswith("Workflow(")))' "$workflow_guard_fixture" >/dev/null \
    || fail "settings guard jq expression failed to catch $shape"
done
printf '{"permissions":{"allow":[42,"Workflow"]}}\n' > "$workflow_guard_fixture"
jq -e '.permissions.allow[]? | select(type == "string" and (. == "Workflow" or startswith("Workflow(")))' "$workflow_guard_fixture" >/dev/null \
  || fail 'settings guard jq expression failed to catch "Workflow" alongside a non-string entry'
printf '{"env":{"VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT":"/tmp/evil"}}\n' > "$workflow_guard_fixture"
jq -e '.env["VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT"] != null' "$workflow_guard_fixture" >/dev/null \
  || fail 'settings guard jq expression failed to catch VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT override'
rm -f "$workflow_guard_fixture"
trap - EXIT

node --test \
  "$CLAUDE_REVIEW/scripts/review-run.test.mjs" \
  "$CLAUDE_REVIEW/scripts/review-benchmark.test.mjs" \
  "$CLAUDE_REVIEW/scripts/verify-citations.test.mjs" \
  "$CLAUDE_REVIEW/scripts/review-fanout.workflow.test.mjs" \
  "$CLAUDE_REVIEW/scripts/validate-workflow-launch.test.mjs" \
  "$CLAUDE_REVIEW/scripts/codex-launch.test.mjs" \
  "$CLAUDE_REVIEW/scripts/review-preflight.test.mjs"

# Installed runtime: the skill must be a directory symlink into the repo so
# every canonical resource the Codex skill requires resolves, always current.
installed_review="$HOME/.claude/skills/comprehensive-code-review"
if [[ -e "$installed_review" ]]; then
  [[ -L "$installed_review" ]] || fail 'installed review skill is not a directory symlink'
  [[ -r "$installed_review/references/reviewer-profiles.json" ]] \
    || fail 'installed reviewer profiles missing'
  [[ -r "$installed_review/scripts/review-run.mjs" ]] \
    || fail 'installed canonical run-state helper missing'
fi

[[ "$(grep -Fc "[[ \"\$path\" == .codex/skills/* ]] && continue" "$ROOT/setup.sh")" -eq 2 ]] \
  || fail 'Codex skill is not excluded from ~/.codex path-for-path linking'

printf 'OK\n'
