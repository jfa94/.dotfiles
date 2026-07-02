---
name: comprehensive-code-review
description: >
  Run a comprehensive code review using parallel specialist reviewers and a Codex adversarial
  review. Covers architecture, security, quality, tests, types, comments, simplification,
  silent failures, documentation, systemic failure modes, and optionally implementation-vs-spec.
  Every critical and important finding is adversarially verified by a fresh refuter agent before
  it can ship. Consolidates all findings into a single deduplicated report with verified
  file:line citations.
  Usage: /comprehensive-code-review [--base <ref>] [--full] [--spec <path>]
argument-hint: "[--base <ref>] [--full] [--spec <path>]"
---

# Comprehensive Code Review

You are the orchestrator for a comprehensive, multi-dimensional code review. You dispatch the
specialist reviewers through a **Workflow** (which forces every reviewer into one findings schema,
adversarially verifies every critical/important finding with a fresh refuter agent, and writes the
consolidated result to a file), run **Codex** as a concurrent backgrounded Bash job whose scope
mirrors the reviewers (bounded only under `--full`), verify every finding has a real file:line
citation, dedup across reviewers, group results by category, and emit one consolidated report.

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

| Thought                                      | Reality                                                                            |
| -------------------------------------------- | ---------------------------------------------------------------------------------- |
| "I'll Task each reviewer myself"             | Iron Law 4. Reviewers go through the Workflow, not direct Task calls.              |
| "The finding looks right, I'll include it"   | Iron Law 1. Verify file:line first. Drop if no match.                              |
| "Workflow's still running, I'll report now"  | Iron Law 2. workflow-result.json written AND Codex terminated first.               |
| "I'll create a new category for this"        | Iron Law 3. Use fixed set; map to "Other" if nothing fits.                         |
| "Codex isn't available, I'll abort"          | Mark Codex SKIPPED. The Workflow still runs.                                       |
| "I'll poll `status <id>` for Codex"          | No. adversarial-review never backgrounds; read the JSON file the Bash task writes. |
| "I'll harvest the Workflow's return value"   | No. Read .comprehensive-code-review/raw/workflow-result.json instead.              |
| "--full, so I'll build a root..HEAD diff"    | No. --full sends agents the file inventory; they Read files.                       |
| "I'll summarise a finding without the quote" | No quote = no finding. Period.                                                     |
| "A refuted finding still looks right to me"  | Refuted = Dropped Findings with the refuter's reason. Never resurrect it.          |
| "Same issue from 3 reviewers = 3 findings"   | Dedup first (Phase 8). Merge, keep highest severity, annotate "Also flagged by".   |

## Dimension ownership map (cross-cutting)

Every cross-cutting dimension has an owning reviewer whose prompt explicitly hunts for it — do not
assume a dimension is covered unless its owner ran:

- **Dead code / semantic duplication / over-engineering** → simplification-reviewer
- **Dependency & supply-chain hygiene** (new-dep necessity, typosquatting, devDeps in prod) → security-reviewer
- **PII-in-logs / data leakage** → security-reviewer
- **Observability gaps** (failure paths with zero telemetry) → silent-failure-hunter
- **Statically-visible performance** (N+1, super-linear loops, blocking IO, unbounded growth) → quality-reviewer
- **Contract compatibility** (public API breaking changes) & **migration safety** → quality-reviewer
- **Test pyramid health / over-pinned tests** → test-coverage-reviewer

