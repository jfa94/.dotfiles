---
name: code-review
description: Run native Codex code reviews using the canonical Claude specialist prompts without copying them. Use for focused diff reviews, comprehensive whole-codebase reviews, base-ref reviews, implementation-vs-spec reviews, or reviews with an explicit change-context file. Supports focused with optional base/context and comprehensive with optional base/full/spec/context; defaults to focused, while full or spec implies comprehensive.
---

# Native Code Review

Run the review in Codex with collaboration subagents. Never invoke Claude's Workflow runtime or recursively launch another Codex CLI review.

## Load required instructions

1. Read [references/orchestration.md](references/orchestration.md) completely.
2. Expand `~` to the current user's home directory for every canonical Claude resource below.
3. The reviewer roster comes from `~/.claude/skills/comprehensive-code-review/references/reviewer-profiles.json`, selected and readability-validated by the preflight script (see orchestration.md). Validate every selected charter and resource below is readable; never read or re-emit their bodies — each spawned reviewer reads its own charter from disk as its first action. The charters remain canonical; never copy them into this skill—pass canonical paths only.

Focused always selects:

- `~/.claude/skills/comprehensive-code-review/agents/security-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/quality-reviewer.md`
- `~/.claude/skills/comprehensive-code-review/agents/simplification-reviewer.md`
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

- `~/.claude/skills/comprehensive-code-review/scripts/review-preflight.mjs`
- `~/.claude/skills/comprehensive-code-review/scripts/verify-citations.mjs`
- `~/.claude/skills/comprehensive-code-review/scripts/review-run.mjs`
- `~/.claude/skills/comprehensive-code-review/references/report-format.md`
- `~/.claude/skills/comprehensive-code-review/references/reviewer-profiles.json`

Fail loudly if any selected charter or required resource is missing or unreadable.

## Profile rules

- No profile and no `--full`/`--spec`: focused.
- `focused [--base <ref>] [--context <path>]`: focused diff review.
- `comprehensive [--base <ref>] [--full] [--spec <path>] [--context <path>]`: comprehensive review.
- `--full` or `--spec` without a profile: comprehensive.
- Reject `--full` or `--spec` with an explicit focused profile; do not silently ignore it.
- Reject unknown flags, unsafe or unresolved base refs, and context files outside the repository or matching protected/secret paths before launching reviewers.

## Completion contract

Do not report completion until:

- every selected reviewer is DONE or BLOCKED;
- every eligible finding has completed its fresh refutation policy or is explicitly retained because verification failed;
- deterministic citation verification and deduplication completed;
- `run.json`, raw machine artifacts, and `report.md` exist in the unique run directory; and
- the absolute last response line is `STATUS: DONE` or `STATUS: DONE_WITH_CONCERNS — <reason>`.
  Use concerns when the overall result is NEEDS-DECISION even though every track completed.
