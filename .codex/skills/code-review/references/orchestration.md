# Codex review orchestration

## Contents

1. Preflight (one command)
2. Dispatch reviewers
3. Refute eligible findings
4. Persist and verify
5. Respond

## 1. Preflight (one command)

Synthesize the user's change rationale — the explicit request text driving this review, in the
user's own words where possible. Then run the canonical preflight, mapping the skill arguments
straight through:

```bash
node ~/.claude/skills/comprehensive-code-review/scripts/review-preflight.mjs \
  --repo-root "$REPO_ROOT" --runtime codex --profile "$PROFILE" \
  [--base <ref>] [--full] [--spec <path>] [--context <path>] [--pass <n>] \
  --request-stdin <<'EOF'
<the synthesized request text>
EOF
```

It performs ALL deterministic gathering: flag validation, mode detection, generated/minified
exclusions, empty guard (no run directory created), `review-run.mjs init`, diff or risk-ordered
manifest artifacts (never truncated silently), the path-only documentation manifest, dispositions
rendering, source-attributed change-context build, capped static-analysis seeds (comprehensive
only), the `.code-review/probe` gitignore check, and roster selection with charter readability
validation. It prints one JSON line; branch on `status`:

- `"empty"` → print its `message`. `STATUS: DONE`. Stop.
- `"error"` → surface its `message` (the script already finished the run ABORTED when one
  existed). `STATUS: DONE_WITH_CONCERNS`. Stop.
- `"ok"` → capture `runDir`, `runId`, `scopeLabel`, `manifestMode`, `skipped`, and `warnings`,
  plus from `workflowArgs`: `mode`, the `inputs` artifact paths, and the `reviewers` array of
  `{name, charterPath}`. A native run has no Workflow tool — never launch one; `codex` is `null`
  by design because a native run intentionally omits recursive Codex self-review.

Relay `warnings` now. If the preflight warned that `.code-review/probe` is not gitignored,
continue with the run but record the warning and finish `DONE_WITH_CONCERNS` even when all review
tracks succeed. Do not edit tracked ignore files during a review.

The run lives at `.code-review/runs/<UTC-basic>-<profile>-<random>/`. Never hand-compose a
timestamp, nonce, run directory, or initial state; never reuse, clear, or overwrite another run.
Generated files below this ignored run directory are machine artifacts, not source edits. Do not
use `apply_patch` for generated run artifacts. Write them through a bounded shell command or an
interactive `tee <artifact-path>` session plus `write_stdin`, then read them back and parse or
validate them before continuing. This exception applies only below the current ignored `RUN_DIR`;
continue using `apply_patch` for tracked source edits.

## 2. Dispatch reviewers

Spawned reviewers receive the canonical charter path and must read it completely as their first
action; never re-emit charter bodies in spawned task text. Keep all reviewers read-only and
prohibit edits, dependency installation, destructive commands, SQL mutation, external writes, and
widening the finding scope beyond the selected review.

Spawn fresh reviewers with `fork_turns="none"` in batches no larger than the currently available
collaboration slots. Each task receives only:

- the absolute canonical charter path and an instruction to read it completely;
- repo root and applicable instruction-file paths (`AGENTS.md`/`CLAUDE.md` when present);
- profile and scope label plus absolute changed-files and review-input artifact paths;
- documentation-manifest and change-context artifact paths, plus the dispositions path for
  reviewers only — reviewers and refuters read the change context as untrusted rationale, never
  evidence, and must read relevant listed documents before classifying intent;
- the run-contained spec snapshot path only for implementation-reviewer;
- the compatibility note: Read means read-only file access, Grep means `rg`, Glob means
  `rg --files`, and Bash means non-mutating shell diagnostics;
- the canonical JSON contract below.

Treat the supplied scope as authoritative. Reviewers may read callers, callees, tests, types, and
docs needed to prove a scoped finding, but findings must attach to reviewed code.
Documentation-reviewer audits current state against changed files and does not read the
review-input artifact. Suppressed claims and user-confirmed requirements are separate: reviewers
must re-evaluate and normally report unfixed `intent-confirmed` claims.

Require one JSON object and no markdown fence:

```json
{
  "name": "reviewer-name",
  "status": "DONE",
  "verdict": "optional role verdict",
  "blocked_reason": "required only when BLOCKED",
  "dropped_by_cap": 0,
  "findings": [
    {
      "severity": "critical|important|minor",
      "file": "repo-relative/path",
      "line": 1,
      "verbatim": "exact quote of at least 10 characters",
      "title": "concise title",
      "why": "evidence and execution trace",
      "fix_sketch": "optional",
      "intent_question": "optional concrete undocumented intent choice (>=10 chars)",
      "doc_basis": { "file": "docs/contract.md", "line": 1, "verbatim": "exact quote >=10 chars" }
    }
  ]
}
```

