---
name: comprehensive-code-review
description: >
  Run a comprehensive code review using parallel specialist reviewers and a Codex adversarial
  review. Covers architecture, security, quality, tests, types, comments, simplification,
  silent failures, documentation, systemic failure modes, and optionally implementation-vs-spec.
  Every critical and important finding (including Codex's) is adversarially verified by a fresh
  refuter agent before it can ship. Consolidates all findings into a single deduplicated report
  with verified file:line citations.
  Usage: /comprehensive-code-review [--base <ref>] [--full] [--spec <path>] [--context <path>] [--pass <n>]
argument-hint: "[--base <ref>] [--full] [--spec <path>] [--context <path>] [--pass <n>]"
hooks:
  PreToolUse:
    - matcher: Workflow
      hooks:
        - type: command
          command: 'node "$HOME/.claude/skills/comprehensive-code-review/scripts/validate-workflow-launch.mjs"'
---

# Comprehensive Code Review

You are the orchestrator. A deterministic preflight script gathers every input; ONE **Workflow**
owns everything concurrent (specialist reviewer fan-out with adversarial refutation, the Codex
CLI track, and the Codex-verify pass); a script verifies citations; a report-writer subagent
emits the consolidated report. You supply judgment only where it is needed: the request text, the
harvest, and relaying results. Do NOT read `references/` files up front — each is named below at
the exact point (and only the failure paths) where it is needed.

## Iron Laws

```
1. NO FINDING WITHOUT A VERIFIED FILE:LINE CITATION — verify-citations.mjs enforces;
   unverifiable findings are dropped before emission. No exceptions.
2. NO REPORT UNTIL THE WORKFLOW RESOLVES (workflow-result.json written, carrying reviewer
   AND Codex terminal states). No exceptions.
3. NO INVENTED CATEGORIES — the fixed set in references/report-format.md; misfits go to
   "Other" with reviewer name preserved. No exceptions.
4. EVERYTHING DISPATCHES VIA THE WORKFLOW — no hand-dispatched reviewer Task calls, no
   Bash Codex runs, no direct background calls. No exceptions.
5. REFUTED = DEAD EVERYWHERE — a refuted or previously-adjudicated finding never re-enters
   the report body, Themes, or fix guidance (including residuals or "weakened versions").
   A different concern at the same site is a NEW finding that must survive its own
   refutation. Refuted critical/important findings are appended to the disposition ledger
   at report time. No exceptions.
```

## Red Flags — STOP and re-read this prompt

| Thought                                        | Reality                                                              |
| ---------------------------------------------- | -------------------------------------------------------------------- |
| "I'll gather the diff/inputs myself with Bash" | Phase 1's preflight script owns ALL gathering. One call.             |
| "I'll Task each reviewer / run Codex myself"   | Iron Law 4. The Workflow owns both tracks.                           |
| "I'll tweak workflowArgs before launching"     | Pass them verbatim — the hook deep-equals them against the preflight's record. |
| "Workflow's still running, I'll report now"    | Iron Law 2. workflow-result.json first.                              |
| "I'll harvest the Workflow's return value"     | No. Read `<runDir>/raw/workflow-result.json`.                        |
| "I'll hand-execute the citation checks"        | Run scripts/verify-citations.mjs — hand-execution is the failure mode it removes. |
| "A refuted finding still looks right to me"    | Iron Law 5. Dropped with the refuter's reason; never resurrected.    |
| "This adjudicated finding looks real"          | Only via challenges_disposition with NEW evidence.                   |
| "Codex isn't available, I'll abort"            | The preflight passes `codex: null`; the workflow marks it SKIPPED.   |
| "Workflow rejected scriptPath, I'll copy/inline the script" | Never; the hook denies it. Surface the error verbatim: fix is the `Read(//…/skills/**)` rules (alias + realpath) in ~/.claude/settings.json + a new session. |

## Convergence contract (for loop-callers)

A review⇄fix loop that treats every NEEDS-CHANGES as "go again" ratchets. When invoked in a loop:

- Default max **2 fix passes** per subject. Re-invoke with `--pass <n>` (pass 1 = first review).
- Only NEEDS-CHANGES justifies another fix pass. NEEDS-DECISION pauses for a user ruling. Minors,
  test-hardening, simplification, and comment findings never trigger one.
- Between passes, the caller records decisions on findings it declines to fix:
  `node "<this skill's base directory>/scripts/review-run.mjs" disposition --repo-root <root> --file <f> --title "<t>" --status accepted-risk|wont-fix --reason "<why>" --decided-by user [--keywords "a,b"]`
  The next pass auto-suppresses matching re-raises.
- Pass ≥3 with NEEDS-CHANGES renders **STOP-LOOPING** in the report: hand remaining blockers to a
  human.
- Fixers act under the report's Fix-Scope Contract — smallest diff, deletion is a valid fix, no
  out-of-scope hardening.

## Phase 1 — Preflight (one Bash call)

Synthesize the user's change rationale — the explicit request text driving this review, in the
user's own words where possible (it becomes the reviewers' `request` context and the report's
Scope). Then run the preflight, mapping the skill arguments (`$ARGUMENTS`) straight through:

