# Workflow & Codex Reference

This skill dispatches the 11 specialist reviewers through a `Workflow` and runs Codex as a
separate background Bash job. Citation verification runs via `scripts/verify-citations.mjs`;
report assembly stays in the main session. This file is the contract for all of them.

## 1. Reviewer fan-out via Workflow

Invoke the shipped script by path (do NOT inline a script string):

```js
Workflow({
  scriptPath: "<this skill's base directory>/scripts/review-fanout.workflow.js",
  args: {
    scopeLabel:
      "<human-readable scope, e.g. 'ENTIRE CODEBASE (current state)' or 'abc123...HEAD'>",
    mode: "full" | "base" | "working-tree",
    reviewInput:
      "<full mode: the whole-codebase instruction; diff modes: the diff text>",
    changedFiles: "<newline-joined file list>",
    repoRoot: "<absolute repo root>",
    claudeMdPath: "<path to CLAUDE.md or 'not found'>",
    spec: null | { path: "<spec path>", content: "<spec file content>" },
    reviewers: [
      {
        name: "architecture-reviewer",
        role: "<full body of agents/architecture-reviewer.md>",
      },
      {
        name: "quality-reviewer",
        role: "<full body of agents/quality-reviewer.md>",
      },
      // ... one entry per reviewer ...
      {
        name: "systemic-failure-reviewer",
        role: "<full body of agents/systemic-failure-reviewer.md>",
      },
      // include implementation-reviewer ONLY if --spec is valid (Phase 4)
    ],
  },
});
```

The workflow's final stage writes `{ reviewers: [ { name, status, verdict?, blocked_reason?, dropped_by_cap?, findings: [...] }, ... ] }`
to `<repoRoot>/.comprehensive-code-review/raw/workflow-result.json`. **Read that file to harvest the
result — the workflow's JS `return` value is NOT retrievable by the caller** (`TaskOutput` is
deprecated; the completion notification carries only prose). Each `findings[]` entry matches the
canonical schema below. Every reviewer named in `args.reviewers` appears in the result (BLOCKED with a
reason if its agent failed or was skipped).

The persist stage is transcription-checked: the script computes the payload's UTF-8 byte count and
the persist agent must confirm `wc -c` on the written file matches before returning `written=true`
(a mismatch means the agent altered content while copying — the canonical way findings get silently
corrupted and then dropped at citation verification). A failed persist (no output, `written` false,
or byte mismatch) is retried once with a fresh agent before the workflow gives up — persistence is
the run's single point of failure. If both attempts fail, the skill's journal fallback (Phase 6)
reconstructs the result from the run's `journal.jsonl`; reviewer results echo `name` and refuter
verdicts echo `file`/`line` precisely to make that reconstruction deterministic.

Three behaviors live inside the workflow, not the skill:

