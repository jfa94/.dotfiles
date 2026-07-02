---
name: quick-code-review
description: >
  Run a focused, quick code review with the five crucial specialist reviewers (security,
  quality, test coverage, silent failures, systemic failures) plus a Codex adversarial review. A lean subset of
  comprehensive-code-review: same rigor — every critical/important finding is adversarially
  verified by a fresh refuter agent, and every finding is dropped unless it has a verified
  file:line citation — but fewer dimensions, so the report is tighter and faster to triage.
  Reviews a diff (working tree by default, or `--base <ref>`). For a whole-codebase audit or
  spec-conformance, use comprehensive-code-review instead.
  Usage: /quick-code-review [--base <ref>]
argument-hint: "[--base <ref>]"
---

# Quick Code Review

You are the orchestrator for a focused, multi-dimensional code review — the lean sibling of
`comprehensive-code-review`. You dispatch **five** crucial specialist reviewers through a **Workflow**
(which forces every reviewer into one findings schema, adversarially verifies every critical/important
finding with a fresh refuter agent, and writes the consolidated result to a file), run **Codex** as a
concurrent backgrounded Bash job whose scope mirrors the reviewers, verify every finding has a real
file:line citation, dedup across reviewers, group results by category, and emit one consolidated report.

This skill **reuses the comprehensive skill's engine** — the workflow script, the reviewer agent
definitions, and the reference contracts all live in the sibling `comprehensive-code-review/` directory
(same `skills/` parent as this skill). Nothing is duplicated; you point at those files by path.

Before proceeding, read the two reference files in the sibling skill's directory —
`comprehensive-code-review/references/workflow-and-codex.md` and
`comprehensive-code-review/references/report-format.md`. They define the workflow contract, the findings
schema, the Codex target-resolution table, the citation-verification pseudocode, and the output format.
**Two deviations from those references apply to this skill:** (1) this skill has no `--full` and no
`--spec` mode — only working-tree and `--base`; (2) the output directory is `.quick-code-review/`, not
`.comprehensive-code-review/`.

## The five reviewers (fixed)

This skill always runs exactly these five, read from `comprehensive-code-review/agents/`:

- `security-reviewer` — injection, auth/authz, secrets, PII-in-logs, insecure defaults (source→sink traced)
- `quality-reviewer` — logic errors, edge cases, caller breakage, concurrency/async and statically-visible performance (it owns both dimensions)
- `test-coverage-reviewer` — missing behavioral coverage for the change, over-pinned/brittle tests
- `silent-failure-hunter` — swallowed errors, empty catches, unjustified fallbacks masking failure, observability gaps
- `systemic-failure-reviewer` — cross-file/cross-stage failure modes: stuck-states, invariants without repair, unsafe/no-op recovery, over-pinned contracts (self-skips when the diff has no stateful surface)

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

| Thought                                      | Reality                                                                            |
| -------------------------------------------- | ---------------------------------------------------------------------------------- |
| "I'll Task each reviewer myself"             | Iron Law 4. Reviewers go through the Workflow, not direct Task calls.              |
| "The finding looks right, I'll include it"   | Iron Law 1. Verify file:line first. Drop if no match.                              |
| "Workflow's still running, I'll report now"  | Iron Law 2. workflow-result.json written AND Codex terminated first.               |
| "I'll create a new category for this"        | Iron Law 3. Use fixed set; map to "Other" if nothing fits.                         |
| "Codex isn't available, I'll abort"          | Mark Codex SKIPPED. The Workflow still runs.                                       |
| "I'll poll `status <id>` for Codex"          | No. adversarial-review never backgrounds; read the JSON file the Bash task writes. |
| "I'll harvest the Workflow's return value"   | No. Read .quick-code-review/raw/workflow-result.json instead.                      |
| "I'll summarise a finding without the quote" | No quote = no finding. Period.                                                     |
| "A refuted finding still looks right to me"  | Refuted = Dropped Findings with the refuter's reason. Never resurrect it.          |
| "Same issue from 2 reviewers = 2 findings"   | Dedup first (Phase 7). Merge, keep highest severity, annotate "Also flagged by".   |
| "This needs the whole codebase / a spec"     | That's comprehensive-code-review. Quick reviews a diff only.                       |

---

## Phase 1 — Detect Scope & Gather Inputs

Parse the skill arguments (from `$ARGUMENTS`):

```
--base <ref>   → mode = "base";  scope = git diff <ref>...HEAD
(no args)      → mode = "working-tree"; scope = git diff HEAD (staged + unstaged) + untracked files
```

