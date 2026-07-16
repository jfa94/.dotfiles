---
name: focused-code-review
description: >
  Run several focused code reviews in parallel — five crucial specialist reviewers (security,
  quality, simplification, silent failures, systemic failures), each a narrow lens, plus a Codex
  adversarial review. A lean subset of comprehensive-code-review: same rigor — every
  critical/important finding (including Codex's) is adversarially verified by a fresh refuter agent,
  and every finding is dropped unless it has a verified file:line citation — but fewer dimensions,
  so the report is tighter to triage. Reviews a diff (working tree by default, or `--base <ref>`).
  For a whole-codebase audit or spec-conformance, use comprehensive-code-review instead.
  Usage: /focused-code-review [--base <ref>] [--pass <n>]
argument-hint: "[--base <ref>] [--pass <n>]"
---

# Focused Code Review

You are the orchestrator for a focused, multi-dimensional code review — the lean sibling of
`comprehensive-code-review`. You dispatch ONE **Workflow** that owns everything concurrent: the
**five** crucial specialist reviewers (one findings schema, every critical/important finding
adversarially verified by a fresh refuter agent), the **Codex** adversarial review (a codex-runner
agent runs the CLI, scope mirrors the reviewers), and the Codex-verify refutation pass — all inside
the single workflow, so no track can serialize behind another. You then verify every finding has a
real file:line citation, dedup across reviewers, group results by category, and emit one consolidated
report.

This skill **reuses the comprehensive skill's engine** — the workflow script, the reviewer agent
definitions, and the reference contracts all live in the sibling `comprehensive-code-review/` directory
(same `skills/` parent as this skill). Nothing is duplicated; you point at those files by path.

Before proceeding, read the two reference files in the sibling skill's directory —
`comprehensive-code-review/references/workflow-and-codex.md` and
`comprehensive-code-review/references/report-format.md`. They define the workflow contract, the findings
schema, the Codex target-resolution table, the citation-verification pseudocode, and the output format.
**One deviation from those references applies to this skill:** it has no `--full` and no `--spec`
mode — only working-tree and `--base`.

## The five reviewers (fixed)

This skill always runs exactly these five, read from `comprehensive-code-review/agents/`:

- `security-reviewer` — injection, auth/authz, secrets, PII-in-logs, insecure defaults (source→sink traced)
- `quality-reviewer` — logic errors, edge cases, caller breakage, concurrency/async and statically-visible performance (it owns both dimensions)
- `simplification-reviewer` — dead code, over-engineering, diff bloat, defenses against adjudicated ghosts (never blocks; its findings are counter-pressure against ratcheting fixes)
- `silent-failure-hunter` — swallowed errors, empty catches, unjustified fallbacks masking failure, observability gaps
- `systemic-failure-reviewer` — cross-file/cross-stage failure modes: stuck-states, invariants without repair, unsafe/no-op recovery, over-pinned contracts (self-skips when the diff has no stateful surface)

(test-coverage-reviewer is deliberately NOT in this roster — in review⇄fix loops its
test-symmetry importants drove non-converging passes; comprehensive-code-review still runs it.)

## Iron Laws

```
1. NO FINDING WITHOUT A VERIFIED FILE:LINE CITATION.
   Every reported reviewer finding cites file:line + verbatim quote >=10 chars, verified by
   reading the file. Unverifiable findings are dropped before emission. No exceptions.

2. NO REPORT UNTIL THE WORKFLOW RESOLVES.
   The single Workflow must complete (its workflow-result.json written, carrying reviewer
   AND Codex terminal states) before you emit the report. No exceptions.

3. NO INVENTED CATEGORIES.
   Report uses the fixed category set in references/report-format.md.
   Findings that don't fit go to "Other" with reviewer name preserved. No exceptions.

4. EVERYTHING DISPATCHES VIA THE WORKFLOW.
   Do not hand-dispatch reviewer Task calls, and do not run Codex yourself with a Bash
   call. The Workflow owns reviewer fan-out, the Codex track, and the Codex-verify pass.
   You make NO direct background calls. No exceptions.

5. REFUTED = DEAD EVERYWHERE.
   A refuted or previously-adjudicated finding never re-enters the report body, Themes, or
   fix guidance — including residuals, "weakened versions", or hardening suggestions derived
   from it. A different concern at the same site is a NEW finding that must survive its own
   refutation. Refuted critical/important findings are appended to the disposition ledger at
   report time (Phase 7). No exceptions.
```

## Red Flags — STOP and re-read this prompt

| Thought                                      | Reality                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------- |
| "I'll Task each reviewer myself"             | Iron Law 4. Reviewers go through the Workflow, not direct Task calls.               |
| "The finding looks right, I'll include it"   | Iron Law 1. Verify file:line first. Drop if no match.                               |
| "Workflow's still running, I'll report now"  | Iron Law 2. workflow-result.json written first.                                    |
| "I'll create a new category for this"        | Iron Law 3. Use fixed set; map to "Other" if nothing fits.                          |
| "Codex isn't available, I'll abort"          | Pass `codex: null`. The workflow marks Codex SKIPPED; reviewers still run.          |
| "I'll run Codex myself with a Bash call"     | Iron Law 4. The workflow's codex-runner agent owns the CLI run.                     |
| "I'll harvest the Workflow's return value"   | No. Read `<runDir>/raw/workflow-result.json` instead.                                |
| "I'll summarise a finding without the quote" | No quote = no finding. Period.                                                      |
| "A refuted finding still looks right to me"  | Refuted = Dropped Findings with the refuter's reason. Never resurrect it.           |
| "Same issue from 2 reviewers = 2 findings"   | The script dedups (Phase 6). Merged, highest severity, annotated "Also flagged by". |
| "Codex findings ship as-is"                  | Critical/high/medium Codex findings are refuted inside the workflow's Codex-verify stage. |
| "I'll hand-execute the citation checks"      | Run verify-citations.mjs (Phase 6) — hand-execution is the failure mode it removes. |
| "This needs the whole codebase / a spec"     | That's comprehensive-code-review. This skill reviews a diff only.                   |
| "The refuted finding still has a valid residual" | Iron Law 5. Refuted = dead everywhere; a residual is a new finding or nothing.  |
| "This adjudicated finding looks real, I'll promote it" | Only via challenges_disposition with NEW evidence — never by re-including it. |

## Convergence contract (for loop-callers)

A review⇄fix loop that treats every NEEDS-CHANGES as "go again" ratchets: each pass adds guards,
tests, and comments and removes nothing. When this skill is invoked inside a loop:

- Default max **2 fix passes** per subject. Re-invoke with `--pass <n>` (pass 1 = first review).
- Only a NEEDS-CHANGES verdict justifies another pass — and the verdict gates on `stats.blocking`
  alone. Minors, test-hardening, simplification, and comment findings never trigger one.
- Between passes, the caller records decisions on findings it declines to fix:
  `node "<comprehensive-code-review skill dir>/scripts/review-run.mjs" disposition --repo-root <root> --file <f> --title "<t>" --status accepted-risk|wont-fix --reason "<why>" --decided-by caller [--keywords "a,b"]`
  The next pass auto-suppresses matching re-raises into the Previously Adjudicated section.
- Pass ≥3 with NEEDS-CHANGES renders **STOP-LOOPING** in the report: hand the remaining blockers
  to a human. More passes add armor, not correctness.
- Fixers act under the report's Fix-Scope Contract — smallest diff, deletion is a valid fix, no
  out-of-scope hardening.

---

## Phase 1 — Detect Scope & Gather Inputs

Parse the skill arguments (from `$ARGUMENTS`):

```
--base <ref>   → mode = "base";  scope = git diff <ref>...HEAD
(no args)      → mode = "working-tree"; scope = git diff HEAD (staged + unstaged) + untracked files
--pass <n>     → review⇄fix loop iteration (default 1); recorded in run.json, drives STOP-LOOPING
```

There is no `--full` and no `--spec` in this skill. If either is passed, tell the user this skill reviews
a diff only and to use `/comprehensive-code-review` for whole-codebase or spec-conformance review, then
proceed treating the rest of the args normally (ignore the unsupported flag).

First gather `changedFiles` per mode and apply the empty guard without writing artifacts. Then create
a unique run exactly as the shared reference specifies, with `PROFILE=focused` and
`--pass-number "${PASS:-1}"`, before materializing
`reviewInput`, a manifest, or any workflow output. Only after writing the initial `<runDir>/run.json`
may you build `reviewInput` or write review artifacts.

**Build-output exclusion.** Generated/minified output (committed or untracked) is skipped so reviewers
see only hand-written code. Define `EXCLUDES` once and append `-- . "${EXCLUDES[@]}"` to _every_
file/diff gathering command below. The positive `.` is required so the exclude-only pathspecs resolve
against the whole repo; `top`+`glob` anchoring catches nested monorepo paths. This same list is
mirrored by `verify-citations.mjs`'s drop predicate (Phase 6):

```bash
EXCLUDES=(
  ':(top,exclude,glob).code-review/**'
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

Read the five reviewer agent files from the sibling skill — `comprehensive-code-review/agents/{security-reviewer,quality-reviewer,simplification-reviewer,silent-failure-hunter,systemic-failure-reviewer}.md` — into the `reviewers` array as `{ name, role }`. Read `CLAUDE.md` path.

**Disposition ledger → DISPOSITIONS_BLOCK.** If `<repoRoot>/.code-review/dispositions.json`
exists, render `DISPOSITIONS_BLOCK` for the reviewer prompts (else set it to `null`):

- Include ONLY entries whose `fingerprint.file` is in `changedFiles` (diff-scoped injection —
  the block can never outgrow the diff's relevance) AND whose file still exists; skip status
  `overturned`.
- Cap at the 20 most recent (by `decidedAt`); one line each:
  `#<id> [<status>] <file> — "<title>" — <reason>`
- Prefix with this header, verbatim:

  ```
  ## Previously adjudicated claims (input document — NOT shared belief-state)
  The claims below were adjudicated in a prior pass. Re-filing one is auto-suppressed
  downstream. ONLY with NEW evidence that a disposition is wrong, file the finding with
  challenges_disposition: <id> and cite the new evidence in why. This list says nothing
  about the rest of the code — review everything else with fresh eyes.
  ```

The FIRST time a disposition is recorded in a repo whose `.gitignore` ignores `.code-review/`,
append `!.code-review/dispositions.json` to `.gitignore` (one line, once) — the ledger is
committed; run artifacts stay ignored.

Record `scopeLabel` (human-readable), `mode`, `reviewInput`, `changedFiles`, `repoRoot`,
`claudeMdPath`, `dispositions` (the rendered block, or null), `passNumber`.

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

Then build the staleness contract the workflow's codex-runner agent will enforce (Gate B):

```bash
# base mode — resolve the trusted ref to a SHA NOW, before launch:
EXPECTED_TARGET='{ "mode": "branch", "baseSha": "'$(git rev-parse "$BASE_REF^{commit}")'" }'
# working-tree mode:
EXPECTED_TARGET='{ "mode": "working-tree" }'
```

Assemble the workflow's `codex` arg (or `null` when `CODEX_AVAILABLE=false`):

```
codex = { cmd: <CODEX_CMD>, launcher: "<comprehensive-code-review skill dir>/scripts/codex-launch.mjs",
          targetFlags: <CODEX_TARGET>, expectedTarget: <EXPECTED_TARGET as JSON> }
```

## Phase 4 — Launch the Workflow (single call)

The unique run directory already exists. Never reuse or clear another run directory.

<EXTREMELY-IMPORTANT>
Launch ONE Workflow — it owns the reviewer fan-out, the Codex adversarial review (a codex-runner
agent runs the CLI inside the workflow), AND the Codex-verify refutation pass, all concurrently —
using the sibling skill's script:

```
Workflow({
  scriptPath: "<comprehensive-code-review skill dir>/scripts/review-fanout.workflow.js",
  args: { runtime: "claude", profile: "focused", runId, scopeLabel, mode,
          reviewInput, changedFiles, repoRoot, claudeMdPath, outDir: runDir, reviewers,
          dispositions: <the Phase 1 DISPOSITIONS_BLOCK, or null>,
          codex: <the Phase 3 codex object, or null when CODEX_AVAILABLE=false> }
})
```

The `args` values are the records gathered in Phases 1–3. Pass them as real JSON. `repoRoot` MUST be the
absolute repo root. `outDir` is required and must be `.code-review/runs/<runId>`. Do not pass a `spec`.

Do NOT launch Codex yourself (no Bash call, backgrounded or otherwise) and do NOT hand-dispatch
reviewer Task calls — the workflow owns both tracks precisely so they can never serialize.
</EXTREMELY-IMPORTANT>

## Phase 5 — Harvest

When the Workflow completion notification arrives, **Read the file the workflow wrote** —
`<runDir>/raw/workflow-result.json` — and parse
`{ runtime, profile, runId, scopeLabel, mode, reviewers: [...], codex: {...} }`. Do NOT rely on the Workflow's JS return value or
`TaskOutput`. Each reviewer entry has `status`, optional `verdict`, and `findings[]`. **Staleness guard:**
verify its `runtime`, `profile`, `runId`, `scopeLabel`, and `mode` match the run — if absent or different, it is
a stale leftover (the current run's persist failed), so do NOT trust it.

**Journal fallback (before declaring reviewers BLOCKED):** if the file is missing, stale, or unparseable,
reconstruct from the run's journal first. The Workflow tool result named the run's `runId` and transcript
directory; `<transcript dir>/journal.jsonl` records every agent's structured return as
`{"type":"result", ..., "result": <object>}` lines. Reviewer results echo `name`, refuter verdicts echo
`file`/`line` — rebuild
`{ runtime: "claude", profile: "focused", runId, scopeLabel, mode, reviewers: [...] }`
(criticals count as refuted only when
BOTH of their two verdicts refute; importants on one). This pairing is **best-effort, not
deterministic** — the journal has no record of an agent's `label`, only the schema-optional
`file`/`line` echo, so if a verdict omits it or matches more than one finding, leave that finding
unrefuted rather than guess (mis-pairing can then at worst let a refuted finding survive, never drop
a real one). The codex-runner's structured return is in the journal too — rebuild the `codex` key
from it (its record carries `status`/`outcome`/`degraded_refs`; set `verifyRan` true only if
`verify:codex:*` verdicts appear). Write it to `workflow-result.json`, and continue. Only if the
journal is also missing/unusable: mark every dispatched reviewer
BLOCKED("workflow-result.json missing/stale and journal unavailable") and `codex`
BLOCKED("workflow died before the codex track resolved") — but first, if `codex-adversarial.json`
exists, salvage what the CLI wrote: apply Gates A/B and the structured/degraded routing yourself per
`comprehensive-code-review/references/workflow-and-codex.md` §6 (in that salvage path treat
`payload.target.baseRef` as untrusted — regex-validate `^[A-Za-z0-9._/@{}~^-]+$` before any git
command, compare resolved SHAs).

Then read the Codex track's terminal state from the same file's `codex` key — the workflow ran the
CLI, the validity/staleness gates (A/B), the structured/degraded routing, AND the Codex-verify
refutation pass in-script, so there is nothing to launch or poll here:

- `codex.status`: `DONE` / `BLOCKED` / `SKIPPED` (SKIPPED when you passed `codex: null`). Surface
  `codex.blocked_reason` verbatim when BLOCKED.
- `codex.outcome === "structured"` → the structured review lives in
  `<runDir>/raw/codex-adversarial.json` (`payload.result`); Phase 6's script reads it directly.
- `codex.outcome === "degraded"` → structured output was unavailable; `codex.degraded_refs` holds the
  existence-checked `file:line` refs recovered from the narrative output. Add the **mandatory degraded
  note** in both the Reviewers table Verdict cell (suffix `(degraded — narrative fallback)`) and the
  Codex section ("structured output unavailable — findings recovered from narrative fallback; degraded,
  not schema-validated").
- `codex.verifyRan === true` → the workflow refuted the critical/high/medium Codex findings and
  persisted `<runDir>/raw/codex-verify-result.json`. Read it, apply the same five-field staleness
  guard as above; findings annotated `refuted: true` go to Dropped
  Findings (`refuted`, with `refute_reason`) — never resurrect them. If the file is missing/stale
  despite `verifyRan: true` → keep ALL Codex findings unrefuted AND add a mandatory report note
  ("Codex findings not adversarially verified — verify pass failed"). Never drop a finding because
  verification broke. Degraded-fallback findings are never refuted — the degraded note already marks
  them as lower-trust.

## Phase 6 — Citation Verification (scripted, deterministic)

Do NOT hand-execute citation checks — run the sibling skill's script (spec:
`comprehensive-code-review/references/workflow-and-codex.md` §6). Write the changed-files list first:

```bash
printf '%s\n' "$CHANGED_FILES" > "$RUN_DIR/raw/changed-files.txt"
node "<comprehensive-code-review skill dir>/scripts/verify-citations.mjs" \
  --workflow-result "$RUN_DIR/raw/workflow-result.json" \
  --codex "$RUN_DIR/raw/codex-adversarial.json" \
  --codex-verify "$RUN_DIR/raw/codex-verify-result.json" \
  --mode "$MODE" \
  --changed-files "$RUN_DIR/raw/changed-files.txt" \
  --dispositions "$REPO_ROOT/.code-review/dispositions.json" \
  --repo-root "$REPO_ROOT" \
  --out "$RUN_DIR/raw/verified-findings.json"
```

Omit `--codex` when Codex is SKIPPED/BLOCKED or took the degraded fallback (the script processes only
structured payloads; on the degraded path use `codex.degraded_refs` from Phase 5). Omit
`--codex-verify` when `codex.verifyRan` is false. Always pass `--dispositions` (a missing ledger is
a no-op). If the script errors, fix the invocation
and re-run — never fall back to hand-verification.

The script never crashes on a bad Codex file — a missing/empty/invalid `--codex` or
`--codex-verify` payload is surfaced in the output instead. After running it, check
`verified-findings.json`: `codexPayloadError` set → report the Codex track BLOCKED with that reason;
`codexVerifyError` set → keep the Codex findings and add the mandatory note "Codex findings not
adversarially verified — verify pass failed"; `dispositionsError` set → adjudication matching was
skipped this pass — add a report note ("disposition ledger unreadable — previously adjudicated
claims may re-appear as findings").

The script implements the full §6 procedure: EXCLUDES drop (incl. the Codex backstop), refuted drop,
the systemic gate, the line±2 / grep-rescue citation check (`ok` / `relocated_ok`), outside-diff
tagging, Codex existence checks + native→standard severity mapping, cross-reviewer dedup, the
reachability downgrade (important+theoretical → minor), the adjudication split against the
disposition ledger, and per-finding `blocking`.

Read `verified-findings.json`: `findings` (verified, post-dedup, each with `blocking`),
`previouslyAdjudicated` (ledger-matched — render in the Previously Adjudicated section, exclude
from verdict/Themes/fix scope), `dropped` (with per-finding
`verification` reasons), `reviewers` (status pass-through), and `stats` (`perReviewer` +
`duplicatesMerged` — feeds Phase 7's Calibration line — + `unmatchedCodexRefutations` (Phase 7
warning) + `previouslyAdjudicated` + `blocking`, which drives the Summary verdict).

## Phase 7 — Group, Sort, Emit

1. Categorize each verified finding per `comprehensive-code-review/references/report-format.md`. With this
   skill's five reviewers + Codex, only these categories will populate: **Security, Quality,
   Simplification, Silent Failures, Systemic, Adversarial-Codex, Other**. (Use the fixed set; never invent a category.
   The script already deduped, severity-mapped Codex findings — native severity + `confidence`
   preserved — and tagged `outside_diff`.)
2. Sort within each category by severity DESC, then file ASC. For **Adversarial-Codex**, sort by severity
   DESC, then `confidence` DESC, then file ASC.
3. Write the consolidated report to `<runDir>/report.md` using the skeleton in
   `comprehensive-code-review/references/report-format.md`. The **Summary verdict is deterministic**:
   NEEDS-CHANGES iff `stats.blocking > 0`; INCOMPLETE on any BLOCKED track; else SHIP —
   reviewer prose verdicts never gate. Render the **Fix-Scope Contract** section verbatim, the
   **Previously Adjudicated** section (from `previouslyAdjudicated`; omit when empty), the
   `Previously adjudicated: <n>` Summary line, and — when `passNumber ≥ 3` AND NEEDS-CHANGES —
   the **STOP-LOOPING** recommendation. Findings with `challenges_disposition` render in their
   category tagged "⚑ challenges disposition #<id>". In the Scope section, list the excluded
   build-output patterns and note this is a **focused review (5 reviewers + Codex)**, not the comprehensive
   one. The raw JSON files under `<runDir>/raw/` are the machine record — do NOT render
   per-reviewer or Codex `.md` files.
4. **Ledger write-back (Iron Law 5).** For every dropped finding with
   `verification: "refuted"` and severity critical/important, append it to the disposition
   ledger so no later pass re-litigates it:

   ```bash
   node "<comprehensive-code-review skill dir>/scripts/review-run.mjs" disposition \
     --repo-root "$REPO_ROOT" --file "<f.file>" --title "<f.title>" \
     --status refuted --reason "<f.refute_reason>" --decided-by report --run-id "$RUN_ID"
   ```

   (Upsert semantics: re-refuting the same claim updates the existing entry, no duplicates.
   Apply the Phase 1 `.gitignore` negation on first creation.)
5. Print the summary:

   ```
   ## Focused Code Review complete

   Report: <runDir>/report.md
   Reviewers: <n> DONE, <n> SKIPPED, <n> BLOCKED
   Findings: <total> verified post-dedup (<n> critical, <n> important, <n> minor; <n> duplicates merged; <n> blocking)
   Previously adjudicated: <n> suppressed via the disposition ledger   # only when > 0
   Dropped: <n> (<n> citation-unverifiable, <n> refuted, <n> excluded build output)
   Capped: <n> findings discarded by reviewer caps (<reviewer names>)   # only when any reviewer reported dropped_by_cap > 0
   Calibration: <reviewer> <n> refuted, <n> citation-dropped; …        # from stats.perReviewer; only reviewers with non-zero counts; omit line if all zero
   Recommendation: STOP-LOOPING                                        # only when passNumber >= 3 and verdict is NEEDS-CHANGES
   ⚠ Codex verify mismatch: <n> refutation(s) matched no finding — possible false-positive in report   # only when stats.unmatchedCodexRefutations > 0
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