- **Adversarial Verify stage**: each critical/important finding is handed to a fresh refuter agent
  that sees only the claim + location (title, severity, file:line, verbatim quote — NOT the
  reviewer's `why` reasoning chain) and must hunt for concrete counter-evidence. **Criticals get 2
  independent refuters and are refuted only unanimously** (a single same-model verifier is the
  weakest link for the highest-stakes drops); importants get 1. Refuted findings
  stay in the payload annotated `refuted: true` + `refute_reason` — the skill moves them to Dropped
  Findings (never silently deleted, never resurrected). A verifier that dies/skips keeps the finding.
- **Diffless reviewers**: `documentation-reviewer` audits current state, not the change; the workflow
  withholds the diff from it (it gets the changed-files list only) to avoid context dilution.
- **Spec scoping**: `args.spec` (when provided) is included ONLY in implementation-reviewer's prompt —
  broadcasting it to every reviewer would cost spec × N tokens and duplicate the acceptance-criteria pass.

### Verify-only mode (Codex refutation)

Passing `verifyOnly` (a non-empty array of Codex structured findings — the `payload.result.findings`
entries, shape in §6) skips the reviewer fan-out entirely. The workflow refutes each finding with
native severity `critical`/`high`/`medium` using a fresh agent (Codex findings carry no `verbatim`,
so the refuter Reads `file` around `line_start..line_end` instead of starting from a quote; same
keep-on-uncertainty bias), annotates `refuted`/`refute_reason`, and persists

```json
{ "scopeLabel": "...", "mode": "...", "codexFindings": [ ...all input findings, annotated... ] }
```

to `<repoRoot>/<outDir>/raw/codex-verify-result.json` (same persist agent + retry). Invocation:

```js
Workflow({
  scriptPath: "<this skill's base directory>/scripts/review-fanout.workflow.js",
  args: { scopeLabel, mode, repoRoot, verifyOnly: [ ...codex findings... ] },
});
```

## 2. Canonical FINDINGS_SCHEMA (defined in the workflow script)

```json
{
  "status": "DONE | BLOCKED",
  "name": "<reviewer name echo, optional — attributes journal.jsonl records; the script's own name assignment stays authoritative>",
  "blocked_reason": "<string, only when BLOCKED>",
  "verdict": "<reviewer-specific verdict string, optional>",
  "dropped_by_cap": "<integer ≥0, optional — candidates the reviewer discarded to respect its findings cap; surfaces silent cap truncation in the report>",
  "findings": [
    {
      "severity": "critical | important | minor",
      "file": "path/to/file.ts",
      "line": 42,
      "verbatim": "<exact quote, >= 10 chars>",
      "title": "<one-line title>",
      "why": "<reasoning>",
      "fix_sketch": "<one sentence, optional>",
      "kind": "local | systemic (systemic-failure-reviewer only)",
      "failure_mode": "stuck-state | invariant-without-repair | unsafe-recovery | over-pinned-contract (systemic only)",
      "scenario": "<one-sentence trigger→stuck-state chain (systemic only)>",
      "anchors": [
        {
          "file": "...",
          "line": 42,
          "verbatim": "...",
          "role": "(optional stage label)"
        }
      ]
    }
  ]
}
```

`verbatim` min length (10) and the `severity` enum are enforced by the schema validator, not by a
downstream parser. There is no STATUS line and no prose verdict block any more.

After validation, the workflow's Verify stage may annotate a finding with two extra fields the
schema does not declare (they are workflow annotations, not reviewer output):

```json
{
  "refuted": true,
  "refute_reason": "<refuter's counter-evidence, with file:line>"
}
```

Refuter verdicts themselves (`VERIFY_SCHEMA`) are `{ refuted, reason }` plus optional `file`/`line`
echoes of the finding's location — journal-reconstruction aids, ignored by the in-memory pairing.

## 3. Codex invocation pattern

`adversarial-review` has **no real backgrounding** — its `--background` flag is parsed but ignored
(`handleReviewCommand` always runs foreground), it prints no `background as <id>` line, and there is
no companion-level job to poll. So run it **synchronously** and background it with the **Bash tool's
`run_in_background: true`**.

Pass `--json`: the companion then emits exactly one JSON object on stdout (`outputResult` →
`console.log(JSON.stringify(payload))`) and routes progress to a job logfile instead of stderr
(`createTrackedProgress(..., { stderr: false })`), so stdout is clean machine output. Redirect stdout to
a file and stderr to a separate log so nothing can interleave with the captured JSON. (When the model
returns non-conforming output, `payload.result` is null but `payload.rawOutput` still carries the raw
model text inside the same `--json` payload — the degraded fallback parses that, NOT a separate
non-`--json` run; see §6.)

```bash
# Resolve companion script (latest installed version)
CODEX_CMD=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)

# Launch (in a Bash tool call with run_in_background: true). $CODEX_TARGET is one of:
#   --base "$CODEX_BASE"   (base / full modes)   |   --scope working-tree   (working-tree mode)
node "$CODEX_CMD" adversarial-review --json $CODEX_TARGET \
  >.comprehensive-code-review/raw/codex-adversarial.json \
  2>.comprehensive-code-review/raw/codex-adversarial.stderr.log
```

Do NOT pass `--background`; do NOT pass `--model` (let the companion auto-default to the best model);
and do NOT call the companion's `status`/`result` subcommands for reviews (those exist only for the
`task` subcommand). Harvest the review by reading `codex-adversarial.json` once the Bash task terminates
and `JSON.parse`-ing it (payload shape + fallback in §6). If it has not terminated by the time the
Workflow finishes, wait for it (Iron Law 2); if the file is empty/unparseable and `.stderr.log` shows a
crash, mark Codex BLOCKED.