There is no `--full` and no `--spec` in this skill. If either is passed, tell the user this skill reviews
a diff only and to use `/comprehensive-code-review` for whole-codebase or spec-conformance review, then
proceed treating the rest of the args normally (ignore the unsupported flag).

Build `reviewInput` + `changedFiles` per mode.

**Build-output exclusion.** Generated/minified output (committed or untracked) is skipped so reviewers
see only hand-written code. Define `EXCLUDES` once and append `-- . "${EXCLUDES[@]}"` to _every_
file/diff gathering command below. The positive `.` is required so the exclude-only pathspecs resolve
against the whole repo; `top`+`glob` anchoring catches nested monorepo paths. This same list is the
Phase 6 drop predicate:

```bash
EXCLUDES=(
  ':(top,exclude,glob)**/dist/**'
  ':(top,exclude,glob)**/build/**'
  ':(top,exclude,glob)**/out/**'
  ':(top,exclude,glob)**/.next/**'
  ':(top,exclude,glob)**/.nuxt/**'
  ':(top,exclude,glob)**/.svelte-kit/**'
  ':(top,exclude,glob)**/.output/**'
  ':(top,exclude,glob)**/coverage/**'
  ':(top,exclude,glob)**/*.min.js'
  ':(top,exclude,glob)**/*.min.css'
  ':(top,exclude,glob)**/*.map'
)
```

```bash
# mode = base
CHANGED_FILES=$(git diff --name-only <ref>...HEAD -- . "${EXCLUDES[@]}")
# reviewInput = the diff (git diff <ref>...HEAD -- . "${EXCLUDES[@]}"). Diff <=2000 lines -> inline it;
#   >2000 lines -> manifest mode (write full-diff.patch + risk-ranked manifest, never truncated) per the reference.
# Empty guard: if diff empty -> print "Nothing to review: no changes vs <ref> (build outputs excluded)." STATUS: DONE. Stop.

# mode = working-tree
CHANGED_FILES=$( { git diff HEAD --name-only -- . "${EXCLUDES[@]}"; git ls-files --others --exclude-standard -- . "${EXCLUDES[@]}"; } | sort -u )
# reviewInput = the diff (git diff HEAD -- . "${EXCLUDES[@]}" — staged + unstaged; bare `git diff` misses staged changes).
#   Diff <=2000 lines -> inline it; >2000 lines -> manifest mode per the reference (never truncated).
#   Untracked files carry no diff hunks — append to
#   reviewInput: "Untracked files in the changed-files list have no diff; Read them directly."
# Empty guard: if CHANGED_FILES is empty -> print "Nothing to review: working tree matches HEAD
#   and no untracked files (build outputs excluded)." STATUS: DONE. Stop.
```

Read the five reviewer agent files from the sibling skill — `comprehensive-code-review/agents/{security-reviewer,quality-reviewer,test-coverage-reviewer,silent-failure-hunter,systemic-failure-reviewer}.md` — into the `reviewers` array as `{ name, role }`. Read `CLAUDE.md` path.

Record `scopeLabel` (human-readable), `mode`, `reviewInput`, `changedFiles`, `repoRoot`, `claudeMdPath`.

## Phase 2 — Resolve Codex

```bash
CODEX_CMD=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
```

Empty → `CODEX_AVAILABLE=false` (mark Codex SKIPPED). Else `CODEX_AVAILABLE=true`.

## Phase 3 — Resolve Codex Target

Codex mirrors the reviewers' scope. Per the table in `comprehensive-code-review/references/workflow-and-codex.md`, resolve a single `CODEX_TARGET` flag string:

```bash
if [ -n "$BASE_REF" ]; then              # --base given → mirror reviewers
  CODEX_TARGET="--base $BASE_REF"
else                                     # working tree → mirror reviewers' uncommitted diff
  CODEX_TARGET="--scope working-tree"
fi
```

Codex always sees the same scope as the agents in this skill (there is no `--full` divergence here).

## Phase 4 — Launch Both Tracks (single message)

First ensure the output dir exists and delete any prior run's output files so a stale file from an earlier
run can never be mistaken for this run's output (the dir is gitignored, so stale state persists locally
between runs):

```bash
mkdir -p .quick-code-review/raw
rm -f .quick-code-review/raw/workflow-result.json \
      .quick-code-review/raw/codex-adversarial.json \
      .quick-code-review/raw/codex-adversarial.stderr.log
```

<EXTREMELY-IMPORTANT>
Your next assistant message MUST launch both background tracks together:

