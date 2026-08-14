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
if jq -e '.permissions.allow[]? | select(. == "Workflow")' "$ROOT/.claude/settings.json" >/dev/null; then
  fail 'global Workflow permission is forbidden; use the skill-scoped validator'
fi

node --test \
  "$CLAUDE_REVIEW/scripts/review-run.test.mjs" \
  "$CLAUDE_REVIEW/scripts/review-benchmark.test.mjs" \
  "$CLAUDE_REVIEW/scripts/verify-citations.test.mjs" \
  "$CLAUDE_REVIEW/scripts/review-fanout.workflow.test.mjs" \
  "$CLAUDE_REVIEW/scripts/validate-workflow-launch.test.mjs" \
  "$CLAUDE_REVIEW/scripts/codex-launch.test.mjs"

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
