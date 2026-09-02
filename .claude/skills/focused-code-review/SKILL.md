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
  Usage: /focused-code-review [--base <ref>] [--context <path>] [--pass <n>]
argument-hint: "[--base <ref>] [--context <path>] [--pass <n>]"
hooks:
  PreToolUse:
    - matcher: Workflow
      hooks:
        - type: command
          command: 'node "$HOME/.claude/skills/comprehensive-code-review/scripts/validate-workflow-launch.mjs"'
---

# Focused Code Review

You are the orchestrator for the lean sibling of `comprehensive-code-review`, and this skill
**reuses that skill's engine end to end** — the preflight script, the workflow script, the
reviewer charters, the citation verifier, the report-writer charter, and the references all live
in the sibling `comprehensive-code-review/` directory (same `skills/` parent). Nothing is
duplicated; `<sibling dir>` below means that directory. A deterministic preflight gathers every
input; ONE **Workflow** owns everything concurrent (the **five** specialist reviewers with
adversarial refutation, the Codex CLI track, and the Codex-verify pass); a script verifies
citations; a report-writer subagent emits the consolidated report. Do NOT read `references/`
files up front — each is named below only where (and only on the failure path) it is needed.

The five reviewers are fixed by `references/reviewer-profiles.json`'s `focused` array:
security-reviewer, quality-reviewer, simplification-reviewer (never blocks), silent-failure-hunter,
systemic-failure-reviewer. (test-coverage-reviewer is deliberately absent — its test-symmetry
importants drove non-converging review⇄fix loops; comprehensive still runs it.) This skill has no
`--full` and no `--spec` — it reviews a diff only (working tree or `--base`); point users needing
whole-codebase or spec-conformance review at `/comprehensive-code-review`.

## Iron Laws