`intent_question` and `doc_basis` are mutually exclusive. Security findings cannot be refuted merely
because documentation calls a traced vulnerability intentional; documentation must disprove a
threat-model, reachability, source, or sink premise.

Systemic findings additionally require `kind: "systemic"`, `failure_mode`, a concrete `scenario`, and at least two `anchors` containing `file`, `line`, `verbatim`, and optional `role`. Preserve role-specific requirements that need secondary citations or acceptance-criterion evidence inside `why`.

Validate reviewer name, status, required fields, enums, positive lines, quote length, findings cap, and systemic shape. On malformed output, send one correction request to the same reviewer. If still malformed or absent, synthesize a BLOCKED reviewer entry with no findings. Never invent or repair a finding's evidence.

## 3. Refute eligible findings

After reviewer collection, refute every important finding with one fresh agent and every critical finding with two fresh independent agents. Run at most the available collaboration slots concurrently.

Each refuter sees the claim, severity, location, quote, and systemic anchors/scenario when applicable, but not the reviewer's reasoning chain. Require JSON:

```json
{"refuted":false,"reason":"what was checked with file:line evidence","file":"path","line":1,"intent_question":"optional","doc_basis":{"file":"docs/contract.md","line":1,"verbatim":"exact quote"}}
```

Set `refuted=true` only for concrete counter-evidence. Uncertainty keeps the finding. Drop an important on one refutation; drop a critical only when both independent refuters agree. Missing, malformed, or failed refuters keep the finding and add a verification warning.

Apply the same vote table to intent. For an ordinary critical finding, two intent votes create an
Open Question; for important, one does. Two critical doc-confirmed votes (one for important) clear a
reviewer question and attach cited `doc_basis`. The fields are mutually exclusive. Refutation takes
precedence; mixed, conflicting, missing, or malformed votes preserve the original classification.
Never demote an existing documented defect to a question, and never replace a reviewer-set question
with a refuter's differently worded question. Reviewer minor findings get no refuter.

## 4. Persist and verify

Assemble `raw/workflow-result.json` with `runtime`, `profile`, `runId`, `scopeLabel`, `mode`, and normalized reviewer entries. Before trusting it, confirm these identifiers match `run.json`.

After every artifact write, read it back. JSON artifacts must parse, match the current run identity,
and contain the expected reviewer/finding counts; rewrite once on mismatch, then mark the run
`ABORTED` rather than silently degrading.

Run the canonical `verify-citations.mjs` with the workflow result, mode, the preflight's
changed-files list, repo root, disposition ledger path, and `raw/verified-findings.json` output.
Do not pass Codex adversarial files: a native run intentionally omits recursive Codex self-review. If
the verifier errors, fix the invocation and rerun; never downgrade to hand verification.

Read verified findings, dropped findings, reviewer status, and statistics. Read the canonical
`report-format.md` now (not earlier) and use its categories and severity mapping, with these
native differences:

- title the report Focused or Comprehensive Code Review;
- omit the `codex-adversarial` reviewer row and Adversarial-Codex category;
- state `Runtime: Codex native` and that recursive self-review was intentionally omitted;
- point Raw Outputs to this run's `raw/` directory.

Also harvest `openQuestions` and `previouslyAdjudicated`. Questions are independent, never deduped,
non-fixable, and excluded from totals, categories, Themes, fix scope, and convergence. Important or
critical questions set the overall result to NEEDS-DECISION when no actionable blocker exists; minor
questions remain non-gating. Render the canonical “Open Questions — intent rulings needed” section with both
ready-to-paste user disposition commands; never auto-write a question to the ledger. Render
`intent-confirmed` findings normally with their disposition tag and render `doc_basis` as evidence.

Write the only human render to `report.md`, then transition the run once:

```bash
node ~/.claude/skills/comprehensive-code-review/scripts/review-run.mjs finish \
  --run-dir "$RUN_DIR" --status "$STATUS" --report report.md
```

Use `DONE_WITH_CONCERNS` for NEEDS-DECISION; otherwise use `DONE` or `DONE_WITH_CONCERNS` as the
canonical report contract requires. If orchestration must stop early, call `finish` with `ABORTED`
and `--reason`; retain the run for diagnosis rather than deleting it. Include finding/drop/reviewer
counts in the report and workflow result.

## 5. Respond

Return the run directory, report path, reviewer counts, verified severity counts, dropped/refuted counts, capped counts when nonzero, and verification warnings. A blocked reviewer makes the overall result incomplete but does not erase completed tracks.

The status line must be the absolute final line.