`--base <ref>` makes Codex diff `merge-base(HEAD,<ref>)..HEAD`. Above 2 files / 256 KB the companion
self-collects — it sends only a summary + commit log + file list and tells Codex to inspect the range
itself, so the companion will not overflow. But in self-collect mode Codex must still inspect the
range, so an unbounded range makes Codex do a large/expensive pass (or decline). This is why `--full`
caps Codex to the recent window even though the agents review everything.

## 4. Codex target resolution (by mode)

| Mode                                      | Codex target                                                                        |
| ----------------------------------------- | ----------------------------------------------------------------------------------- |
| `--base <ref>` (with or without `--full`) | `--base <ref>` (mirrors the reviewers' `<ref>...HEAD` scope)                        |
| `--full` alone                            | `--base <CODEX_BASE>` where `CODEX_BASE`=`HEAD~30`, clamped to root if <=30 commits |
| no args (working tree)                    | `--scope working-tree` (mirrors the reviewers' working-tree diff — NOT a base ref)  |

Compute the `--full` bounded base safely:

```bash
if [ "$(git rev-list --count HEAD)" -gt 30 ]; then
  CODEX_BASE=$(git rev-parse HEAD~30)
else
  CODEX_BASE=$(git rev-list --max-parents=0 HEAD | tail -1)
fi
```

Codex mirrors the reviewers' scope in `--base` and working-tree modes. Only under `--full` do the two
diverge: agents review the entire codebase, Codex reviews the recent window (`HEAD~30`) to stay within
its context limit. Note this `--full`-only mismatch in the report. (Working-tree mode must use
`--scope working-tree`, never a root-commit base — the companion's `auto` scope would otherwise diff
against `main` when the tree is clean, but the skill already stops on a clean tree before reaching
Codex.)

## 5. Diff size management (base / working-tree modes only)

`--full` sends no diff (agents Read files themselves). For `--base` and working-tree modes, the
2000-line number is a **mode switch, not a cut point** — nothing is ever truncated. LLM review
detection degrades as context grows and every diff line is duplicated into all ~10 reviewer prompts,
so a large diff is moved out of the prompt and onto disk rather than discarded:

```bash
git diff <range> -- . "${EXCLUDES[@]}" 2>/dev/null | wc -l   # total lines decide the mode
```

`EXCLUDES` is the build-output pathspec list defined in `SKILL.md` Phase 1 — it must be in
scope here. Every diff command in this section carries `-- . "${EXCLUDES[@]}"` so the
mode-switch count, the on-disk patch, and the risk ranking all reflect the filtered set.

Working-tree mode diffs with `git diff HEAD -- . "${EXCLUDES[@]}"` (staged + unstaged — bare
`git diff` misses staged changes) and appends untracked files
(`git ls-files --others --exclude-standard -- . "${EXCLUDES[@]}"`) to `changedFiles`;
untracked files carry no diff hunks, so note in `reviewInput` that agents must Read them directly.
Always pass the complete `changedFiles` list in every mode.

### Inline mode — diff ≤ 2000 lines

`reviewInput` is the diff text itself (unchanged behavior). No artifact, no manifest, no extra tool
calls. This is the common case and must stay byte-for-byte as it was.

### Manifest mode — diff > 2000 lines

Reviewers mirror what Codex already does (§3, self-collect): they get a pointer to the **complete**
diff plus a risk-ordered map, and Read all of it. Nothing is dropped.

1. **Write the full diff to disk, once:**

   ```bash
   git diff <range> -- . "${EXCLUDES[@]}" > .comprehensive-code-review/raw/full-diff.patch   # never truncated
   ```

   (base: `<range>` = `<ref>...HEAD`; working-tree: `<range>` = `HEAD`.)

2. **Build a per-file line index into the patch** (start line of each file's section), so a reviewer
   can page the patch deterministically with Read offset/limit:

   ```bash
   grep -n '^diff --git' .comprehensive-code-review/raw/full-diff.patch   # "line:diff --git a/<f> b/<f>"
   ```

3. **Rank the changed files by risk** (so highest-risk content is read first; this is what removes the
   old filename-ordered arbitrariness). Sort by these three signals, in order:
   - **Security-sensitive path/name match** — a path matching the documented glob list
     (`auth`, `login`, `session`, `password`, `secret`, `token`, `crypto`, `payment`, `billing`,
     `sql`/`query`, `exec`, `deserialize`). Keep the list minimal.
   - **Churn** — reuse `--full`'s hotspot computation
     (`git log --since="12 months ago" --format= --name-only -- . "${EXCLUDES[@]}" | sort | uniq -c | sort -rn`).
   - **Change size** — `+adds`/`−dels` per file (`git diff --numstat <range> -- . "${EXCLUDES[@]}"`).

4. **Set `reviewInput`** to an instruction block + the risk-ranked manifest table (NOT diff text):

   ```
   The complete diff is at <repoRoot>/.comprehensive-code-review/raw/full-diff.patch (<N> lines).
   Read ALL of it before reviewing — page through it with Read offset/limit using the per-file line
   index below. The manifest is a reading order, not a substitute for the diff.

   | risk | file | +/− | patch line |
   | ---- | ---- | --- | ---------- |
   | sec  | api/auth/session.ts | +120/−4 | 1 |
   | churn| billing/charge.ts   | +60/−12 | 540 |
   | ...  | ...                 | ...     | ... |
   ```

**Pathological fallback (disclose-and-proceed):** if a diff is so large a single reviewer cannot read
it all within its context, the risk ordering guarantees the highest-risk content is read first. This
is the ONLY place sampling survives, and it is now risk-ranked, not filename-ordered. Surface the
partial-coverage caveat explicitly in the report's Scope section. (Auto-chunking the panel is a
future v2.)

**Report disclosure (Scope section):** note that manifest mode was used, the `full-diff.patch` path,
that reviewers were instructed to read all of it in risk order, and any pathological partial-coverage
caveat. The old "split into chunked `--base` runs" line is optional advice now, not a required
remediation.

The workflow script forwards `reviewInput` verbatim into each reviewer prompt (`buildPrompt`), so the
manifest needs no script change; `DIFFLESS_REVIEWERS` (documentation-reviewer) still get the
changed-files list only.

## 6. Citation verification spec (implemented by `scripts/verify-citations.mjs`)

This section is the SPEC for `scripts/verify-citations.mjs` — the skill runs the script (Phase 7)
and never hand-executes this procedure. The pseudocode below documents what the script does;
change the script and this spec together.

Source the reviewer findings from `.comprehensive-code-review/raw/workflow-result.json` (the file the
workflow wrote), not from the Workflow return value.

`is_excluded_build_output(path)` matches the Phase 1 `EXCLUDES` set: a `dist/`, `build/`, `out/`,
`.next/`, `.nuxt/`, `.svelte-kit/`, `.output/`, or `coverage/` path segment, a lockfile name
(`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `bun.lock`, `bun.lockb`), or a name ending in
`.min.js`, `.min.css`, or `.map`. Apply it to every track (incl. the Codex findings in §7 below) —
it backstops Codex, which self-collects its diff and cannot honor the gathering pathspecs.

```
for each finding in (workflowResult.reviewers[*].findings + codex findings):
    if is_excluded_build_output(finding.file):
        finding.verification = "dropped_excluded_build_output" -> move to dropped list
        continue                                                # backstops Codex; reviewers are pre-filtered
    if finding.refuted:
        finding.verification = "refuted"                        -> move to dropped list
        # record refute_reason in the dropped table; NEVER resurrect a refuted finding
    elif finding.kind == "systemic":
        # Systemic: require failure_mode + scenario + ≥2 anchors, then verify every anchor.
        if not finding.failure_mode or not finding.scenario or len(finding.anchors or []) < 2:
            finding.verification = "dropped_systemic_incomplete" -> move to dropped list
        else:
            for anchor in finding.anchors:
                [apply same line±2/Grep-rescue logic to anchor.file/anchor.line/anchor.verbatim]
                if anchor fails verification:
                    finding.verification = "dropped_systemic_anchor_unverified" -> move to dropped list; break
            if finding not yet dropped:  # all anchors pass — top-level (= anchors[0]) already covered
                finding.verification = "ok"
    elif finding.file and finding.line and finding.verbatim:
        if len(collapse_whitespace(finding.verbatim)) < 10:
            finding.verification = "dropped_quote_too_short"   -> move to dropped list
        else:
            content = Read(finding.file, offset=max(0, finding.line-2), limit=5)
            if collapse_whitespace(finding.verbatim) in collapse_whitespace(content):
                finding.verification = "ok"
            elif finding.verbatim is single-line:
                # Rescue: line-number drift is the canonical LLM citation failure.
                matches = Grep(finding.file, fixed-string = trim(finding.verbatim), with line numbers)
                if exactly 1 matching line:
                    finding.line = matched line; finding.verification = "relocated_ok"
                else:
                    finding.verification = "dropped_no_match"   -> move to dropped list
            else:
                finding.verification = "dropped_no_match"       -> move to dropped list
    else:
        finding.verification = "dropped_no_citation"            -> move to dropped list
```

`collapse_whitespace`: replace runs of whitespace (incl. newlines) with a single space, then trim.
The Grep rescue applies only to single-line quotes (grep is line-based); a multi-line quote that
fails the line±2 check is dropped as before.

Codex (`adversarial-review --json`) returns a structured payload, parsed from
`raw/codex-adversarial.json`:

```
payload.target   // ALWAYS present (assigned before result/parseError; absence ⇒ companion crash).
                 //   base / --full: { mode: "branch", baseRef: "<ref>", explicit: true }
                 //   working-tree:  { mode: "working-tree", explicit: true }   (no baseRef)
payload.result   // null on parse failure; else matches review-output.schema.json:
                 //   { verdict: "approve"|"needs-attention", summary,
                 //     findings: [ { severity: critical|high|medium|low, title, body,
                 //                   file, line_start, line_end, confidence: 0-1, recommendation } ],
                 //     next_steps: [ ... ] }
payload.rawOutput   // raw model text (used by the degraded fallback path)
payload.parseError  // set when result is null
```

The review schema has **no `verbatim` field** (`additionalProperties:false`), so quote-verification is
impossible by construction — line-range existence-checking is the verification ceiling. For each
structured finding: confirm `file` exists AND both `line_start` and `line_end` fall within the file's
length; on failure move it to Dropped Findings (`codex_file_missing` / `codex_line_out_of_range`).
Refutation substitutes for the missing quote check: critical/high/medium findings go through the
verify-only Workflow pass (§1) and arrive at the script (via `--codex-verify`) with `refuted`
annotations that drop them like any refuted reviewer finding. Include surviving findings under
"Adversarial-Codex" and note they are existence-checked and (critical/high/medium) refuter-verified,
not quote-verified.

Beyond the pseudocode above, the script also: tags verified non-systemic findings outside the
changed-files list with `outside_diff: true` (diff modes only), maps Codex native severities to the
standard scale (`critical→critical`, `high|medium→important`, `low→minor`, native kept as
`codex_severity`), dedups across reviewers (same file AND same `kind` AND (lines ±3 OR identical
collapsed verbatim); highest severity wins, others in `also_flagged_by`), and emits
`stats.perReviewer` (verified / refuted / citation-dropped counts) + `stats.duplicatesMerged` for
the report's Calibration line.

**Harvest** the payload as a validity/staleness gate, then a two-outcome branch — a structured-output
failure must never report as a clean success:

1. **Gate A — validity/crash:** file missing/empty/not valid JSON, or `payload.target` absent, or the
   Bash task not yet terminated → **BLOCKED** (companion crash — see `codex-adversarial.stderr.log`).
2. **Gate B — staleness:** `payload.target` must match the run just launched, else **BLOCKED** (stale /
   foreign): base / `--full` → `target.mode === "branch"` AND `target.baseRef === <the launched ref>`;
   working-tree → `target.mode === "working-tree"`. (This is the Codex analogue of the
   `workflow-result.json` scopeLabel/mode guard.)
3. **Route on `result`:**
   - **Structured** — `payload.result` is a non-null object with a `findings` array → existence-check
     each finding (above) and mark Codex DONE.
   - **Degraded** — otherwise (`result` null / absent / not findings-bearing) → existence-check any
     `file:line` references parsed from `payload.rawOutput`: **≥1 recovered** → Codex DONE with a
     mandatory degraded note (structured output unavailable, not schema-validated); **zero recovered** →
     Codex **BLOCKED**.
