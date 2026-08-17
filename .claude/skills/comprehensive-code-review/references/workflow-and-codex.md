# Workflow & Codex Reference

This skill dispatches ONE `Workflow` that owns the 11-reviewer fan-out, the Codex adversarial
review (a codex-runner agent inside the workflow runs the CLI), and the Codex-verify refutation
pass — all concurrent by construction. Citation verification runs via
`scripts/verify-citations.mjs`; report assembly stays in the main session. This file is the
contract for all of them.

After the changed-files empty guard and before any diff, seed, or workflow artifact is written, the
orchestrator calls `scripts/review-run.mjs init` to atomically create a unique
`.code-review/runs/<UTC YYYYMMDDTHHMMSSZ>-<profile>-<6 alphanumeric nonce>/` directory, including its
`raw/` and `raw/inputs/` subdirectories. It immediately
writes `run.json` with `runtime`, `profile`, `runId`, `scopeLabel`, `mode`, `passNumber` (from
`init --pass-number <n>`, integer ≥1, default 1 — the review⇄fix loop iteration this run is),
`startedAt`, and
`status: "RUNNING"`; after report emission the orchestrator calls `review-run.mjs finish` to add
`completedAt` and set `DONE` or `DONE_WITH_CONCERNS`. Early stops become `ABORTED` with a reason.
Runs are never cleared or reused. `outDir` is mandatory; the workflow has no legacy/default output
directory.

## 1. Single-workflow fan-out (reviewers + Codex)

Invoke the shipped script by path (do NOT inline a script string):

```js
Workflow({
  scriptPath: "<this skill's base directory>/scripts/review-fanout.workflow.js",
  args: {
    runtime: "claude",
    profile: "focused" | "comprehensive",
    runId: "<UTC timestamp>-<profile>-<nonce>",
    scopeLabel:
      "<human-readable scope, e.g. 'ENTIRE CODEBASE (current state)' or 'abc123...HEAD'>",
    mode: "full" | "base" | "working-tree",
    repoRoot: "<absolute repo root>",
    outDir: ".code-review/runs/<runId>",
    inputs: {
      reviewInputPath: "<absolute path to raw/inputs/review-input.txt>",
      changedFilesPath: "<absolute path to raw/changed-files.txt>",
      claudeMdPath: null | "<absolute repository-contained CLAUDE.md path>",
      docsManifestPath: null | "<absolute path to raw/inputs/docs-manifest.txt>",
      changeContextPath: null | "<absolute path to raw/inputs/change-context.json>",
      specPath: null | "<absolute path to raw/inputs/spec>",
      dispositionsPath: null | "<absolute path to raw/inputs/dispositions.txt>",
    },
    codex: null | {
      cmd: "<absolute path to codex-companion.mjs (CODEX_CMD)>",
      launcher: "<absolute path to this skill's scripts/codex-launch.mjs>",
      targetFlags: "--base <ref>" | "--scope working-tree",
      expectedTarget:
        { mode: "branch", baseSha: "<git rev-parse'd SHA of the trusted ref>" } |
        { mode: "working-tree" },
    },
    reviewers: [
      {
        name: "architecture-reviewer",
        charterPath: "<absolute canonical path to agents/architecture-reviewer.md>",
      },
      {
        name: "quality-reviewer",
        charterPath: "<absolute canonical path to agents/quality-reviewer.md>",
      },
      // ... one entry per reviewer ...
      {
        name: "systemic-failure-reviewer",
        charterPath: "<absolute canonical path to agents/systemic-failure-reviewer.md>",
      },
      // include implementation-reviewer ONLY if --spec is valid (Phase 4)
    ],
  },
});
```

The Workflow runtime forbids non-deterministic globals and direct filesystem access —
`new TextEncoder`, `Date.now`, `Math.random`, `require("node:fs")`/`import ... from "node:fs"` —
enforced by a static regression check in `review-fanout.workflow.test.mjs`.

