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

installed_review="$HOME/.claude/skills/comprehensive-code-review"
if [[ -d "$installed_review" ]]; then
  [[ -r "$installed_review/scripts/review-run.mjs" ]] \
    || fail 'installed canonical run-state helper missing'
fi

[[ "$(grep -Fc "[[ \"\$path\" == .codex/skills/* ]] && continue" "$ROOT/setup.sh")" -eq 2 ]] \
  || fail 'Codex skill is not excluded from ~/.codex path-for-path linking'

printf 'OK\n'
