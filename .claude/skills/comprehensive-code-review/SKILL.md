---
name: comprehensive-code-review
description: >
  Run a comprehensive code review using parallel specialist reviewers and a Codex adversarial
  review. Covers architecture, security, quality, tests, types, comments, simplification,
  silent failures, documentation, and optionally implementation-vs-spec. Consolidates all
  findings into a single standardized report with verified file:line citations.
  Usage: /comprehensive-code-review [--base <ref>] [--full] [--spec <path>]
argument-hint: "[--base <ref>] [--full] [--spec <path>]"
---

# Comprehensive Code Review

You are the orchestrator for a comprehensive, multi-dimensional code review. You dispatch the
specialist reviewers through a **Workflow** (which forces every reviewer into one findings schema and
writes the consolidated result to a file), run **Codex** as a concurrent backgrounded Bash job whose
scope mirrors the reviewers (bounded only under `--full`), verify every finding has a real file:line
citation, group results by category, and emit one consolidated report.

Read `references/workflow-and-codex.md` and `references/report-format.md` (in this skill's
directory) before proceeding — they define the workflow contract, the findings schema, the Codex
target-resolution table, and the output format.

## Iron Laws

```
1. NO FINDING WITHOUT A VERIFIED FILE:LINE CITATION.
   Every reported reviewer finding cites file:line + verbatim quote >=5 chars, verified by
   reading the file. Unverifiable findings are dropped before emission. No exceptions.

2. NO REPORT UNTIL BOTH TRACKS RESOLVE.
   The reviewer Workflow must complete (its workflow-result.json written) AND Codex must
   reach a terminal state (done / skipped / blocked) before you emit the report. No exceptions.

3. NO INVENTED CATEGORIES.
   Report uses the fixed category set in references/report-format.md.
   Findings that don't fit go to "Other" with reviewer name preserved. No exceptions.

4. REVIEWERS DISPATCH VIA THE WORKFLOW.
   Do not hand-dispatch reviewer Task calls. The Workflow owns reviewer fan-out and schema
   enforcement. The only direct background call you make is Codex. No exceptions.
```

## Red Flags — STOP and re-read this prompt

| Thought                                      | Reality                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------- |
| "I'll Task each reviewer myself"             | Iron Law 4. Reviewers go through the Workflow, not direct Task calls.               |
| "The finding looks right, I'll include it"   | Iron Law 1. Verify file:line first. Drop if no match.                               |
| "Workflow's still running, I'll report now"  | Iron Law 2. workflow-result.json written AND Codex terminated first.                |
| "I'll create a new category for this"        | Iron Law 3. Use fixed set; map to "Other" if nothing fits.                          |
| "Codex isn't available, I'll abort"          | Mark Codex SKIPPED. The Workflow still runs.                                        |
| "I'll poll `status <id>` for Codex"          | No. adversarial-review never backgrounds; read the backgrounded Bash task's stdout. |
| "I'll harvest the Workflow's return value"   | No. Read .comprehensive-code-review/raw/workflow-result.json instead.               |
| "--full, so I'll build a root..HEAD diff"    | No. --full sends agents the file inventory; they Read files.                        |
| "I'll summarise a finding without the quote" | No quote = no finding. Period.                                                      |

## Additional review dimensions (cross-cutting)

When reading findings, also look for evidence of these higher-order issues (flag under "Other" if a
reviewer surfaces them):

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

## Phase 1 — Detect Scope & Gather Inputs

Parse the skill arguments (from `$ARGUMENTS`):

```
--base <ref>   → mode = "base";  scope = git diff <ref>...HEAD
--full         → mode = "full";  scope = ENTIRE CODEBASE, current state
(no args)      → mode = "working-tree"; scope = git diff (working tree vs HEAD)
--spec <path>  → path to spec file for implementation-reviewer
```

Build `reviewInput` + `changedFiles` per mode:

```bash
# mode = full  → agents Read files themselves; send the inventory, not a diff
CHANGED_FILES=$(git ls-files)
# reviewInput = "Review the ENTIRE codebase at its current committed state. Use Read/Grep/Glob to
#   open and inspect the actual files listed under 'Changed files' above. Do NOT expect a diff."
# Empty guard: if CHANGED_FILES is empty -> print "Nothing to review: no tracked files." STATUS: DONE. Stop.

# mode = base
CHANGED_FILES=$(git diff --name-only <ref>...HEAD)
# reviewInput = the diff (git diff <ref>...HEAD), truncated at 8000 lines per the reference.

# mode = working-tree
CHANGED_FILES=$(git diff --name-only)
# reviewInput = the diff (git diff), truncated at 8000 lines.
# Empty guard: if diff empty AND working tree clean -> print "Nothing to review: working tree is
#   clean and no --base was specified." STATUS: DONE. Stop.
```

Read the 10 reviewer agent files (`agents/<name>.md`) into the `reviewers` array as
`{ name, role }`. Read `CLAUDE.md` path. Read the spec file if `--spec` was given.

Record `scopeLabel` (human-readable), `mode`, `reviewInput`, `changedFiles`, `repoRoot`,
`claudeMdPath`, `spec`.

## Phase 2 — Resolve Codex

```bash
CODEX_CMD=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
```

Empty → `CODEX_AVAILABLE=false` (mark Codex SKIPPED). Else `CODEX_AVAILABLE=true`.

## Phase 3 — Resolve Codex Target

Codex mirrors the reviewers' scope, except `--full` caps it to the recent window. Per the table in
`references/workflow-and-codex.md`, resolve a single `CODEX_TARGET` flag string:

```bash
if [ -n "$BASE_REF" ]; then              # --base given (with or without --full) → mirror reviewers
  CODEX_TARGET="--base $BASE_REF"
elif [ "$MODE" = "full" ]; then          # --full alone → bounded recent window (context limit)
  if [ "$(git rev-list --count HEAD)" -gt 10 ]; then CODEX_BASE=$(git rev-parse HEAD~10);
  else CODEX_BASE=$(git rev-list --max-parents=0 HEAD | tail -1); fi
  CODEX_TARGET="--base $CODEX_BASE"
else                                     # working tree → mirror reviewers' uncommitted diff
  CODEX_TARGET="--scope working-tree"
fi
```

In `--base` and working-tree modes Codex sees the same scope as the agents. Only under `--full` do
they diverge (agents = whole codebase, Codex = `HEAD~10` window, to stay within Codex's context
limit) — note this `--full`-only mismatch in the report.

## Phase 4 — Implementation-Reviewer Eligibility

If `SPEC_PATH` is null → exclude implementation-reviewer from `reviewers`; mark it SKIPPED ("no --spec provided").
If `SPEC_PATH` is set but the file does not exist → exclude it; mark SKIPPED ("spec file not found: <path>").
Otherwise → include `{ name: "implementation-reviewer", role: <file body> }` in `reviewers`, and set `spec = { path, content }`.

## Phase 5 — Launch Both Tracks (single message)

First ensure the output dir exists (both the workflow's persist agent and Codex's raw output land here):

```bash
mkdir -p .comprehensive-code-review/raw
```

<EXTREMELY-IMPORTANT>
Your next assistant message MUST launch both background tracks together:

1. **Bash call (`run_in_background: true`)** — Codex adversarial review, ONLY if `CODEX_AVAILABLE=true`.
   `adversarial-review` has NO real backgrounding (`--background` is a no-op for reviews and prints no
   job id) — run it synchronously and let the Bash tool background it:

   ```bash
   node "$CODEX_CMD" adversarial-review $CODEX_TARGET 2>&1
   ```

   Do NOT pass `--background`. Do NOT poll the companion's `status`/`result` subcommands. The Bash task
   keeps running across turns; harvest its output when it terminates (Phase 6).

2. **Workflow call** — the reviewer fan-out:
   ```
   Workflow({
     scriptPath: "<this skill's base directory>/scripts/review-fanout.workflow.js",
     args: { scopeLabel, mode, reviewInput, changedFiles, repoRoot, claudeMdPath, spec, reviewers }
   })
   ```
   The `args` values are the records gathered in Phase 1/4. Pass them as real JSON. `repoRoot` MUST be
   the absolute repo root — the workflow writes its result under `repoRoot/.comprehensive-code-review/`.

Both return immediately and run in the background. Do not hand-dispatch reviewer Task calls.
</EXTREMELY-IMPORTANT>

## Phase 6 — Harvest

When the Workflow completion notification arrives, **Read the file the workflow wrote** —
`.comprehensive-code-review/raw/workflow-result.json` — and parse `{ reviewers: [...] }`. Do NOT rely
on the Workflow's JS return value or `TaskOutput`; neither surfaces the structured object to you. Each
reviewer entry has `status`, optional `verdict`, and `findings[]`. If the file is missing or unparseable,
mark every dispatched reviewer BLOCKED("workflow-result.json missing/unparseable") and continue.

Then harvest Codex if `CODEX_AVAILABLE=true`: the Codex review ran as a backgrounded **Bash** task.
When that Bash task terminates, read its captured stdout (the review markdown) directly — there is no
companion job to poll. Wait for it to finish before emitting the report (Iron Law 2). If it produced
no usable output, or has not terminated after a reasonable wait, mark Codex BLOCKED("no output / did
not terminate").

## Phase 7 — Citation Verification (deterministic)

For every finding from every reviewer (per the pseudocode in `references/workflow-and-codex.md`):

1. Require `file`, `line`, `verbatim` (>=5 chars) — else drop (`dropped_no_citation` / `dropped_quote_too_short`).
2. Read the file at `line ±2`, collapse whitespace on both quote and content, and require the quote
   to be a substring — else drop (`dropped_no_match`).

Collect dropped findings into the "Dropped Findings" list. Codex emits narrative markdown (no verbatim
quotes), so its findings are existence-checked only (any cited file exists + cited line within file
length), not quote-verified.

## Phase 8 — Group, Sort, Emit

1. `mkdir -p .comprehensive-code-review/raw` (idempotent — already created in Phase 5).
2. Write each reviewer's raw findings JSON to `.comprehensive-code-review/raw/<reviewer>-<UTC-iso>.md`
   (derived from the parsed `workflow-result.json`), and the Codex review markdown to
   `.comprehensive-code-review/raw/codex-adversarial-<UTC-iso>.md`.
3. Categorize each verified finding per `references/report-format.md`.
4. Map severity per the table in `references/report-format.md`.
5. Sort within each category by severity DESC, then file ASC.
6. Write the consolidated report to `.comprehensive-code-review/report-<UTC-iso>.md` using the
   skeleton in `references/report-format.md`. In the Scope section, note the agent vs. Codex scope
   when mode = full.
7. Print the summary:

   ```
   ## Comprehensive Code Review complete

   Report: .comprehensive-code-review/report-<ts>.md
   Reviewers: <n> DONE, <n> SKIPPED, <n> BLOCKED
   Findings: <total> verified (<n> critical, <n> important, <n> minor)
   Dropped: <n> (citation unverifiable)
   ```

## Phase 9 — STATUS line

If all reviewers are DONE or SKIPPED (no BLOCKED) and Codex is DONE/SKIPPED:

```
STATUS: DONE
```

If any reviewer or Codex is BLOCKED:

```
STATUS: DONE_WITH_CONCERNS — <n> track(s) BLOCKED: <names>
```

The STATUS line must be the absolute last line of your response.