The Workflow tool input stays at or below 8 KiB. The workflow validates `runtime`, `profile`,
`runId`, `scopeLabel`, `mode`, `outDir`, the path-only input shape, and the absence of legacy inline
fields before dispatch. A skill-scoped PreToolUse hook independently verifies the exact bundled
script, canonical roster/charters, current-run artifact containment/readability, and pins both the
bundled Codex launcher (`scripts/codex-launch.mjs`) and the installed companion
(`$HOME/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs`) before
auto-allowing the call. Persisted workflow and Codex-verification results echo all
five identity/scope fields; harvesters reject any mismatch as stale/foreign.

When `changeContextPath` is set, that same hook and the workflow's own run-time preflight
independently enforce the change-context content contract (non-empty JSON array, allowed
`source` values, non-empty `text`, ≤8192 combined UTF-8 bytes) — defense in depth that narrows,
but does not close, the TOCTOU window between hook approval and the moment an agent actually
reads the file: reviewer/codex agents still read the file lazily afterward, so a change landing
between the run-time preflight and that later read is not caught. The preflight's `jq -s -e`
check requires `jq` on `PATH`.

`codex: null` (Codex unavailable) makes the workflow report the track SKIPPED; reviewers run
regardless. The orchestrator never launches Codex itself — the old two-call contract (backgrounded
Codex Bash + Workflow in one message) relied on prose compliance and serialized whenever the model
waited on Codex before launching the workflow.

The workflow's final stage writes

```json
{ "runtime": "claude", "profile": "...", "runId": "...", "scopeLabel": "...", "mode": "...",
  "reviewers": [ { "name", "status", "verdict?", "blocked_reason?", "dropped_by_cap?", "findings": [] } ],
  "codex": { "status": "DONE|BLOCKED|SKIPPED", "outcome": "structured|degraded|null",
             "blocked_reason?": "...", "verdict?": "...", "summary?": "...",
             "degraded_refs": [ { "file": "...", "line": 1 } ], "verifyRan": true } }
```

to `<repoRoot>/<outDir>/raw/workflow-result.json`. **Read that file to harvest the
result — the workflow's JS `return` value is NOT retrievable by the caller** (`TaskOutput` is
deprecated; the completion notification carries only prose). Each `findings[]` entry matches the
canonical schema below. Every reviewer named in `args.reviewers` appears in the result (BLOCKED with a
reason if its agent failed or was skipped). The `codex` key is the track's terminal state only — the
review content itself stays in `codex-adversarial.json` (source of truth, written by the CLI) and
`codex-verify-result.json` (refuted annotations, written when `verifyRan` is true).

The persist stage is transcription-checked: the persist agent parses the read-back and confirms the
expected entry and nested-finding counts before returning `written=true`. A failed persist (no
output, `written` false, or count mismatch) is retried once with a fresh agent before the workflow gives up — persistence is
the run's single point of failure. If both attempts fail, the skill's journal fallback (Phase 6)
reconstructs the result from the run's `journal.jsonl`; reviewer results echo `name` and refuter
verdicts echo `file`/`line` to help that reconstruction. This is **best-effort, not deterministic**:
the journal has no record of an agent's `label`, so pairing a refuter verdict back to its finding
relies entirely on these schema-optional echoes — if a verdict omits the echo, or two reviewers
flagged the same file:line (the case the dedup stage exists for), the match is ambiguous. Pair by
`file`/`line`; on a missing echo or an ambiguous (>1 candidate) match, preserve the finding's original
classification rather than guess. When pairing is unambiguous, apply the same refutation/intent/doc
vote table described below, including refutation precedence and the rule against replacing a
reviewer-authored question.

These behaviors live inside the workflow, not the skill:

- **Adversarial Verify stage**: each critical/important finding is handed to a fresh refuter agent
  that sees only the claim + location (title, severity, file:line, verbatim quote — NOT the
  reviewer's `why` reasoning chain) and must hunt for concrete counter-evidence. Refuters run on a
  cheaper model than the reviewers (a refuter can only *drop* a finding on concrete counter-evidence,
  so a weaker one keeps more, never loses a real bug — and an Opus-reviewer/Sonnet-refuter pairing is
  a cross-model check with fewer correlated blind spots). **Criticals get 2 independent refuters and
  are refuted only unanimously** (a single refuter is the weakest link for the highest-stakes drops);
  importants get 1. Refuted findings
  stay in the payload annotated `refuted: true` + `refute_reason` — the skill moves them to Dropped
  Findings (never silently deleted, never resurrected). A verifier that dies/skips keeps the finding.
  The same vote table classifies intent: criticals require two `intent_question` votes or two
  `doc_basis` votes; importants require one. The fields are mutually exclusive and documentation
  basis is an exact file/line/verbatim citation. Refutation takes precedence. Mixed, conflicting,
  missing, or malformed votes preserve the reviewer classification; an existing documentation basis
  cannot be demoted to a question, and a reviewer question is never replaced with a refuter's wording.
- **Diffless reviewers**: `documentation-reviewer` audits current state, not the change; the workflow
  withholds the diff from it (it gets the changed-files list only) to avoid context dilution.
- **Spec scoping**: `args.inputs.specPath` (when provided) is read ONLY by implementation-reviewer —
  broadcasting its content would cost spec × N tokens and duplicate the acceptance-criteria pass.
- **Dispositions splicing**: `args.inputs.dispositionsPath` points to the output from
  `review-run.mjs render-dispositions`.
  Suppressed claims require new evidence plus `challenges_disposition`; `intent-confirmed` claims
  live in a separate user-confirmed-requirements block that reviewers re-evaluate and report normally.
  It is an INPUT DOCUMENT, not shared belief-state. Refuters and the Codex track never see it. Reviewer
  prompts also instruct that every critical/important finding set `reachability`
  (direct/conditional/theoretical).
- **Codex track**: when `args.codex` is set, a codex-runner agent (`general-purpose`, so Bash is
  guaranteed) runs the adversarial-review CLI per §3, applies the §6 validity/staleness gates and
  structured/degraded routing, and returns the track's terminal state — concurrent with the reviewer
  pipeline (the promise starts before the pipeline is awaited).
- **Documentation manifest**: `args.inputs.docsManifestPath` is sent to every reviewer and refuter.
  The codex-runner passes the artifact path as the companion's existing focus-text positional
  argument using POSIX single-quote escaping. Every classification path reads relevant listed
  documents first.
- **Change rationale**: `args.inputs.changeContextPath` points to source-attributed, capped untrusted context from the
  explicit request, base-range commit messages, and optional `--context` file. It goes to reviewers,
  refuters, and Codex, but can never substitute for code or verified documentation evidence.
- **Codex-verify stage**: when the runner returns a structured outcome with ≥1 finding, the workflow
  classifies every severity, including low, in-script — concurrent with
  reviewers still in flight. Codex findings carry no `verbatim`, so each refuter Reads `file` around
  `line_start..line_end` instead of starting from a quote; same keep-on-uncertainty bias; native
  criticals need 2 votes, high/medium/low 1. It annotates `refuted`/`refute_reason`,
  mutually exclusive `intent_question` or cited `doc_basis` and persists
  `{ "runtime", "profile", "runId", "scopeLabel", "mode", "codexFindings": [ ...all findings, annotated... ] }` to
  `<repoRoot>/<outDir>/raw/codex-verify-result.json` (same persist agent + retry), and sets
  `codex.verifyRan: true` in the consolidated result.

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
      "intent_question": "<optional concrete undocumented intent choice, min 10 chars>",
      "doc_basis": { "file": "docs/contract.md", "line": 12, "verbatim": "<exact quote, >=10 chars>" },
      "reachability": "direct | conditional | theoretical (required on critical/important: direct = fails under normal operation; conditional = specific but plausible state; theoretical = improbable operational sequence — important+theoretical is downgraded to minor downstream)",
      "challenges_disposition": "<ledger id, optional — ONLY to challenge a previously-adjudicated claim with NEW evidence>",
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

After validation, the workflow's Verify stage may annotate a finding with these extra fields the
schema does not declare (they are workflow annotations, not reviewer output):

```json
{
  "refuted": true,
  "refute_reason": "<refuter's counter-evidence, with file:line>",
  "intent_question": "<intent ruling needed>",
  "doc_basis": { "file": "docs/contract.md", "line": 12, "verbatim": "<exact quote>" }
}
```

Refuter verdicts themselves (`VERIFY_SCHEMA`) are `{ refuted, reason, intent_question?, doc_basis? }`
with `intent_question` and `doc_basis` mutually exclusive, plus optional `file`/`line`
echoes of the finding's location — journal-reconstruction aids, ignored by the in-memory pairing.

## 3. Codex invocation pattern (runs INSIDE the workflow's codex-runner agent)

The orchestrator only resolves `CODEX_CMD`, the launcher path, and the target flags (Phase 2/3) and
passes them in `args.codex`; the workflow's codex-runner agent executes the CLI. These are the CLI
facts that agent's prompt encodes:

`adversarial-review` has **no real backgrounding** — its `--background` flag is parsed but ignored
(`handleReviewCommand` always runs foreground), it prints no `background as <id>` line, and there is
no companion-level job to poll. The runner must also **never** use the Bash tool's
`run_in_background: true`: background-task completion notifications never reach workflow subagents,
and turn-end teardown kills a subagent's tracked background tasks — that combination deterministically
killed the CLI mid-review with 0-byte output. Instead the runner invokes this skill's
`scripts/codex-launch.mjs` as a **foreground** Bash call (`timeout: 600000`): the launcher spawns the
companion **OS-detached** exactly once (pidfile at `<outDir>/raw/codex.pid`; every re-run
attach-and-waits, never relaunches), self-limits each invocation (`--max-wait-ms`, default 9 min —
under the 10-minute foreground cap) and owns the total deadline (`--deadline-ms`, default 40 min),
and prints exactly one stdout token the runner branches on: `EXITED` (proceed to the gates),
`STILL_RUNNING pid=<n>` or a Bash-call timeout (re-run the same command), `TIMEOUT pid=<n>` (attempt
Gate A once — a recycled pid may hide a finished review — else BLOCKED quoting the stderr tail + pid;
never kill the process). Re-running the launcher is always safe; the runner never kills a review.

Pass `--json`: the companion then emits exactly one JSON object on stdout (`outputResult` →
`console.log(JSON.stringify(payload))`) and routes progress to a job logfile instead of stderr
(`createTrackedProgress(..., { stderr: false })`), so stdout is clean machine output. Redirect stdout to
a file and stderr to a separate log so nothing can interleave with the captured JSON. (When the model
returns non-conforming output, `payload.result` is null but `payload.rawOutput` still carries the raw
model text inside the same `--json` payload — the degraded fallback parses that, NOT a separate
non-`--json` run; see §6.)

```bash
# Orchestrator (Phase 2): resolve companion script (latest installed version)
CODEX_CMD=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)

# codex-runner agent (inside the workflow), FOREGROUND, timeout 600000, repeated until EXITED.
# Target flags after -- are one of:
#   --base "$CODEX_BASE"   (base / full modes)   |   --scope working-tree   (working-tree mode)
node "<skill dir>/scripts/codex-launch.mjs" \
  --companion "$CODEX_CMD" \
  --json-out <runDir>/raw/codex-adversarial.json \
  --stderr-out <runDir>/raw/codex-adversarial.stderr.log \
  --pid-file <runDir>/raw/codex.pid \
  -- $CODEX_TARGET '<path-only docs manifest focus text>'
```

No `--background`; no `--model` (let the companion auto-default to the best model); no
`status`/`result` subcommand calls for reviews (those exist only for the `task` subcommand). Once the
launcher prints `EXITED` the runner reads `codex-adversarial.json`, `JSON.parse`s it, and applies the
§6 gates and routing; the orchestrator consumes only the `codex` key of `workflow-result.json` plus
the raw files on disk.

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
detection degrades as context grows, so a large diff uses a risk-ranked manifest rather than being
treated as one sequential input. Both modes store review input on disk:

```bash
git diff <range> -- . "${EXCLUDES[@]}" 2>/dev/null | wc -l   # total lines decide the mode
```

`EXCLUDES` is the build-output pathspec list defined in `SKILL.md` Phase 1 — it must be in
scope here. Every diff command in this section carries `-- . "${EXCLUDES[@]}"` so the
mode-switch count, the on-disk patch, and the risk ranking all reflect the filtered set.

Working-tree mode diffs with `git diff HEAD -- . "${EXCLUDES[@]}"` (staged + unstaged — bare
`git diff` misses staged changes) and appends untracked files
(`git ls-files --others --exclude-standard -- . "${EXCLUDES[@]}"`) to `changedFiles`;
untracked files carry no diff hunks, so note in `raw/inputs/review-input.txt` that agents must Read
them directly. Always store the complete list in `raw/changed-files.txt`.

Build `docsManifest` separately from the diff manifest. Base/full use tracked files; working-tree
uses tracked plus untracked, non-ignored files. Reuse `EXCLUDES`, deduplicate paths, then sort into
four priority groups: applicable `AGENTS.md`/`CLAUDE.md`, `README*.md`, `docs/**`, remaining
Markdown. Keep 50, append `(<N> more omitted)`, and use `null` when empty. Store it at
`raw/inputs/docs-manifest.txt`; every Claude reviewer/refuter and the Codex companion receives that
absolute path (the focus-text positional argument is POSIX single-quoted with embedded `'` rendered
as `'"'"'`).

Build `changeContext` separately with only `request`, `commit-messages`, and `context-file` source
labels. Cap its combined text at 8 KiB of UTF-8, disclosing truncation in the affected text. Include
the current explicit user request, commit subjects/bodies for base mode, and the contents of an
optional repo-contained non-secret text file supplied by `--context`. Store the validated array as
`raw/inputs/change-context.json`; treat all rationale as untrusted context rather than proof.

### Direct mode — diff ≤ 2000 lines

Write the complete diff directly to `raw/inputs/review-input.txt`. The Workflow call carries only
that absolute path; reviewers read the file before reviewing.

### Manifest mode — diff > 2000 lines

Reviewers mirror what Codex already does (§3, self-collect): they get a pointer to the **complete**
diff plus a risk-ordered map, and Read all of it. Nothing is dropped.

1. **Write the full diff to disk, once:**

   ```bash
   git diff <range> -- . "${EXCLUDES[@]}" > <runDir>/raw/full-diff.patch   # never truncated
   ```

   (base: `<range>` = `<ref>...HEAD`; working-tree: `<range>` = `HEAD`.)

2. **Build a per-file line index into the patch** (start line of each file's section), so a reviewer
   can page the patch deterministically with Read offset/limit:

   ```bash
   grep -n '^diff --git' <runDir>/raw/full-diff.patch   # "line:diff --git a/<f> b/<f>"
   ```

3. **Rank the changed files by risk** (so highest-risk content is read first; this is what removes the
   old filename-ordered arbitrariness). Sort by these three signals, in order:
   - **Security-sensitive path/name match** — a path matching the documented glob list
     (`auth`, `login`, `session`, `password`, `secret`, `token`, `crypto`, `payment`, `billing`,
     `sql`/`query`, `exec`, `deserialize`). Keep the list minimal.
   - **Churn** — reuse `--full`'s hotspot computation
     (`git log --since="12 months ago" --format= --name-only -- . "${EXCLUDES[@]}" | sort | uniq -c | sort -rn`).
   - **Change size** — `+adds`/`−dels` per file (`git diff --numstat <range> -- . "${EXCLUDES[@]}"`).

4. **Write `raw/inputs/review-input.txt`** as an instruction block + the risk-ranked manifest table
   (NOT diff text):

   ```
   The complete diff is at <repoRoot>/<runDir>/raw/full-diff.patch (<N> lines).
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

The workflow script forwards only the artifact path into each reviewer prompt;
`DIFFLESS_REVIEWERS` (documentation-reviewer) get the changed-files path and do not read the review
input.

## 6. Citation verification spec (implemented by `scripts/verify-citations.mjs`)

This section is the SPEC for `scripts/verify-citations.mjs` — the skill runs the script (Phase 7)
and never hand-executes this procedure. The pseudocode below documents what the script does;
change the script and this spec together.

The complete order is fixed: exclusion → refutation → systemic/citation checks → reachability →
disposition matching → Open Question split → actionable dedup/blocking.

Source the reviewer findings from `<runDir>/raw/workflow-result.json` (the file the
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
Refutation/classification substitutes for the missing quote check: every structured severity,
including low, goes through the workflow's in-script Codex-verify stage (§1) and arrives at the
script (via `--codex-verify`) with optional `refuted`, `intent_question`, or `doc_basis`
annotations. Refutation drops as usual; intent-dependent entries become Open Questions. Include
surviving findings under "Adversarial-Codex" and note they are existence-checked and
refuter-classified, not quote-verified.

Every `doc_basis` is independently verified with the same repo-contained file/line/verbatim check as
a code citation. A valid basis makes the finding an actionable documented defect. An invalid basis
cannot promote or demote a finding: restore a question that was provisionally promoted, otherwise
strip the basis, retain the actionable finding, and attach a verification warning. Legacy string
values are readable diagnostics only and are never authoritative.

The optional inputs are LLM/CLI-written and must never crash the pass: a missing, empty, or
invalid-JSON `--codex` file sets `codexPayloadError` in the output (Codex findings empty; the
orchestrator reports the Codex track BLOCKED with that reason); same for `--codex-verify` →
`codexVerifyError`, in which case the refutation loop is skipped and Codex findings ship unrefuted
(the orchestrator adds the mandatory "not adversarially verified" note — never drop a finding
because verification broke). Both errors also echo on stderr and in the stdout summary line.
Codex verification entries carrying any refutation, intent, or doc-basis annotation are matched by
file + line_start + title. Unmatched refutations increment `unmatchedCodexRefutations`; unmatched
non-refutation annotations increment the separate `unmatchedCodexAnnotations` warning count.
`--workflow-result` is a required input with its own journal-fallback recovery; the script still
fails hard on it.

Beyond the pseudocode above, the script also: tags verified non-systemic findings outside the
changed-files list with `outside_diff: true` (diff modes only), maps Codex native severities to the
standard scale (`critical→critical`, `high|medium→important`, `low→minor`, native kept as
`codex_severity`), dedups across reviewers (same file AND same `kind` AND (lines ±3 OR identical
collapsed verbatim); highest severity wins while all reviewer/blocking/disposition provenance is
merged, and distinct disposition ids are not merged), and emits
`stats.perReviewer` (verified / refuted / adjudicated / citation-dropped counts) +
`stats.duplicatesMerged` + `stats.openQuestions` + `stats.decisionRequired` + `stats.previouslyAdjudicated` +
`stats.unmatchedCodexRefutations` + `stats.unmatchedCodexAnnotations` +
`stats.blocking` for the report's
Summary and Calibration lines.

### Dispositions, reachability downgrade, blocking (anti-ratcheting)

After excluded/refuted/systemic/citation checks and before dedup, the script runs these deterministic passes over the
verified findings (change the script and this spec together):

1. **Reachability downgrade** — `severity === "important"` AND `reachability === "theoretical"` →
   severity becomes `minor` with `downgraded_from: "important"`. Criticals never auto-downgrade;
   a missing `reachability` leaves the severity untouched (conservative).
2. **Adjudication split** — optional `--dispositions <path>` points at the cross-run ledger
   `<repoRoot>/.code-review/dispositions.json` (written by `review-run.mjs disposition`). A missing
   file is a no-op (fresh repo); an unreadable/invalid one sets `dispositionsError` in the output
   and skips matching (fail-open, the `codexPayloadError` pattern). Entries with status
   `overturned` never match. `accepted-risk`, `by-design`, and `intent-confirmed` are effective only when
   `decidedBy === "user"`; incorrectly attributed entries are ignored. **Match** = same repo-relative `file` AND (exact normalized title OR
   ≥2 fingerprint keywords all present in the normalized title+why), where normalization =
   lowercase, strip non-alphanumerics, collapse whitespace. Codex findings arrive with
   `why = body`, so the same matcher deterministically kills blind Codex re-raises. Matched
   findings move to a separate `previouslyAdjudicated[]` output array (finding + `disposition_id`
   / `disposition_status` / `disposition_reason`; per-reviewer `adjudicated` stat) — not in
   `findings`, not in `dropped`, excluded from dedup and blocking. **Exception**: a finding with
   `challenges_disposition === <matched id>` stays actionable (it already survived its own
   refutation); a challenge whose id matches nothing (or a different entry) also stays, annotated
   `challenge_unmatched: true` — surfaced, never silently dropped. `by-design` routes to
   `previouslyAdjudicated`. `intent-confirmed` clears `intent_question`, sets
   `intent_confirmed: true`, attaches disposition id/status/reason, and remains actionable under
   ordinary dedup/blocking. Challenges retain precedence.
3. **Open Question split** — any remaining finding with `intent_question` moves independently to
   `openQuestions[]`, gets `open_question: true`, `blocking: false`, and `decision_required: true`
   for critical/important severity, and is excluded from dedup. Questions at the same site are never
   merged; `stats.decisionRequired` drives NEEDS-DECISION only when no actionable blocker exists.
4. **Blocking computation** (after actionable dedup) — compute each source finding's blocking state
   before merge and OR those states across duplicates. A later blocking reviewer can never disappear
   behind an earlier nonblocking reviewer. `stats.blocking` is the count.

## Empirical regression benchmark

`benchmarks/corpus.json` is the versioned 14-case seeded/clean corpus. Before changing reviewer
rosters, prompts, intent policy, severity policy, or consolidation, materialize each case in an
isolated temporary repository and run both Claude and native Codex profiles three times. Record each
run's `verified-findings.json` in a results index:

```json
{"runs":[{"case":"security-sql-injection","runtime":"claude","repetition":1,"verifiedFindings":"/absolute/path/verified-findings.json"}]}
```

Score it offline with
`node scripts/review-benchmark.mjs --results <index.json> [--out <score.json>]`. Compare seeded
recall, clean-case pass rate, case pass rate, stability, and per-case outcomes against the previous
baseline. Do not impose an arbitrary CI pass threshold: review regressions by case and retain the
raw repeated runs so stochastic changes are visible.

**Harvest** — the workflow's codex-runner agent applies these gates and routing itself and reports
the result in `workflow-result.json`'s `codex` key (the orchestrator re-applies them only in the
journal-fallback salvage path). A structured-output failure must never report as a clean success:

1. **Gate A — validity/crash:** file missing/empty/not valid JSON, or `payload.target` absent →
   **BLOCKED** (companion crash — see `codex-adversarial.stderr.log`).
2. **Gate B — staleness:** `payload.target` must match `expectedTarget`, else **BLOCKED** (stale /
   foreign): base / `--full` → `target.mode === "branch"` AND `target.baseRef` resolving to
   `expectedTarget.baseSha` (`baseRef` is untrusted external output — regex-validate
   `^[A-Za-z0-9._/@{}~^-]+$` before any git command, compare resolved SHAs, not spellings);
   working-tree → `target.mode === "working-tree"`. (This is the Codex analogue of the
   `workflow-result.json` scopeLabel/mode guard.)
3. **Route on `result`:**
   - **Structured** — `payload.result` is a non-null object with a `findings` array → mark Codex DONE,
     `outcome: "structured"` (per-finding existence checks run later in `verify-citations.mjs`).
   - **Degraded** — otherwise (`result` null / absent / not findings-bearing) → existence-check any
     `file:line` references parsed from `payload.rawOutput`: **≥1 recovered** → Codex DONE,
     `outcome: "degraded"` with the recovered refs in `codex.degraded_refs` (the skill adds the
     mandatory degraded note); **zero recovered** → Codex **BLOCKED**.