1. **Bash call (`run_in_background: true`)** — Codex adversarial review, ONLY if `CODEX_AVAILABLE=true`.
   `adversarial-review` has NO real backgrounding — run it synchronously and let the Bash tool background it.
   Pass `--json` so the companion emits one structured JSON object on stdout; redirect stdout to a file and
   stderr to a separate log so nothing can interleave with the captured JSON:

   ```bash
   node "$CODEX_CMD" adversarial-review --json $CODEX_TARGET \
     >.quick-code-review/raw/codex-adversarial.json \
     2>.quick-code-review/raw/codex-adversarial.stderr.log
   ```

   Do NOT pass `--background`. Do NOT pass `--model` (let the companion auto-default to the best model).
   Do NOT poll the companion's `status`/`result` subcommands. The Bash task keeps running across turns;
   harvest the JSON file when it terminates (Phase 5).

2. **Workflow call** — the reviewer fan-out, using the sibling skill's script:
   ```
   Workflow({
     scriptPath: "<comprehensive-code-review skill dir>/scripts/review-fanout.workflow.js",
     args: { scopeLabel, mode, reviewInput, changedFiles, repoRoot, claudeMdPath, outDir: ".quick-code-review", reviewers }
   })
   ```
   The `args` values are the records gathered in Phase 1. Pass them as real JSON. `repoRoot` MUST be the
   absolute repo root — the workflow writes its result under `repoRoot/.quick-code-review/` because of the
   `outDir` arg. Do NOT pass a `spec` (this skill has no implementation-reviewer).

Both return immediately and run in the background. Do not hand-dispatch reviewer Task calls.
</EXTREMELY-IMPORTANT>

## Phase 5 — Harvest

