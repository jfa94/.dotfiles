# Codex review orchestration

## Contents

1. Establish scope once
2. Create an isolated run
3. Dispatch reviewers
4. Refute eligible findings
5. Persist and verify
6. Respond

## 1. Establish scope once

Read the target repository's `/docs` directory first when present, then applicable `AGENTS.md` and `CLAUDE.md` files. Keep all reviewers read-only and prohibit edits, dependency installation, destructive commands, SQL mutation, external writes, and widening the finding scope beyond the selected review.

Use the same generated/minified exclusions as the Claude skills: `.code-review`, `dist`, `build`,
`out`, `.next`, `.nuxt`, `.svelte-kit`, `.output`, `coverage`, `*.min.js`, `*.min.css`, `*.map`, and
package-manager lockfiles. Before creating a run, check whether `.code-review/probe` is ignored. Do
not edit tracked ignore files during a review. If it is not ignored, continue with the explicit
`.code-review/**` scope exclusion, record a warning, and finish `DONE_WITH_CONCERNS` even when all
review tracks succeed.

- Working tree: combine `git diff HEAD` (staged and unstaged) with untracked, non-ignored files.
- Base: validate the ref with Git, then use `<ref>...HEAD`.
- Full: use tracked source inventory at current state; prioritize 12-month churn hotspots and disclose sampling.
- Empty scope: stop cleanly without launching agents.
- Diff at most 2,000 lines: inline it in reviewer prompts.
- Larger diff: store the complete patch under the run's `raw/full-diff.patch`; provide a risk-ordered manifest and require reviewers to read the patch/files. Never truncate silently.

Collect installed static-analysis seeds only; never install tooling or author configuration. Store capped output under `raw/seeds/` and give reviewers paths, not duplicated raw output.

## 2. Create an isolated run

Before writing any diff, seed, or result, call the canonical initializer:

```bash
node ~/.claude/skills/comprehensive-code-review/scripts/review-run.mjs init \
  --repo-root "$REPO_ROOT" --runtime codex --profile "$PROFILE" \
  --mode "$MODE" --scope-label "$SCOPE_LABEL"
```

Parse its single-line JSON output and use the returned absolute `runDir` and `runId`. It atomically
creates the collision-safe directory and initial `run.json`:

```text
.code-review/runs/<UTC-basic>-<profile>-<random>/
├── run.json
└── raw/
```

Never hand-compose a timestamp, nonce, run directory, or initial state. Never reuse, clear, or
overwrite another run. Generated files below this ignored run directory are machine artifacts, not
source edits. Do not use `apply_patch` for generated run artifacts. Write them through a bounded
shell command or an interactive `tee <artifact-path>` session plus `write_stdin`, then read them back
and parse/validate them before continuing. This exception applies only below the current ignored
`RUN_DIR`; continue using `apply_patch` for tracked source edits.

## 3. Dispatch reviewers

The main agent must read each selected charter itself, then embed the charter body in the spawned task. A path alone is insufficient.

Spawn fresh reviewers with `fork_turns="none"` in batches no larger than the currently available collaboration slots. Each task receives only:

- the full charter body;
- repo root and applicable instruction-file paths;
- profile, scope label, changed-files list, and review input/manifest;
- spec path and content only for implementation-reviewer;
- the compatibility note: Read means read-only file access, Grep means `rg`, Glob means `rg --files`, and Bash means non-mutating shell diagnostics;
- the canonical JSON contract below.

Treat the supplied scope as authoritative. Reviewers may read callers, callees, tests, types, and docs needed to prove a scoped finding, but findings must attach to reviewed code. Documentation-reviewer audits current state against changed files and does not need the inline diff.

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
      "fix_sketch": "optional"
    }
  ]
}
```

Systemic findings additionally require `kind: "systemic"`, `failure_mode`, a concrete `scenario`, and at least two `anchors` containing `file`, `line`, `verbatim`, and optional `role`. Preserve role-specific requirements that need secondary citations or acceptance-criterion evidence inside `why`.

Validate reviewer name, status, required fields, enums, positive lines, quote length, findings cap, and systemic shape. On malformed output, send one correction request to the same reviewer. If still malformed or absent, synthesize a BLOCKED reviewer entry with no findings. Never invent or repair a finding's evidence.

## 4. Refute eligible findings

After reviewer collection, refute every important finding with one fresh agent and every critical finding with two fresh independent agents. Run at most the available collaboration slots concurrently.

Each refuter sees the claim, severity, location, quote, and systemic anchors/scenario when applicable, but not the reviewer's reasoning chain. Require JSON:

```json
{"refuted":false,"reason":"what was checked with file:line evidence","file":"path","line":1}
```

Set `refuted=true` only for concrete counter-evidence. Uncertainty keeps the finding. Drop an important on one refutation; drop a critical only when both independent refuters agree. Missing, malformed, or failed refuters keep the finding and add a verification warning.

## 5. Persist and verify

Assemble `raw/workflow-result.json` with `runtime`, `profile`, `runId`, `scopeLabel`, `mode`, and normalized reviewer entries. Before trusting it, confirm these identifiers match `run.json`.

After every artifact write, read it back. JSON artifacts must parse, match the current run identity,
and contain the expected reviewer/finding counts; rewrite once on mismatch, then mark the run
`ABORTED` rather than silently degrading.

Write `raw/changed-files.txt`, then run the canonical `verify-citations.mjs` with the workflow result, mode, changed-files list, repo root, and `raw/verified-findings.json` output. Do not pass Codex adversarial files: a native run intentionally omits recursive Codex self-review. If the verifier errors, fix the invocation and rerun; never downgrade to hand verification.

Read verified findings, dropped findings, reviewer status, and statistics. Use the canonical report-format categories and severity mapping, with these native differences:

- title the report Focused or Comprehensive Code Review;
- omit the `codex-adversarial` reviewer row and Adversarial-Codex category;
- state `Runtime: Codex native` and that recursive self-review was intentionally omitted;
- point Raw Outputs to this run's `raw/` directory.

Write the only human render to `report.md`, then transition the run once:

```bash
node ~/.claude/skills/comprehensive-code-review/scripts/review-run.mjs finish \
  --run-dir "$RUN_DIR" --status "$STATUS" --report report.md
```

Use `DONE` or `DONE_WITH_CONCERNS`. If orchestration must stop early, call `finish` with `ABORTED`
and `--reason`; retain the run for diagnosis rather than deleting it. Include finding/drop/reviewer
counts in the report and workflow result.

## 6. Respond

Return the run directory, report path, reviewer counts, verified severity counts, dropped/refuted counts, capped counts when nonzero, and verification warnings. A blocked reviewer makes the overall result incomplete but does not erase completed tracks.

The status line must be the absolute final line.