```
1. NO FINDING WITHOUT A VERIFIED FILE:LINE CITATION — verify-citations.mjs enforces;
   unverifiable findings are dropped before emission. No exceptions.
2. NO REPORT UNTIL THE WORKFLOW RESOLVES (workflow-result.json written, carrying reviewer
   AND Codex terminal states). No exceptions.
3. NO INVENTED CATEGORIES — the fixed set in the sibling's references/report-format.md;
   misfits go to "Other" with reviewer name preserved. No exceptions.
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
| "I'll hand-execute the citation checks"        | Run verify-citations.mjs — hand-execution is the failure mode it removes. |
| "A refuted finding still looks right to me"    | Iron Law 5. Dropped with the refuter's reason; never resurrected.    |
| "This adjudicated finding looks real"          | Only via challenges_disposition with NEW evidence.                   |
| "Codex isn't available, I'll abort"            | The preflight passes `codex: null`; the workflow marks it SKIPPED.   |
| "This needs the whole codebase / a spec"       | That's comprehensive-code-review. This skill reviews a diff only.    |
| "Workflow rejected scriptPath, I'll copy/inline the script" | Never; the hook denies it. Surface the error verbatim: fix is the `Read(~/…/skills/**)` rules (alias + realpath) in ~/.claude/settings.json + a new session. |

## Convergence contract (for loop-callers)

A review⇄fix loop that treats every NEEDS-CHANGES as "go again" ratchets. When invoked in a loop:

- Default max **2 fix passes** per subject. Re-invoke with `--pass <n>` (pass 1 = first review).
- Only NEEDS-CHANGES justifies another fix pass. NEEDS-DECISION pauses for a user ruling. Minors,
  test-hardening, simplification, and comment findings never trigger one.
- Between passes, the caller records decisions on findings it declines to fix:
  `node "<sibling dir>/scripts/review-run.mjs" disposition --repo-root <root> --file <f> --title "<t>" --status accepted-risk|wont-fix --reason "<why>" --decided-by user [--keywords "a,b"]`
  The next pass auto-suppresses matching re-raises.
- Pass ≥3 with NEEDS-CHANGES renders **STOP-LOOPING** in the report: hand remaining blockers to a
  human.
- Fixers act under the report's Fix-Scope Contract — smallest diff, deletion is a valid fix, no
  out-of-scope hardening.

## Phase 1 — Preflight (one Bash call)

Synthesize the user's change rationale — the explicit request text driving this review, in the
user's own words where possible. Then run the sibling's preflight, mapping the skill arguments
(`$ARGUMENTS`) straight through:

```bash
node "<sibling dir>/scripts/review-preflight.mjs" \
  --repo-root "<absolute repo root>" --profile focused \
  [--base <ref>] [--context <path>] [--pass <n>] \
  --request-stdin <<'REQ_EOF_x7'
<the synthesized request text>
REQ_EOF_x7
```

Pick a unique heredoc delimiter (`REQ_EOF_` plus a random suffix) and confirm no line of the
request text equals it — a fixed `EOF` delimiter lets a pasted line reading `EOF` break out of the
heredoc into shell execution.

(If the user passed `--full` or `--spec`, tell them this skill reviews a diff only — the preflight
also warns and ignores those flags for the focused profile.)

It performs ALL deterministic gathering: mode detection, EXCLUDES-filtered changed files, empty
guard, `review-run.mjs init`, diff/manifest artifacts, docs manifest, dispositions rendering,
change-context build, Codex companion + target resolution (Gate B `expectedTarget`; Codex always
mirrors this skill's scope — no `--full` divergence), the five-reviewer roster, and the assembled
Workflow args (recorded to `<runDir>/raw/inputs/launch-args.json` for the launch hook). It prints
one JSON line; branch on `status`:

- `"empty"` → print its `message`. **STATUS: DONE.** Stop (no run dir was created).
- `"error"` → surface its `message` (the script already finished the run ABORTED when one
  existed). **STATUS: DONE_WITH_CONCERNS.** Stop.
- `"ok"` → capture `workflowArgs`, `runDir`, `runId`, `scopeLabel`, `manifestMode`, `skipped`,
  `warnings`. Relay `warnings` now; keep the scope facts for Phase 5.

## Phase 2 — Launch the Workflow (single call)

<EXTREMELY-IMPORTANT>
Launch ONE Workflow with the preflight's `workflowArgs` passed **verbatim** — do not add, drop, or
rewrite any field (the PreToolUse hook deep-equals the args against the preflight's provenance
record and denies drift):

```
Workflow({
  scriptPath: "<sibling dir>/scripts/review-fanout.workflow.js",
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

If the file is missing, stale, or unparseable: read the sibling's
`references/harvest-recovery.md` (only then) and follow its journal-fallback and Codex-salvage
procedure before declaring tracks BLOCKED.

Note the `codex` key for Phase 4: `status` (DONE/BLOCKED/SKIPPED — surface `blocked_reason`
verbatim when BLOCKED), `outcome` (`structured` | `degraded` — degraded findings live in
`codex.degraded_refs`), and `verifyRan`.

## Phase 4 — Citation Verification + Ledger Write-back

Run the sibling's script (never hand-verify; if it errors, fix the invocation and re-run):

```bash
node "<sibling dir>/scripts/verify-citations.mjs" \
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
`codex.verifyRan` is false; always pass `--changed-files` (this skill has no `--full`) and
`--dispositions` (missing ledger = no-op). The script never crashes on a bad Codex file —
`codexPayloadError` / `codexVerifyError` / `dispositionsError` in the output carry those failures
into the report.

**Ledger write-back (Iron Law 5).** For every dropped finding in `verified-findings.json` with
`verification: "refuted"` and severity critical/important:

```bash
node "<sibling dir>/scripts/review-run.mjs" disposition \
  --repo-root "$REPO_ROOT" --file "<f.file>" --title "<f.title>" \
  --status refuted --reason "<f.refute_reason>" --decided-by report --run-id "$RUN_ID"
```

(Upsert semantics — no duplicates. The ledger is local, untracked working state under the ignored
`.code-review/`; never add it to git or edit the repo's `.gitignore` to re-include it.)

Never auto-write an Open Question to the ledger — only the user runs the paired
`by-design`/`intent-confirmed` commands rendered in the report.

## Phase 5 — Report (subagent)

Spawn a subagent with the charter at `<sibling dir>/agents/report-writer.md` (pass the charter
path; do not inline its body). Its prompt must supply: the charter path, the sibling skill base
directory, `runDir`/`runId`/`repoRoot`, profile `focused`, the Phase 1 scope facts (mode,
scopeLabel, manifestMode, warnings, plus "focused review (5 reviewers + Codex), not the
comprehensive one" for the Scope section), the Phase 3 `codex` state, and the exact finish
command:
`node "<sibling dir>/scripts/review-run.mjs" finish --repo-root "$REPO_ROOT" --run-dir "$RUN_DIR" --status <DONE|DONE_WITH_CONCERNS> --report report.md`
(status DONE_WITH_CONCERNS when any track is BLOCKED or the verdict is NEEDS-DECISION). With this
skill's five reviewers + Codex, only these categories populate: Security, Quality,
Simplification, Silent Failures, Systemic, Adversarial-Codex, Other.

Relay the subagent's summary block + WARNING lines to the user verbatim, plus the report path.

**Fallback:** if the subagent fails or returns no VERDICT line, read the sibling's
`references/report-format.md` yourself, write `<runDir>/report.md`, run the finish command, and
print the summary block per that reference.

## Phase 6 — STATUS line

All reviewers DONE/SKIPPED, Codex DONE/SKIPPED, verdict SHIP or NEEDS-CHANGES → `STATUS: DONE`.
Any track BLOCKED, or verdict NEEDS-DECISION →
`STATUS: DONE_WITH_CONCERNS — <reason: blocked tracks or user decision required>`.
The STATUS line must be the absolute last line of your response.