```bash
node "<this skill's base directory>/scripts/review-preflight.mjs" \
  --repo-root "<absolute repo root>" --profile comprehensive \
  [--base <ref>] [--full] [--spec <path>] [--context <path>] [--pass <n>] \
  --request-stdin <<'REQ_EOF_x7'
<the synthesized request text>
REQ_EOF_x7
```

Pick a unique heredoc delimiter (`REQ_EOF_` plus a random suffix) and confirm no line of the
request text equals it — a fixed `EOF` delimiter lets a pasted line reading `EOF` break out of the
heredoc into shell execution.

It performs ALL deterministic gathering: mode detection, EXCLUDES-filtered changed files, empty
guard, `review-run.mjs init`, diff/manifest artifacts, docs manifest, dispositions rendering,
change-context build, parallel static-analysis seeds, Codex companion + target resolution
(Gate B `expectedTarget`), roster + spec eligibility, and the assembled Workflow args (recorded
to `<runDir>/raw/inputs/launch-args.json` for the launch hook). It prints one JSON line; branch
on `status`:

- `"empty"` → print its `message`. **STATUS: DONE.** Stop (no run dir was created).
- `"error"` → surface its `message` (the script already finished the run ABORTED when one
  existed). **STATUS: DONE_WITH_CONCERNS.** Stop.
- `"ok"` → capture `workflowArgs`, `runDir`, `runId`, `scopeLabel`, `manifestMode`, `seeds`,
  `skipped`, `warnings`. Relay `warnings` to the user now; keep the scope facts for Phase 5.

## Phase 2 — Launch the Workflow (single call)