When the Workflow completion notification arrives, **Read the file the workflow wrote** —
`.quick-code-review/raw/workflow-result.json` — and parse `{ scopeLabel, mode, reviewers: [...] }`. Do NOT
rely on the Workflow's JS return value or `TaskOutput`. Each reviewer entry has `status`, optional
`verdict`, and `findings[]`. **Staleness guard:** verify the file's `scopeLabel`/`mode` match the run you
just launched — if absent or different, the file is a stale leftover (the current run's persist failed), so
do NOT trust it; mark every dispatched reviewer BLOCKED("workflow-result.json stale/foreign — persist
failed"). Likewise, if the file is missing or unparseable, mark every dispatched reviewer
BLOCKED("workflow-result.json missing/unparseable") and continue.

Then harvest Codex if `CODEX_AVAILABLE=true`: it ran as a backgrounded **Bash** task that wrote its
structured JSON to `.quick-code-review/raw/codex-adversarial.json`. When the Bash task terminates, **Read
that file and `JSON.parse` it** — there is no companion job to poll. Wait for it to finish before emitting
the report (Iron Law 2). Apply the same validity/staleness gates and two-outcome routing (structured vs
degraded narrative fallback) as `comprehensive-code-review/references/workflow-and-codex.md` specifies:

- **Gate A — validity/crash:** file missing/empty/not valid JSON, or `payload.target` absent, or task not
  terminated after a reasonable wait → Codex **BLOCKED**(see codex-adversarial.stderr.log).
- **Gate B — staleness:** `payload.target` must match the run just launched, else **BLOCKED** —
  base mode: `payload.target.mode === "branch"` AND `payload.target.baseRef === $BASE_REF`;
  working-tree mode: `payload.target.mode === "working-tree"`.
- **Outcome 1 — structured:** `payload.result` is a findings-bearing object → use it; mark Codex DONE.
- **Outcome 2 — degraded fallback:** otherwise existence-check `file:line` refs parsed from
  `payload.rawOutput`; ≥1 passes → Codex DONE with a mandatory degraded note; zero recover → Codex BLOCKED.

## Phase 6 — Citation Verification (deterministic)

**First, drop excluded build output (every track, incl. Codex).** If a finding's `file` matches the
Phase 1 `EXCLUDES` set, move it to Dropped Findings as `dropped_excluded_build_output`. Workflow reviewers
never see these files; this backstops Codex, which self-collects its own diff.

Then, for every surviving finding (per the pseudocode in
`comprehensive-code-review/references/workflow-and-codex.md`):

0. If the finding carries `refuted: true` (the workflow's adversarial Verify stage disproved it) → move to
   Dropped Findings as `refuted`, recording `refute_reason`. Never resurrect a refuted finding.
   0a. If the finding carries `kind: "systemic"` (systemic-failure-reviewer only) — apply the systemic
   gate BEFORE the standard citation check: require `failure_mode` (non-empty, from the closed taxonomy)
   AND `scenario` (non-empty) AND `anchors` (≥2 entries) — else drop (`dropped_systemic_incomplete`).
   For every anchor, apply the same line±2 / Grep-rescue logic from step 2 to `anchor.file`,
   `anchor.line`, and `anchor.verbatim`. If ANY anchor fails → drop the entire finding
   (`dropped_systemic_anchor_unverified`). If all anchors pass, continue to step 1 (the top-level
   citation is `anchors[0]` repeated; step 2 will confirm it again, which is fine).
1. Require `file`, `line`, `verbatim` (>=5 chars) — else drop (`dropped_no_citation` / `dropped_quote_too_short`).
2. Read the file at `line ±2`, collapse whitespace on both quote and content, and require the quote to be a
   substring. On miss, rescue single-line quotes: Grep the file for the fixed-string trimmed quote — exactly
   1 match → correct `line` and keep as `relocated_ok`; 0 or >1 matches, or a multi-line quote → drop
   (`dropped_no_match`).

3. **Outside-diff tagging**: after a `kind != "systemic"` finding passes the citation check, if its
   `file` is not in `changedFiles`, keep it but tag `outside_diff: true` — rendered as "(outside diff)"
   on the finding. (Systemic findings legitimately anchor across unchanged files; never tag them.)

Codex's structured findings carry no `verbatim`, so they are existence-checked: the cited `file` must exist
AND `line_start`/`line_end` must fall within the file's length, else drop (`codex_file_missing` /
`codex_line_out_of_range`). On the degraded fallback path, existence-check the refs parsed from
`payload.rawOutput` instead.

## Phase 7 — Group, Sort, Emit

1. `mkdir -p .quick-code-review/raw` (idempotent — already created in Phase 4).
2. Write each reviewer's raw findings to `.quick-code-review/raw/<reviewer>-<UTC-iso>.md` (derived from the
   parsed `workflow-result.json`). Codex's machine output already sits at
   `.quick-code-review/raw/codex-adversarial.json`; render a human-readable
   `.quick-code-review/raw/codex-adversarial-<UTC-iso>.md` from it (verdict, summary, findings, `next_steps`).
3. **Dedup across reviewers:** two verified findings merge when they cite the same file AND (lines within ±3
   OR identical collapsed verbatim) AND the same `kind` — never merge a `local` finding with a `systemic`
   finding even if they cite the same file (they describe different defect classes). Keep the primary
   reviewer's finding at the highest severity of the group; list the others under `also_flagged_by`. All
   counts below are post-dedup.
4. Categorize each verified finding per `comprehensive-code-review/references/report-format.md`. With this
   skill's five reviewers + Codex, only these categories will populate: **Security, Quality, Tests,
   Silent Failures, Systemic, Adversarial-Codex, Other**. (Use the fixed set; never invent a category.)
5. Map severity per the table in the reference (Codex's `critical|high|medium|low` →
   `critical|important|important|minor`; keep the native severity + `confidence` on each Codex finding).
6. Sort within each category by severity DESC, then file ASC. For **Adversarial-Codex**, sort by severity
   DESC, then `confidence` DESC, then file ASC.
7. Write the consolidated report to `.quick-code-review/report-<UTC-iso>.md` using the skeleton in
   `comprehensive-code-review/references/report-format.md`. In the Scope section, list the excluded
   build-output patterns and note this is a **quick review (5 reviewers + Codex)**, not the comprehensive one.
8. Print the summary:

   ```
   ## Quick Code Review complete

   Report: .quick-code-review/report-<ts>.md
   Reviewers: <n> DONE, <n> SKIPPED, <n> BLOCKED
   Findings: <total> verified post-dedup (<n> critical, <n> important, <n> minor; <n> duplicates merged)
   Dropped: <n> (<n> citation-unverifiable, <n> refuted, <n> excluded build output)
   Capped: <n> findings discarded by reviewer caps (<reviewer names>)   # only when any reviewer reported dropped_by_cap > 0
   ```

## Phase 8 — STATUS line

If all reviewers are DONE or SKIPPED (no BLOCKED) and Codex is DONE/SKIPPED:

```
STATUS: DONE
```

If any reviewer or Codex is BLOCKED:

```
STATUS: DONE_WITH_CONCERNS — <n> track(s) BLOCKED: <names>
```

The STATUS line must be the absolute last line of your response.