Orchestrator-level (yours, not a reviewer's):

- **Hotspot/churn risk**: high-churn files with diffuse ownership (flag if CODEOWNERS absent)
- **Diff reviewability**: detection degrades past ~400 lines; at 2000 lines the skill switches from
  inline diff to manifest mode (full diff on disk + risk-ordered read-all, never truncated — Phase 1) —
  note the switch in Scope, and disclose any pathological partial coverage

---

## Phase 1 — Detect Scope & Gather Inputs

Parse the skill arguments (from `$ARGUMENTS`):

```
--base <ref>   → mode = "base";  scope = git diff <ref>...HEAD
--full         → mode = "full";  scope = ENTIRE CODEBASE, current state
(no args)      → mode = "working-tree"; scope = git diff HEAD (staged + unstaged) + untracked files
--spec <path>  → path to spec file for implementation-reviewer
```

`--base <ref>` + `--full` together: mode = "full" for the agents (entire codebase), and `<ref>`
replaces `HEAD~30` as the Codex window (Phase 3's `--base` branch already does this).

Build `reviewInput` + `changedFiles` per mode.

**Build-output exclusion.** Generated/minified output (committed or untracked) is skipped so
reviewers see only hand-written code. Define `EXCLUDES` once and append `-- . "${EXCLUDES[@]}"`
to _every_ file/diff gathering command below (full / base / working-tree, inline and manifest).
The positive `.` is required so the exclude-only pathspecs resolve against the whole repo;
`top`+`glob` anchoring catches nested monorepo paths (`packages/x/dist/…`), not just repo-root.
This same list is reused by the manifest commands in `references/workflow-and-codex.md` §5 and
as the Phase 7 drop predicate. Edit this list to change what review skips:

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
# mode = full  → agents Read files themselves; send the inventory, not a diff
CHANGED_FILES=$(git ls-files -- . "${EXCLUDES[@]}")
# reviewInput = "Review the ENTIRE codebase at its current committed state. Use Read/Grep/Glob to
#   open and inspect the actual files listed under 'Changed files' above. Do NOT expect a diff."
# Empty guard: if CHANGED_FILES is empty -> print "Nothing to review: no tracked files (build outputs excluded)." STATUS: DONE. Stop.
# Hotspot priority: agents cannot read everything — rank by churn so coverage is deliberate:
HOTSPOTS=$(git log --since="12 months ago" --format= --name-only -- . "${EXCLUDES[@]}" | sort | uniq -c | sort -rn | head -20)
# Append to reviewInput: "Prioritize these high-churn hotspot files (defect density concentrates
#   in churn): <HOTSPOTS>. Cover hotspots first, then sample the rest."
# Note in the report's Scope section that --full coverage is hotspot-prioritized sampling, not exhaustive.

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

Read the **11** reviewer agent files (`agents/<name>.md`) into the `reviewers` array as
`{ name, role }`. Include `systemic-failure-reviewer` in every run regardless of mode — it
self-skips on non-stateful diffs via its Phase 0 check, so gating it off at the roster level
would reopen the "absence reads as clean" blind spot. Read `CLAUDE.md` path. Read the spec file
if `--spec` was given.

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
elif [ "$MODE" = "full" ]; then          # --full alone → wider recent window; systemic reviewer covers the rest
  if [ "$(git rev-list --count HEAD)" -gt 30 ]; then CODEX_BASE=$(git rev-parse HEAD~30);
  else CODEX_BASE=$(git rev-list --max-parents=0 HEAD | tail -1); fi
  CODEX_TARGET="--base $CODEX_BASE"
else                                     # working tree → mirror reviewers' uncommitted diff
  CODEX_TARGET="--scope working-tree"
fi
```

In `--base` and working-tree modes Codex sees the same scope as the agents. Only under `--full` do
they diverge (agents = whole codebase, Codex = `HEAD~30` window, to stay within Codex's context
limit) — note this `--full`-only mismatch in the report.

## Phase 4 — Implementation-Reviewer Eligibility

If `SPEC_PATH` is null → exclude implementation-reviewer from `reviewers`; mark it SKIPPED ("no --spec provided").
If `SPEC_PATH` is set but the file does not exist → exclude it; mark SKIPPED ("spec file not found: <path>").
Otherwise → include `{ name: "implementation-reviewer", role: <file body> }` in `reviewers`, and set `spec = { path, content }`.

## Phase 5 — Launch Both Tracks (single message)

First ensure the output dir exists (both the workflow's persist agent and Codex's raw output land here),
and delete any prior run's output files (the workflow result and Codex's JSON/stderr) so a stale file
from an earlier run can never be mistaken for this run's output (the dir is gitignored, so stale state
persists locally between runs):

```bash
mkdir -p .comprehensive-code-review/raw
rm -f .comprehensive-code-review/raw/workflow-result.json \
      .comprehensive-code-review/raw/codex-adversarial.json \
      .comprehensive-code-review/raw/codex-adversarial.stderr.log
```

<EXTREMELY-IMPORTANT>
Your next assistant message MUST launch both background tracks together:

1. **Bash call (`run_in_background: true`)** — Codex adversarial review, ONLY if `CODEX_AVAILABLE=true`.
   `adversarial-review` has NO real backgrounding (`--background` is a no-op for reviews and prints no
   job id) — run it synchronously and let the Bash tool background it. Pass `--json` so the companion
   emits one structured JSON object on stdout (`result` = the review: `verdict` + `findings[]`, each
   carrying `file`/`line_start`/`line_end`/`severity`/`confidence`/`recommendation`); redirect stdout to
   a file and stderr to a separate log so nothing can interleave with the captured JSON:

   ```bash
   node "$CODEX_CMD" adversarial-review --json $CODEX_TARGET \
     >.comprehensive-code-review/raw/codex-adversarial.json \
     2>.comprehensive-code-review/raw/codex-adversarial.stderr.log
   ```

   Do NOT pass `--background`. Do NOT pass `--model` (let the companion auto-default to the best model).
   Do NOT poll the companion's `status`/`result` subcommands. The Bash task keeps running across turns;
   harvest the JSON file when it terminates (Phase 6).

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
`.comprehensive-code-review/raw/workflow-result.json` — and parse `{ scopeLabel, mode, reviewers: [...] }`.
Do NOT rely on the Workflow's JS return value or `TaskOutput`; neither surfaces the structured object to
you. Each reviewer entry has `status`, optional `verdict`, and `findings[]`. **Staleness guard:** verify
the file's `scopeLabel`/`mode` match the run you just launched — if they are absent or differ, the file is
a stale leftover (the current run's persist failed), so do NOT trust it; mark every dispatched reviewer
BLOCKED("workflow-result.json stale/foreign — persist failed"). Likewise, if the file is missing or
unparseable, mark every dispatched reviewer BLOCKED("workflow-result.json missing/unparseable") and continue.

Then harvest Codex if `CODEX_AVAILABLE=true`: the Codex review ran as a backgrounded **Bash** task that
wrote its structured JSON to `.comprehensive-code-review/raw/codex-adversarial.json`. When the Bash task
terminates, **Read that file and `JSON.parse` it** — there is no companion job to poll. Wait for it to
finish before emitting the report (Iron Law 2). Then run the harvest as a **validity/staleness gate,
then a two-outcome branch** (do NOT mark a structured-output failure as a clean success):

**Gate A — validity/crash:** if the file is missing/empty/not valid JSON, or `payload.target` is absent
(the companion always assigns `target` before `result`/`parseError`, so its absence means a crash mid-emit),
or the task has not terminated after a reasonable wait → Codex **BLOCKED**("codex-adversarial.json
missing/unparseable — companion crash / did not terminate; see codex-adversarial.stderr.log").

**Gate B — staleness:** verify `payload.target` matches the run just launched, else **BLOCKED**
("codex-adversarial.json stale/foreign — target mismatch"):

- base / `--full` mode: `payload.target.mode === "branch"` AND `payload.target.baseRef === $BASE_REF`
  (`$CODEX_BASE` under `--full` alone).
- working-tree mode: `payload.target.mode === "working-tree"`.

**Outcome 1 — structured:** `payload.result` is a non-null object containing a `findings` array → use the
structured review: `verdict` (`approve` / `needs-attention`), `summary`, `findings[]`, and `next_steps[]`.
Mark Codex DONE.

**Outcome 2 — degraded fallback:** otherwise (`payload.result` is null, absent, or not a findings-bearing
object — i.e. `payload.parseError` set or the payload is malformed) → existence-check any `file:line`
references parsed from `payload.rawOutput`:

- **≥1 reference passes** the existence-check → Codex DONE, and add a **mandatory degraded note** in both
  the Reviewers table Verdict cell (suffix `(degraded — narrative fallback)`) and the Codex section
  ("structured output unavailable — findings recovered from narrative fallback; degraded, not
  schema-validated").
- **zero references** recover → Codex **BLOCKED**("structured output unavailable and no findings
  recoverable from narrative output").

## Phase 7 — Citation Verification (deterministic)

**First, drop excluded build output (every track, incl. Codex).** If a finding's `file` matches
the Phase 1 `EXCLUDES` set — a path segment of `dist/`, `build/`, `out/`, `.next/`, `.nuxt/`,
`.svelte-kit/`, `.output/`, or `coverage/`, or a name ending in `.min.js`, `.min.css`, or `.map`
— move it to Dropped Findings as `dropped_excluded_build_output`. Workflow reviewers never see
these files (their input is filtered upstream); this backstops Codex, which self-collects its
own diff and cannot honor the pathspecs.

Then, for every surviving finding from every reviewer (per the pseudocode in `references/workflow-and-codex.md`):

0. If the finding carries `refuted: true` (the workflow's adversarial Verify stage disproved it) →
   move to Dropped Findings as `refuted`, recording `refute_reason`. Never resurrect a refuted
   finding, however right it looks.
   0a. If the finding carries `kind: "systemic"` (systemic-failure-reviewer only) — apply the
   systemic gate BEFORE the standard citation check: - Require `failure_mode` (non-empty, from the closed taxonomy) AND `scenario` (non-empty)
   AND `anchors` (≥2 entries) — else drop (`dropped_systemic_incomplete`). - For every anchor: apply the same line±2 / Grep-rescue logic to `anchor.file`, `anchor.line`,
   and `anchor.verbatim` that step 2 applies to the top-level citation. If ANY anchor fails
   → drop the entire finding (`dropped_systemic_anchor_unverified`). - If all anchors pass, continue to step 1 (the top-level citation is `anchors[0]` repeated;
   step 2 will confirm it again, which is fine).
1. Require `file`, `line`, `verbatim` (>=5 chars) — else drop (`dropped_no_citation` / `dropped_quote_too_short`).
2. Read the file at `line ±2`, collapse whitespace on both quote and content, and require the quote
   to be a substring. On miss, rescue single-line quotes before dropping: Grep the file for the
   fixed-string trimmed quote — exactly 1 matching line → correct `line` and keep as `relocated_ok`
   (line-number drift is the canonical LLM citation failure); 0 or >1 matches, or a multi-line
   quote → drop (`dropped_no_match`).

3. **Outside-diff tagging** (base / working-tree modes only): after a `kind != "systemic"` finding
   passes the citation check, if its `file` is not in `changedFiles`, keep it but tag
   `outside_diff: true` — rendered as "(outside diff)" on the finding. Pre-existing issues in
   untouched files are still worth surfacing, but must be distinguishable from findings on the change.
   (Systemic findings legitimately anchor across unchanged files; never tag them.)

Collect dropped findings into the "Dropped Findings" list. Codex's structured findings carry no
`verbatim` (the review schema has no quote field), so they are existence-checked, not quote-verified:
the cited `file` must exist AND `line_start`/`line_end` must fall within the file's length. A finding
that fails this check moves to Dropped Findings (`codex_file_missing` / `codex_line_out_of_range`) —
never silently discarded. (On the degraded fallback path (Phase 6 Outcome 2), existence-check the
`file:line` references parsed from `payload.rawOutput` instead.)

## Phase 8 — Group, Sort, Emit

1. `mkdir -p .comprehensive-code-review/raw` (idempotent — already created in Phase 5).
2. Write each reviewer's raw findings to `.comprehensive-code-review/raw/<reviewer>-<UTC-iso>.md`
   (derived from the parsed `workflow-result.json`). Codex's machine output already sits at
   `.comprehensive-code-review/raw/codex-adversarial.json` (written in Phase 5); render a human-readable
   `.comprehensive-code-review/raw/codex-adversarial-<UTC-iso>.md` from it (verdict, summary, findings,
   `next_steps`) for parity with the other reviewers' `.md` files.
3. **Dedup across reviewers** (overlapping mandates guarantee duplicates): two verified findings
   merge when they cite the same file AND (lines within ±3 OR identical collapsed verbatim) AND
   **the same `kind`** — never merge a `local` finding with a `systemic` finding even if they
   cite the same file (they describe different defect classes; the Themes section is where the
   connection is drawn instead). Keep the primary reviewer's finding at the highest severity of
   the group; list the others under `also_flagged_by`. All counts below are post-dedup.
4. Categorize each verified finding per `references/report-format.md`.
5. Map severity per the table in `references/report-format.md` (Codex's `critical|high|medium|low` map
   to `critical|important|important|minor`; keep the native severity + `confidence` on each rendered
   Codex finding so the 4→3 collapse loses no signal).
6. Sort within each category by severity DESC, then file ASC. For **Adversarial-Codex**, sort by
   severity DESC, then `confidence` DESC, then file ASC (confidence orders, never filters).
7. Write the consolidated report to `.comprehensive-code-review/report-<UTC-iso>.md` using the
   skeleton in `references/report-format.md`. In the Scope section, list the excluded
   build-output patterns (Phase 1 `EXCLUDES`), and note the agent vs. Codex scope when mode = full.
8. Print the summary:

   ```
   ## Comprehensive Code Review complete

   Report: .comprehensive-code-review/report-<ts>.md
   Reviewers: <n> DONE, <n> SKIPPED, <n> BLOCKED
   Findings: <total> verified post-dedup (<n> critical, <n> important, <n> minor; <n> duplicates merged)
   Dropped: <n> (<n> citation-unverifiable, <n> refuted, <n> excluded build output)
   Capped: <n> findings discarded by reviewer caps (<reviewer names>)   # only when any reviewer reported dropped_by_cap > 0
   ```

   Append WARNING lines when applicable (one line each, only when the condition applies):

   - When `mode === "full"` AND Codex ran: `⚠ Codex reviewed only HEAD~30…HEAD; whole-codebase design review relied on the systemic reviewer [present | ABSENT — systemic failure modes NOT covered].`
   - When Codex was SKIPPED entirely: `⚠ Codex SKIPPED — adversarial/design track did NOT run.`

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
