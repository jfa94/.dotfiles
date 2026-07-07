---
name: quick-code-review
description: >
  Run a focused, quick code review with the five crucial specialist reviewers (security,
  quality, test coverage, silent failures, systemic failures) plus a Codex adversarial review. A lean subset of
  comprehensive-code-review: same rigor — every critical/important finding (including Codex's)
  is adversarially verified by a fresh refuter agent, and every finding is dropped unless it has
  a verified file:line citation — but fewer dimensions, so the report is tighter and faster to triage.
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
   Every reported reviewer finding cites file:line + verbatim quote >=10 chars, verified by
   reading the file. Unverifiable findings are dropped before emission. No exceptions.

2. NO REPORT UNTIL ALL TRACKS RESOLVE.
   The reviewer Workflow must complete (its workflow-result.json written) AND Codex must
   reach a terminal state (done / skipped / blocked) AND, when launched, the Codex-verify
   Workflow (Phase 5.5) must resolve before you emit the report. No exceptions.

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
| "I'll poll `status <id>` for Codex"          | No. adversarial-review never backgrounds; read the JSON file the Bash task writes.  |
| "I'll harvest the Workflow's return value"   | No. Read .quick-code-review/raw/workflow-result.json instead.                       |
| "I'll summarise a finding without the quote" | No quote = no finding. Period.                                                      |
| "A refuted finding still looks right to me"  | Refuted = Dropped Findings with the refuter's reason. Never resurrect it.           |
| "Same issue from 2 reviewers = 2 findings"   | The script dedups (Phase 6). Merged, highest severity, annotated "Also flagged by". |
| "Codex findings ship as-is"                  | Critical/high/medium Codex findings get the verify-only Workflow pass (Phase 5.5).  |
| "I'll hand-execute the citation checks"      | Run verify-citations.mjs (Phase 6) — hand-execution is the failure mode it removes. |
| "This needs the whole codebase / a spec"     | That's comprehensive-code-review. Quick reviews a diff only.                        |

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
against the whole repo; `top`+`glob` anchoring catches nested monorepo paths. This same list is
mirrored by `verify-citations.mjs`'s drop predicate (Phase 6):

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
  ':(top,exclude,glob)**/pnpm-lock.yaml'
  ':(top,exclude,glob)**/package-lock.json'
  ':(top,exclude,glob)**/yarn.lock'
  ':(top,exclude,glob)**/bun.lock'
  ':(top,exclude,glob)**/bun.lockb'
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
      .quick-code-review/raw/codex-adversarial.stderr.log \
      .quick-code-review/raw/codex-verify-result.json \
      .quick-code-review/raw/verified-findings.json
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
do NOT trust it.

**Journal fallback (before declaring reviewers BLOCKED):** if the file is missing, stale, or unparseable,
reconstruct from the run's journal first. The Workflow tool result named the run's `runId` and transcript
directory; `<transcript dir>/journal.jsonl` records every agent's structured return as
`{"type":"result", ..., "result": <object>}` lines. Reviewer results echo `name`, refuter verdicts echo
`file`/`line` — rebuild `{ scopeLabel, mode, reviewers: [...] }` (criticals count as refuted only when
BOTH of their two verdicts refute; importants on one). This pairing is **best-effort, not
deterministic** — the journal has no record of an agent's `label`, only the schema-optional
`file`/`line` echo, so if a verdict omits it or matches more than one finding, leave that finding
unrefuted rather than guess (mis-pairing can then at worst let a refuted finding survive, never drop
a real one). Write it to `workflow-result.json`, and continue. Only if the journal is also
missing/unusable: mark every dispatched reviewer
BLOCKED("workflow-result.json missing/stale and journal unavailable") and continue.

Then harvest Codex if `CODEX_AVAILABLE=true`: it ran as a backgrounded **Bash** task that wrote its
structured JSON to `.quick-code-review/raw/codex-adversarial.json`. When the Bash task terminates, **Read
that file and `JSON.parse` it** — there is no companion job to poll. Wait for it to finish before emitting
the report (Iron Law 2). Apply the same validity/staleness gates and two-outcome routing (structured vs
degraded narrative fallback) as `comprehensive-code-review/references/workflow-and-codex.md` specifies:

- **Gate A — validity/crash:** file missing/empty/not valid JSON, or `payload.target` absent, or task not
  terminated after a reasonable wait → Codex **BLOCKED**(see codex-adversarial.stderr.log).
- **Gate B — staleness:** `payload.target` must match the run just launched, else **BLOCKED** —
  base mode: `payload.target.mode === "branch"` AND `payload.target.baseRef` resolves to the same SHA as
  `$BASE_REF`. `payload.target.baseRef` is untrusted external output — before using it in any shell
  command, verify it matches `^[A-Za-z0-9._/@{}~^-]+$` and **BLOCK** if it does not (never interpolate a
  raw field into `git rev-parse`); then compare resolved SHAs, not ref spellings;
  working-tree mode: `payload.target.mode === "working-tree"`.
- **Outcome 1 — structured:** `payload.result` is a findings-bearing object → use it; mark Codex DONE.
- **Outcome 2 — degraded fallback:** otherwise existence-check `file:line` refs parsed from
  `payload.rawOutput`; ≥1 passes → Codex DONE with a mandatory degraded note; zero recover → Codex BLOCKED.

## Phase 5.5 — Verify Codex Findings (adversarial)

Runs ONLY when Phase 5 ended with Codex **Outcome 1 (structured)** AND `payload.result.findings`
contains ≥1 finding with native severity `critical`, `high`, or `medium`. Degraded-fallback findings
are never refuted — the mandatory degraded note already marks them as lower-trust.

1. Launch the sibling skill's workflow script in verify-only mode:

   ```
   Workflow({
     scriptPath: "<comprehensive-code-review skill dir>/scripts/review-fanout.workflow.js",
     args: { scopeLabel, mode, repoRoot, outDir: ".quick-code-review", verifyOnly: <payload.result.findings array> }
   })
   ```

   It refutes each critical/high/medium finding with a fresh agent (same keep-on-uncertainty bias as
   the reviewer refuters) and persists to `.quick-code-review/raw/codex-verify-result.json`.

2. On the completion notification, Read that file; apply the same `scopeLabel`/`mode` staleness guard
   as Phase 5. Findings annotated `refuted: true` go to Dropped Findings (`refuted`, with
   `refute_reason`) — never resurrect them.
3. If the verify pass itself fails (workflow error, result file missing/stale) → keep ALL Codex
   findings unrefuted AND add a mandatory report note ("Codex findings not adversarially verified —
   verify pass failed"). Never drop a finding because verification broke.

The result feeds Phase 6 via `--codex-verify`.

## Phase 6 — Citation Verification (scripted, deterministic)

Do NOT hand-execute citation checks — run the sibling skill's script (spec:
`comprehensive-code-review/references/workflow-and-codex.md` §6). Write the changed-files list first:

```bash
printf '%s\n' "$CHANGED_FILES" > .quick-code-review/raw/changed-files.txt
node "<comprehensive-code-review skill dir>/scripts/verify-citations.mjs" \
  --workflow-result .quick-code-review/raw/workflow-result.json \
  --codex .quick-code-review/raw/codex-adversarial.json \
  --codex-verify .quick-code-review/raw/codex-verify-result.json \
  --mode "$MODE" \
  --changed-files .quick-code-review/raw/changed-files.txt \
  --repo-root "$REPO_ROOT" \
  --out .quick-code-review/raw/verified-findings.json
```

Omit `--codex` when Codex is SKIPPED/BLOCKED or took the degraded fallback (the script processes only
structured payloads; on the degraded path existence-check the `rawOutput` refs yourself per Phase 5
Outcome 2). Omit `--codex-verify` when Phase 5.5 didn't run. If the script errors, fix the invocation
and re-run — never fall back to hand-verification.

The script implements the full §6 procedure: EXCLUDES drop (incl. the Codex backstop), refuted drop,
the systemic gate, the line±2 / grep-rescue citation check (`ok` / `relocated_ok`), outside-diff
tagging, Codex existence checks + native→standard severity mapping, and cross-reviewer dedup.

Read `verified-findings.json`: `findings` (verified, post-dedup), `dropped` (with per-finding
`verification` reasons), `reviewers` (status pass-through), and `stats` (`perReviewer` +
`duplicatesMerged` — feeds Phase 7's Calibration line).

## Phase 7 — Group, Sort, Emit

1. Categorize each verified finding per `comprehensive-code-review/references/report-format.md`. With this
   skill's five reviewers + Codex, only these categories will populate: **Security, Quality, Tests,
   Silent Failures, Systemic, Adversarial-Codex, Other**. (Use the fixed set; never invent a category.
   The script already deduped, severity-mapped Codex findings — native severity + `confidence`
   preserved — and tagged `outside_diff`.)
2. Sort within each category by severity DESC, then file ASC. For **Adversarial-Codex**, sort by severity
   DESC, then `confidence` DESC, then file ASC.
3. Write the consolidated report to `.quick-code-review/report-<UTC-iso>.md` using the skeleton in
   `comprehensive-code-review/references/report-format.md`. In the Scope section, list the excluded
   build-output patterns and note this is a **quick review (5 reviewers + Codex)**, not the comprehensive
   one. The raw JSON files under `.quick-code-review/raw/` are the machine record — do NOT render
   per-reviewer or Codex `.md` files.
4. Print the summary:

   ```
   ## Quick Code Review complete

   Report: .quick-code-review/report-<ts>.md
   Reviewers: <n> DONE, <n> SKIPPED, <n> BLOCKED
   Findings: <total> verified post-dedup (<n> critical, <n> important, <n> minor; <n> duplicates merged)
   Dropped: <n> (<n> citation-unverifiable, <n> refuted, <n> excluded build output)
   Capped: <n> findings discarded by reviewer caps (<reviewer names>)   # only when any reviewer reported dropped_by_cap > 0
   Calibration: <reviewer> <n> refuted, <n> citation-dropped; …        # from stats.perReviewer; only reviewers with non-zero counts; omit line if all zero
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
