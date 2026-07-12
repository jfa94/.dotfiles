---
name: comprehensive-code-review
description: >
  Run a comprehensive code review using parallel specialist reviewers and a Codex adversarial
  review. Covers architecture, security, quality, tests, types, comments, simplification,
  silent failures, documentation, systemic failure modes, and optionally implementation-vs-spec.
  Every critical and important finding (including Codex's) is adversarially verified by a fresh
  refuter agent before it can ship. Consolidates all findings into a single deduplicated report
  with verified file:line citations.
  Usage: /comprehensive-code-review [--base <ref>] [--full] [--spec <path>]
argument-hint: "[--base <ref>] [--full] [--spec <path>]"
---

# Comprehensive Code Review

You are the orchestrator for a comprehensive, multi-dimensional code review. You dispatch ONE
**Workflow** that owns everything concurrent: the specialist reviewer fan-out (one findings schema,
every critical/important finding adversarially verified by a fresh refuter agent), the **Codex**
adversarial review (a codex-runner agent runs the CLI, scope mirrors the reviewers — bounded only
under `--full`), and the Codex-verify refutation pass — all inside the single workflow, so no track
can serialize behind another. You then verify every finding has a real file:line citation, dedup
across reviewers, group results by category, and emit one consolidated report.

Read `references/workflow-and-codex.md` and `references/report-format.md` (in this skill's
directory) before proceeding — they define the workflow contract, the findings schema, the Codex
target-resolution table, and the output format.

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
```

## Red Flags — STOP and re-read this prompt

| Thought                                      | Reality                                                                                     |
| -------------------------------------------- | ------------------------------------------------------------------------------------------- |
| "I'll Task each reviewer myself"             | Iron Law 4. Reviewers go through the Workflow, not direct Task calls.                       |
| "The finding looks right, I'll include it"   | Iron Law 1. Verify file:line first. Drop if no match.                                       |
| "Workflow's still running, I'll report now"  | Iron Law 2. workflow-result.json written first.                                            |
| "I'll create a new category for this"        | Iron Law 3. Use fixed set; map to "Other" if nothing fits.                                  |
| "Codex isn't available, I'll abort"          | Pass `codex: null`. The workflow marks Codex SKIPPED; reviewers still run.                  |
| "I'll run Codex myself with a Bash call"     | Iron Law 4. The workflow's codex-runner agent owns the CLI run.                             |
| "I'll harvest the Workflow's return value"   | No. Read `<runDir>/raw/workflow-result.json` instead.                                      |
| "--full, so I'll build a root..HEAD diff"    | No. --full sends agents the file inventory; they Read files.                                |
| "I'll summarise a finding without the quote" | No quote = no finding. Period.                                                              |
| "A refuted finding still looks right to me"  | Refuted = Dropped Findings with the refuter's reason. Never resurrect it.                   |
| "Same issue from 3 reviewers = 3 findings"   | The script dedups (Phase 7). Merged, highest severity, annotated "Also flagged by".         |
| "Codex findings ship as-is"                  | Critical/high/medium Codex findings are refuted inside the workflow's Codex-verify stage.   |
| "I'll hand-execute the citation checks"      | Run scripts/verify-citations.mjs (Phase 7) — hand-execution is the failure mode it removes. |

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

First gather `changedFiles` per mode and apply the empty guard without writing artifacts. Then,
before materializing `reviewInput`, a manifest, a seed, or any workflow output, create the run:

```bash
PROFILE=comprehensive
RUN_STATE=$(node "<this skill's base directory>/scripts/review-run.mjs" init \
  --repo-root "$REPO_ROOT" --runtime claude --profile "$PROFILE" \
  --mode "$MODE" --scope-label "$SCOPE_LABEL")
RUN_DIR_ABS=$(printf '%s' "$RUN_STATE" | jq -r .runDir)
RUN_DIR=${RUN_DIR_ABS#"$REPO_ROOT"/}
RUN_ID=$(printf '%s' "$RUN_STATE" | jq -r .runId)
```

The helper atomically creates `run.json` and `raw/`; never hand-compose or reuse a run path. At the
end, call the helper's `finish` command with `DONE` or `DONE_WITH_CONCERNS` and `--report report.md`.
On an early stop, finish it as `ABORTED` with `--reason`; never silently delete diagnostic artifacts.
All later `<runDir>` references mean the returned `RUN_DIR`.

**Build-output exclusion.** Generated/minified output (committed or untracked) is skipped so
reviewers see only hand-written code. Define `EXCLUDES` once and append `-- . "${EXCLUDES[@]}"`
to _every_ file/diff gathering command below (full / base / working-tree, inline and manifest).
The positive `.` is required so the exclude-only pathspecs resolve against the whole repo;
`top`+`glob` anchoring catches nested monorepo paths (`packages/x/dist/…`), not just repo-root.
This same list is reused by the manifest commands in `references/workflow-and-codex.md` §5 and
as the Phase 7 drop predicate. Edit this list to change what review skips:

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

## Phase 1b — Static-Analysis Seeds (installed tools only)

Deterministic tools produce cheap, precise signal the LLM pass should triage rather than
rediscover. Run every tool that is ALREADY installed — never install, never author config:

- `package.json` scripts named `lint` / `typecheck` → run via the repo's package manager
- `node_modules/.bin/eslint` (with an existing eslint config) → run on the changed files
- `node_modules/.bin/tsc` → `tsc --noEmit`
- `semgrep` on PATH AND an existing project config (`.semgrep.yml` / `.semgrep/`) → run it

Rules: ~120s timeout per tool (on expiry: kill, skip, note); a failing/erroring tool is skipped
with a one-line note, never blocks the review; cap each tool's output at ~200 lines; scope to
changed files where the tool supports file args (under `--full`, run repo-wide).

Route seeds to disk — do NOT inline raw output (it would be copied into every reviewer prompt). For
each tool that produced output: `mkdir -p <outDir>/raw/seeds` and write the capped output to
`<runDir>/raw/seeds/<tool>.txt` (mirrors `raw/full-diff.patch`).
Then append to `reviewInput` ONLY a compact manifest — never the raw output:

```
## Static-analysis seeds (candidate leads — Read the file for your lens, then trace + quote yourself)
A seed becomes a finding ONLY when you trace it and quote the code yourself (file:line + verbatim);
report seeds you cannot substantiate as nothing at all. Read only the tools relevant to your role.
- <tool>: <N> lines → <outDir>/raw/seeds/<tool>.txt
```

If no tool produced output, append nothing. List which seed tools ran (or "none installed") in the
report's Scope section.

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

Then build the staleness contract the workflow's codex-runner agent will enforce (Gate B):

```bash
# base / --full modes — resolve the trusted ref to a SHA NOW, before launch:
EXPECTED_TARGET='{ "mode": "branch", "baseSha": "'$(git rev-parse "${BASE_REF:-$CODEX_BASE}^{commit}")'" }'
# working-tree mode:
EXPECTED_TARGET='{ "mode": "working-tree" }'
```

Assemble the workflow's `codex` arg (or `null` when `CODEX_AVAILABLE=false`):

```
codex = { cmd: <CODEX_CMD>, targetFlags: <CODEX_TARGET>, expectedTarget: <EXPECTED_TARGET as JSON> }
```

## Phase 4 — Implementation-Reviewer Eligibility

If `SPEC_PATH` is null → exclude implementation-reviewer from `reviewers`; mark it SKIPPED ("no --spec provided").
If `SPEC_PATH` is set but the file does not exist → exclude it; mark SKIPPED ("spec file not found: <path>").
Otherwise → include `{ name: "implementation-reviewer", role: <file body> }` in `reviewers`, and set `spec = { path, content }`.

## Phase 5 — Launch the Workflow (single call)

The unique run directory already exists. Never reuse or clear another run directory.

<EXTREMELY-IMPORTANT>
Launch ONE Workflow — it owns the reviewer fan-out, the Codex adversarial review (a codex-runner
agent runs the CLI inside the workflow), AND the Codex-verify refutation pass, all concurrently:

```
Workflow({
  scriptPath: "<this skill's base directory>/scripts/review-fanout.workflow.js",
  args: { runtime: "claude", profile: "comprehensive", runId, scopeLabel, mode,
          reviewInput, changedFiles, repoRoot, claudeMdPath, spec, reviewers, outDir: runDir,
          codex: <the Phase 3 codex object, or null when CODEX_AVAILABLE=false> }
})
```

The `args` values are the records gathered in Phases 1–4. Pass them as real JSON. `repoRoot` MUST be
the absolute repo root. `outDir` is required and must be `.code-review/runs/<runId>`.

Do NOT launch Codex yourself (no Bash call, backgrounded or otherwise) and do NOT hand-dispatch
reviewer Task calls — the workflow owns both tracks precisely so they can never serialize.
</EXTREMELY-IMPORTANT>

## Phase 6 — Harvest

When the Workflow completion notification arrives, **Read the file the workflow wrote** —
`<runDir>/raw/workflow-result.json` — and parse
`{ runtime, profile, runId, scopeLabel, mode, reviewers: [...], codex: {...} }`. Do NOT rely on the Workflow's JS return value or
`TaskOutput`; neither surfaces the structured object to you. Each reviewer entry has `status`, optional
`verdict`, and `findings[]`. **Staleness guard:** verify `runtime`, `profile`, `runId`, `scopeLabel`, and `mode` match the run you
just launched — if they are absent or differ, the file is a stale leftover (the current run's persist
failed), so do NOT trust it.

**Journal fallback (before declaring reviewers BLOCKED):** if the file is missing, stale, or
unparseable, reconstruct from the run's journal before giving up. The Workflow tool result named the
run's `runId` and transcript directory; `<transcript dir>/journal.jsonl` records every agent's
structured return as `{"type":"result", ..., "result": <object>}` lines. Reviewer results echo
`name`, refuter verdicts echo `file`/`line` — rebuild
`{ runtime: "claude", profile: "comprehensive", runId, scopeLabel, mode, reviewers: [...] }` by
taking each reviewer's result record and applying refuter verdicts as `refuted`/`refute_reason`
(criticals are dropped-as-refuted only when BOTH of their two verdicts refute; importants on one).
This pairing is **best-effort, not deterministic** — the journal has no record of an agent's `label`,
only the schema-optional `file`/`line` echo, so if a verdict omits it or matches more than one
finding (two reviewers flagging the same site), leave that finding unrefuted rather than guess; a
mis-paired refutation can then at worst let a refuted finding survive, never drop a real one. The
codex-runner's structured return is in the journal too — rebuild the `codex` key from it (its record
carries `status`/`outcome`/`degraded_refs`; set `verifyRan` true only if `verify:codex:*` verdicts
appear). Write the reconstruction to `workflow-result.json` and continue. Only if the journal is also
missing/unusable: mark every dispatched reviewer BLOCKED("workflow-result.json missing/stale and
journal unavailable") and `codex` BLOCKED("workflow died before the codex track resolved") — but
first, if `codex-adversarial.json` exists, salvage what the CLI wrote: apply Gates A/B and the
structured/degraded routing yourself per `references/workflow-and-codex.md` §6 (in that salvage
path treat `payload.target.baseRef` as untrusted — regex-validate before any git command).

Then read the Codex track's terminal state from the same file's `codex` key — the workflow ran the
CLI, the validity/staleness gates (A/B), the structured/degraded routing, AND the Codex-verify
refutation pass in-script, so there is nothing to launch or poll here:

- `codex.status`: `DONE` / `BLOCKED` / `SKIPPED` (SKIPPED when you passed `codex: null`). Surface
  `codex.blocked_reason` verbatim when BLOCKED.
- `codex.outcome === "structured"` → the structured review lives in
  `<runDir>/raw/codex-adversarial.json` (`payload.result`: `verdict`, `summary`,
  `findings[]`, `next_steps[]`); Phase 7's script reads it directly.
- `codex.outcome === "degraded"` → structured output was unavailable; `codex.degraded_refs` holds the
  existence-checked `file:line` refs recovered from the narrative output. Add the **mandatory degraded
  note** in both the Reviewers table Verdict cell (suffix `(degraded — narrative fallback)`) and the
  Codex section ("structured output unavailable — findings recovered from narrative fallback; degraded,
  not schema-validated").
- `codex.verifyRan === true` → the workflow refuted the critical/high/medium Codex findings and
  persisted `<runDir>/raw/codex-verify-result.json`. Read it, apply the same five-field
  staleness guard as above; findings annotated `refuted: true` go to Dropped
  Findings (`refuted`, with `refute_reason`) — never resurrect them. If the file is missing/stale
  despite `verifyRan: true` → keep ALL Codex findings unrefuted AND add a mandatory report note
  ("Codex findings not adversarially verified — verify pass failed"). Never drop a finding because
  verification broke. Degraded-fallback findings are never refuted (no schema-validated claims to
  verify) — the degraded note already marks them as lower-trust.

## Phase 7 — Citation Verification (scripted, deterministic)

Do NOT hand-execute citation checks — run the script (its spec lives in
`references/workflow-and-codex.md` §6). Write the changed-files list to a file first:

```bash
printf '%s\n' "$CHANGED_FILES" > "$RUN_DIR/raw/changed-files.txt"
node "<this skill's base directory>/scripts/verify-citations.mjs" \
  --workflow-result "$RUN_DIR/raw/workflow-result.json" \
  --codex "$RUN_DIR/raw/codex-adversarial.json" \
  --codex-verify "$RUN_DIR/raw/codex-verify-result.json" \
  --mode "$MODE" \
  --changed-files "$RUN_DIR/raw/changed-files.txt" \
  --repo-root "$REPO_ROOT" \
  --out "$RUN_DIR/raw/verified-findings.json"
```

Omit `--codex` when Codex is SKIPPED/BLOCKED or took the degraded fallback (the script processes
only structured payloads; on the degraded path use `codex.degraded_refs` from Phase 6). Omit
`--codex-verify` when `codex.verifyRan` is false. Omit `--changed-files` under
`--full` (no outside-diff tagging). If the script errors, fix the invocation and re-run — never
fall back to hand-verification.

The script never crashes on a bad Codex file — a missing/empty/invalid `--codex` or
`--codex-verify` payload is surfaced in the output instead. After running it, check
`verified-findings.json`: `codexPayloadError` set → report the Codex track BLOCKED with that reason;
`codexVerifyError` set → keep the Codex findings and add the mandatory note "Codex findings not
adversarially verified — verify pass failed".

The script implements the full §6 procedure: EXCLUDES drop (incl. the Codex backstop), refuted
drop, the systemic gate (failure_mode + scenario + ≥2 verified anchors), the line±2 /
grep-rescue citation check (`ok` / `relocated_ok`), outside-diff tagging, Codex existence checks
(`codex_file_missing` / `codex_line_out_of_range`) + native→standard severity mapping, and
cross-reviewer dedup (same file AND same `kind` AND (lines ±3 OR identical collapsed verbatim);
highest severity wins, others under `also_flagged_by`).

Read `verified-findings.json`: `findings` (verified, post-dedup), `dropped` (with per-finding
`verification` reasons), `reviewers` (status pass-through for the report table), and
`stats` (`perReviewer` refuted/citation-dropped counts + `duplicatesMerged` — feeds Phase 8's
Calibration line — + `unmatchedCodexRefutations`, which feeds a Phase 8 WARNING line).

## Phase 8 — Group, Sort, Emit

1. Categorize each verified finding per `references/report-format.md`. (The script already
   deduped, severity-mapped Codex findings — native severity + `confidence` are preserved on each
   finding so the 4→3 collapse loses no signal — and tagged `outside_diff`.)
2. Sort within each category by severity DESC, then file ASC. For **Adversarial-Codex**, sort by
   severity DESC, then `confidence` DESC, then file ASC (confidence orders, never filters).
3. Write the consolidated report to `<runDir>/report.md` using the
   skeleton in `references/report-format.md`. In the Scope section, list the excluded
   build-output patterns (Phase 1 `EXCLUDES`), note which static-seed tools ran (Phase 1b), and
   note the agent vs. Codex scope when mode = full. The raw JSON files under
   `<runDir>/raw/` are the machine record — do NOT render per-reviewer or Codex
   `.md` files.
4. Print the summary:

   ```
   ## Comprehensive Code Review complete

   Report: <runDir>/report.md
   Reviewers: <n> DONE, <n> SKIPPED, <n> BLOCKED
   Findings: <total> verified post-dedup (<n> critical, <n> important, <n> minor; <n> duplicates merged)
   Dropped: <n> (<n> citation-unverifiable, <n> refuted, <n> excluded build output)
   Capped: <n> findings discarded by reviewer caps (<reviewer names>)   # only when any reviewer reported dropped_by_cap > 0
   Calibration: <reviewer> <n> refuted, <n> citation-dropped; …        # from stats.perReviewer; only reviewers with non-zero counts; omit line if all zero
   ```

   Append WARNING lines when applicable (one line each, only when the condition applies):

   - When `mode === "full"` AND Codex ran: `⚠ Codex reviewed only HEAD~30…HEAD; whole-codebase design review relied on the systemic reviewer [present | ABSENT — systemic failure modes NOT covered].`
   - When `stats.unmatchedCodexRefutations > 0`: `⚠ <n> Codex refutation(s) matched no finding (stats.unmatchedCodexRefutations) — a finding the verify pass flagged for drop may have shipped as verified; reconcile codex-adversarial.json against the verify output.`
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
