---
name: code-review
description: Run native Codex code reviews using the canonical Claude specialist prompts without copying them. Use for focused diff reviews, comprehensive whole-codebase reviews, base-ref reviews, or implementation-vs-spec reviews. Supports focused with an optional base ref and comprehensive with optional base, full, and spec arguments; defaults to focused, while full or spec implies comprehensive.
---

# Native Code Review

Run the review in Codex with collaboration subagents. Never invoke Claude's Workflow runtime or recursively launch another Codex CLI review.

## Load required instructions

1. Read [references/orchestration.md](references/orchestration.md) completely.
2. Expand `~` to the current user's home directory for every canonical Claude resource below.
3. Select the profile, then read every selected reviewer charter completely from the paths below. The charters remain canonical; never copy or rewrite them into this skill.

Focused always selects:

- `~/.claude/skills/comprehensive-code-review/agents/security-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/quality-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/test-coverage-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/silent-failure-hunter.md`
- `~/.claude/skills/comprehensive-code-review/agents/systemic-failure-reviewer.md`

Comprehensive selects:

- `~/.claude/skills/comprehensive-code-review/agents/architecture-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/security-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/quality-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/test-coverage-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/type-design-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/comment-accuracy-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/documentation-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/silent-failure-hunter.md`
- `~/.claude/skills/comprehensive-code-review/agents/simplification-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/systemic-failure-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/implementation-reviewer.md` only when `--spec` resolves to a readable file.

Also resolve and reuse these canonical resources:

- `~/.claude/skills/comprehensive-code-review/scripts/verify-citations.mjs`
- `~/.claude/skills/comprehensive-code-review/scripts/review-run.mjs`
- `~/.claude/skills/comprehensive-code-review/references/report-format.md`

Fail loudly if any selected charter or required resource is missing or unreadable.

## Profile rules

- No profile and no `--full`/`--spec`: focused.
- `focused [--base <ref>]`: focused diff review.
- `comprehensive [--base <ref>] [--full] [--spec <path>]`: comprehensive review.
- `--full` or `--spec` without a profile: comprehensive.
- Reject `--full` or `--spec` with an explicit focused profile; do not silently ignore it.
- Reject unknown flags and unsafe or unresolved base refs before launching reviewers.

## Completion contract

Do not report completion until:

- every selected reviewer is DONE or BLOCKED;
- every eligible finding has completed its fresh refutation policy or is explicitly retained because verification failed;
- deterministic citation verification and deduplication completed;
- `run.json`, raw machine artifacts, and `report.md` exist in the unique run directory; and
- the absolute last response line is `STATUS: DONE` or `STATUS: DONE_WITH_CONCERNS — <reason>`.
