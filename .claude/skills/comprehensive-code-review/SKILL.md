---
name: comprehensive-code-review
description: >
  Run a comprehensive code review using parallel specialist reviewers and a Codex adversarial
  review. Covers architecture, security, quality, tests, types, comments, simplification,
  silent failures, documentation, and optionally implementation-vs-spec. Consolidates all
  findings into a single standardized report with verified file:line citations.
  Usage: /comprehensive-code-review [--base <ref>] [--all] [--spec <path>]
---

# Comprehensive Code Review

You are the orchestrator for a comprehensive, multi-dimensional code review. You dispatch
specialist reviewer agents in parallel, verify every finding has a real file:line citation,
group results by category, and emit one consolidated report.

Read `references/report-format.md` and `references/agent-dispatch-template.md` (in this
skill's directory) before proceeding — they define the output contract and dispatch patterns.

## Iron Laws

```
1. NO FINDING WITHOUT A VERIFIED FILE:LINE CITATION.
   Every reported finding cites file:line + verbatim quote ≥5 chars.
   Unverifiable findings are dropped before emission. No exceptions.

2. NO COMPLETION CLAIM WITHOUT EVERY DISPATCHED AGENT'S OUTPUT.
   Each reviewer must terminate with a STATUS line. Missing STATUS = BLOCKED.
   Do not emit the final report until all Task calls have resolved. No exceptions.

3. NO INVENTED CATEGORIES.
   Report uses the fixed category set in references/report-format.md.
   Findings that don't fit go to "Other" with reviewer name preserved. No exceptions.

4. PARALLEL DISPATCH IN ONE MESSAGE.
   All reviewer Task calls + the Codex Bash call must be emitted in a single
   assistant message. Sequential dispatch is forbidden. No exceptions.
```

## Red Flags — STOP and re-read this prompt

| Thought                                      | Reality                                                            |
| -------------------------------------------- | ------------------------------------------------------------------ |
| "I'll dispatch reviewers one at a time"      | Iron Law 4. All Task calls in ONE message.                         |
| "The finding looks right, I'll include it"   | Iron Law 1. Verify file:line first. Drop if no match.              |
| "Some reviewers finished, I'll report now"   | Iron Law 2. ALL agents must resolve first.                         |
| "I'll create a new category for this"        | Iron Law 3. Use fixed set; map to "Other" if nothing fits.         |
| "Codex isn't available, I'll abort"          | Mark Codex SKIPPED. Other reviewers still run.                     |
| "The diff is huge, I'll skip some reviewers" | Truncate the diff per the dispatch template. Never skip reviewers. |
| "I'll summarise a finding without the quote" | No quote = no finding. Period.                                     |

## Additional review dimensions (cross-cutting)

Reviewers collectively cover the standard dimensions. When reading findings, also look for
evidence of these higher-order issues (flag under "Other" if a reviewer surfaces them):

- **Dead code**: unused exports, unreachable branches, stale feature flags with no owner/expiry
- **Dependency hygiene**: new deps without necessity justification, SBOM gaps, devDeps in prod
- **Observability gaps**: new code paths with no logging, metrics, or tracing
- **Migration/release safety**: feature flags lacking owner annotation or expiry date
- **Contract compatibility**: public API changes that break existing callers
- **Semantic duplication**: near-identical logic blocks that differ by one token (AST clones)
- **Hotspot/churn risk**: high-churn files with diffuse ownership (flag if CODEOWNERS absent)
- **Test pyramid health**: too many unit tests on implementation details, too few integration tests
- **Diff reviewability**: PRs >400 lines are harder to review meaningfully; note if applicable

---

## Phase 1 — Detect Scope

Parse the skill arguments (from `$ARGUMENTS`):

```
--base <ref>   → diff range: git diff <ref>...HEAD
--all          → diff range: git diff $(git rev-list --max-parents=0 HEAD | tail -1)...HEAD
(no args)      → diff range: git diff (working tree vs HEAD)
--spec <path>  → path to spec file for implementation-reviewer
```

Run:

```bash
# Resolve diff
if --all:    git diff $(git rev-list --max-parents=0 HEAD | tail -1)
elif --base: git diff <ref>...HEAD
else:        git diff

# Check if diff is empty
git diff --stat 2>/dev/null | tail -1
```

If diff is empty AND working tree is clean → print "Nothing to review: working tree is clean
and no --base was specified." and emit `STATUS: DONE`. Stop.

Record:

- `DIFF_RANGE` — human-readable description of scope
- `DIFF_CONTENT` — the diff output (truncate at 8000 lines per dispatch template)
- `CHANGED_FILES` — output of `git diff --name-only` (always full, even if diff is truncated)
- `SPEC_PATH` — value of --spec if provided, else null

## Phase 2 — Resolve Codex

```bash
CODEX_CMD=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs \
  2>/dev/null | sort -V | tail -1)
```

If `CODEX_CMD` is empty → set `CODEX_AVAILABLE=false`, mark Codex as SKIPPED in the reviewer
table. Otherwise set `CODEX_AVAILABLE=true`.

## Phase 3 — Resolve Codex Base

```bash
CODEX_BASE=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
```

If empty (no commits) → set `CODEX_BASE=HEAD~1` as fallback.

## Phase 4 — Implementation-Reviewer Eligibility

If `SPEC_PATH` is null → mark implementation-reviewer as SKIPPED with reason "no --spec provided".
If `SPEC_PATH` is set but file does not exist → mark SKIPPED with reason "spec file not found: <path>".
Otherwise → mark implementation-reviewer as ELIGIBLE; include spec content in its prompt.

## Phase 5 — PARALLEL DISPATCH (single message — CRITICAL)

<EXTREMELY-IMPORTANT>
Your NEXT assistant message after completing Phase 1–4 MUST contain ALL of the following
in a single message. Do not split across messages. Do not wait for one to finish before
sending the next. Every item below must appear in the same message:

1. Task call — architecture-reviewer (general-purpose subagent, inlined agents/architecture-reviewer.md)
2. Task call — quality-reviewer (general-purpose subagent, inlined agents/quality-reviewer.md)
3. Task call — security-reviewer (general-purpose subagent, inlined agents/security-reviewer.md)
4. Task call — silent-failure-hunter (general-purpose subagent, inlined agents/silent-failure-hunter.md)
5. Task call — test-coverage-reviewer (general-purpose subagent, inlined agents/test-coverage-reviewer.md)
6. Task call — type-design-reviewer (general-purpose subagent, inlined agents/type-design-reviewer.md)
7. Task call — comment-accuracy-reviewer (general-purpose subagent, inlined agents/comment-accuracy-reviewer.md)
8. Task call — simplification-reviewer (general-purpose subagent, inlined agents/simplification-reviewer.md)
9. Task call — documentation-reviewer (general-purpose subagent, inlined agents/documentation-reviewer.md)
10. Task call — implementation-reviewer (general-purpose subagent, inlined agents/implementation-reviewer.md)
    ONLY if ELIGIBLE per Phase 4. If SKIPPED, do not emit this Task call.
11. Bash call (run_in_background: true) — Codex adversarial review
    ONLY if CODEX_AVAILABLE=true. If SKIPPED, do not emit this Bash call.

Violating the letter of this rule violates the spirit. No exceptions.
</EXTREMELY-IMPORTANT>

### Task call prompt structure (per reviewer)

For each reviewer Task call, use this prompt body:

```
You are the <REVIEWER_NAME> for a comprehensive code review.

## Your role

<paste full content of agents/<reviewer>.md>

## Diff to review

Scope: <DIFF_RANGE>
Changed files: <CHANGED_FILES — one per line>

<DIFF_CONTENT>
<if truncated: "[TRUNCATED: full diff is <N> lines; above shows first 8000. All changed files listed above.]">

## Additional context

- Repo root: <absolute path of repo root>
- CLAUDE.md: <path if exists, else "not found">
<if implementation-reviewer: "- Spec file: <SPEC_PATH>\n\n<spec file content>">

## Output requirements

- Follow your Iron Laws exactly.
- End your response with the required STATUS line as the absolute last line.
- Every finding must cite file:line + verbatim quote ≥5 chars.
```

### Codex Bash call

```bash
node "$CODEX_CMD" adversarial-review --background --base "$CODEX_BASE"
```

With `run_in_background: true`. Capture stdout to extract jobId.

## Phase 6 — Harvest Codex

After all Task calls resolve, poll Codex if `CODEX_AVAILABLE=true`:

```bash
# Extract jobId from Codex launch output
CODEX_JOB_ID=$(echo "$CODEX_LAUNCH_OUTPUT" | grep -oE 'background as ([a-zA-Z0-9_-]+)' | awk '{print $NF}')

# Poll until done or timeout (20 min)
node "$CODEX_CMD" status "$CODEX_JOB_ID" --json

# Retrieve result
node "$CODEX_CMD" result "$CODEX_JOB_ID" --json
```

If jobId cannot be extracted or status never reaches `done` within 20 min → mark Codex as
BLOCKED("timeout or launch failed").

## Phase 7 — Citation Verification

For every finding from every reviewer:

1. Extract `file`, `line`, `verbatim` from the finding.
2. If any of these is missing → drop with `verification: dropped_no_citation`.
3. If `verbatim` is <5 chars → drop with `verification: dropped_quote_too_short`.
4. Read the file at `line ±2` (5-line window).
5. Normalize both the verbatim quote and the file content: collapse all whitespace (spaces,
   tabs, newlines) to a single space, then trim.
6. If the normalized quote is NOT a substring of the normalized content → drop with
   `verification: dropped_no_match`.
7. Otherwise mark `verification: ok`.

Collect all dropped findings into a separate list for the "Dropped Findings" section.

## Phase 8 — Group, Sort, Emit

1. **Create output directory**:

   ```bash
   mkdir -p .comprehensive-code-review/raw
   ```

2. **Write raw outputs**: For each reviewer, write the full raw output to
   `.comprehensive-code-review/raw/<reviewer>-<UTC-iso>.md`.

3. **Categorize findings**: Assign each verified finding to a category per
   `references/report-format.md` category assignment rules.

4. **Map severity**: Use the severity mapping table in `references/report-format.md`.

5. **Sort**: Within each category, sort by severity DESC (critical → important → minor),
   then by file ASC.

6. **Write report**: Write the consolidated report to
   `.comprehensive-code-review/report-<UTC-iso>.md` using the skeleton in
   `references/report-format.md`.

7. **Print summary** to stdout:

   ```
   ## Comprehensive Code Review complete

   Report: .comprehensive-code-review/report-<ts>.md
   Reviewers: <n> DONE, <n> SKIPPED, <n> BLOCKED
   Findings: <total> verified (<n> critical, <n> important, <n> minor)
   Dropped: <n> (citation unverifiable)
   ```

## Phase 9 — STATUS line

If all dispatched reviewers are DONE or SKIPPED (no BLOCKED):

```
STATUS: DONE
```

If any reviewer is BLOCKED:

```
STATUS: DONE_WITH_CONCERNS — <n> reviewer(s) BLOCKED: <names>
```

The STATUS line must be the absolute last line of your response.