<EXTREMELY-IMPORTANT>
Launch ONE Workflow with the preflight's `workflowArgs` passed **verbatim** — do not add, drop,
reorder-into-new-values, or rewrite any field (the PreToolUse hook deep-equals the args against
the preflight's provenance record and denies drift):

```
Workflow({
  scriptPath: "<this skill's base directory>/scripts/review-fanout.workflow.js",
  args: <workflowArgs verbatim>
})
```

It owns the reviewer fan-out, the Codex adversarial review, AND the Codex-verify refutation pass,
all concurrently. Do NOT launch Codex yourself and do NOT hand-dispatch reviewer Task calls.
</EXTREMELY-IMPORTANT>

## Phase 3 — Harvest

When the Workflow completion notification arrives, Read `<runDir>/raw/workflow-result.json` and
parse `{ runtime, profile, runId, scopeLabel, mode, reviewers: [...], codex: {...} }`. Do NOT use
the Workflow's JS return value or `TaskOutput`. **Staleness guard:** all five of `runtime`,
`profile`, `runId`, `scopeLabel`, `mode` must match the run you launched — absent or different
means a stale leftover (this run's persist failed).

If the file is missing, stale, or unparseable: read `references/harvest-recovery.md` (only then)
and follow its journal-fallback and Codex-salvage procedure before declaring tracks BLOCKED.

Note the `codex` key for Phase 4: `status` (DONE/BLOCKED/SKIPPED — surface `blocked_reason`
verbatim when BLOCKED), `outcome` (`structured` | `degraded` — degraded findings live in
`codex.degraded_refs`), and `verifyRan`.

## Phase 4 — Citation Verification + Ledger Write-back

Run the script (never hand-verify; if it errors, fix the invocation and re-run):

```bash
node "<this skill's base directory>/scripts/verify-citations.mjs" \
  --workflow-result "$RUN_DIR/raw/workflow-result.json" \
  --codex "$RUN_DIR/raw/codex-adversarial.json" \
  --codex-verify "$RUN_DIR/raw/codex-verify-result.json" \
  --mode "$MODE" \
  --changed-files "$RUN_DIR/raw/changed-files.txt" \
  --dispositions "$REPO_ROOT/.code-review/dispositions.json" \
  --repo-root "$REPO_ROOT" \
  --out "$RUN_DIR/raw/verified-findings.json"
```

Omit `--codex` when Codex is SKIPPED/BLOCKED or degraded; omit `--codex-verify` when
`codex.verifyRan` is false; omit `--changed-files` under `--full`; always pass `--dispositions`
(missing ledger = no-op). The script never crashes on a bad Codex file — `codexPayloadError` /
`codexVerifyError` / `dispositionsError` in the output carry those failures into the report.

**Ledger write-back (Iron Law 5).** For every dropped finding in `verified-findings.json` with
`verification: "refuted"` and severity critical/important:

```bash
node "<this skill's base directory>/scripts/review-run.mjs" disposition \
  --repo-root "$REPO_ROOT" --file "<f.file>" --title "<f.title>" \
  --status refuted --reason "<f.refute_reason>" --decided-by report --run-id "$RUN_ID"
```

(Upsert semantics — no duplicates. The ledger is local, untracked working state under the ignored
`.code-review/`; never add it to git or edit the repo's `.gitignore` to re-include it.)

Never auto-write an Open Question to the ledger — only the user runs the paired
`by-design`/`intent-confirmed` commands rendered in the report.

## Phase 5 — Report (subagent)

Spawn a subagent with the charter at `<this skill's base directory>/agents/report-writer.md`
(pass the charter path; do not inline its body). Its prompt must supply: the charter path, the
skill base directory, `runDir`/`runId`/`repoRoot`, profile `comprehensive`, the Phase 1 scope
facts (mode, scopeLabel, manifestMode, seeds ran/skipped, warnings), the Phase 3 `codex` state,
and the exact finish command:
`node "<base>/scripts/review-run.mjs" finish --repo-root "$REPO_ROOT" --run-dir "$RUN_DIR" --status <DONE|DONE_WITH_CONCERNS> --report report.md`
(status DONE_WITH_CONCERNS when any track is BLOCKED or the verdict is NEEDS-DECISION).

Relay the subagent's summary block + WARNING lines to the user verbatim, plus the report path.

**Fallback:** if the subagent fails or returns no VERDICT line, read
`references/report-format.md` yourself, write `<runDir>/report.md`, run the finish command, and
print the summary block per that reference.

## Phase 6 — STATUS line

All reviewers DONE/SKIPPED, Codex DONE/SKIPPED, verdict SHIP or NEEDS-CHANGES → `STATUS: DONE`.
Any track BLOCKED, or verdict NEEDS-DECISION →
`STATUS: DONE_WITH_CONCERNS — <reason: blocked tracks or user decision required>`.
The STATUS line must be the absolute last line of your response.
