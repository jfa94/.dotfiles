# Workflow & Codex Reference

This skill dispatches the 10 specialist reviewers through a `Workflow` and runs Codex as a
separate background Bash job. Citation verification and report assembly stay in the main
session. This file is the contract for all three.

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
      // include implementation-reviewer ONLY if --spec is valid (Phase 4)
    ],
  },
});
```

The workflow's final stage writes `{ reviewers: [ { name, status, verdict?, blocked_reason?, findings: [...] }, ... ] }`
to `<repoRoot>/.comprehensive-code-review/raw/workflow-result.json`. **Read that file to harvest the
result — the workflow's JS `return` value is NOT retrievable by the caller** (`TaskOutput` is
deprecated; the completion notification carries only prose). Each `findings[]` entry matches the
canonical schema below. Every reviewer named in `args.reviewers` appears in the result (BLOCKED with a
reason if its agent failed or was skipped).

## 2. Canonical FINDINGS_SCHEMA (defined in the workflow script)

```json
{
  "status": "DONE | BLOCKED",
  "blocked_reason": "<string, only when BLOCKED>",
  "verdict": "<reviewer-specific verdict string, optional>",
  "findings": [
    {
      "severity": "critical | important | minor",
      "file": "path/to/file.ts",
      "line": 42,
      "verbatim": "<exact quote, >= 5 chars>",
      "title": "<one-line title>",
      "why": "<reasoning>",
      "fix_sketch": "<one sentence, optional>"
    }
  ]
}
```

`verbatim` min length (5) and the `severity` enum are enforced by the schema validator, not by a
downstream parser. There is no STATUS line and no prose verdict block any more.

## 3. Codex invocation pattern

`adversarial-review` has **no real backgrounding** — its `--background` flag is parsed but ignored
(`handleReviewCommand` always runs foreground), it prints no `background as <id>` line, and there is
no companion-level job to poll. So run it **synchronously** and background it with the **Bash tool's
`run_in_background: true`**; harvest its stdout (the review markdown) when the Bash task completes.

```bash
# Resolve companion script (latest installed version)
CODEX_CMD=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)

# Launch (in a Bash tool call with run_in_background: true). $CODEX_TARGET is one of:
#   --base "$CODEX_BASE"   (base / full modes)   |   --scope working-tree   (working-tree mode)
node "$CODEX_CMD" adversarial-review $CODEX_TARGET 2>&1
```

Do NOT pass `--background`, and do NOT call the companion's `status`/`result` subcommands for reviews
(those exist only for the `task` subcommand). Harvest the review by reading the backgrounded Bash
task's output once it terminates. If it has not terminated by the time the Workflow finishes, wait for
it (Iron Law 2); if it never produces output, mark Codex BLOCKED.

`--base <ref>` makes Codex diff `merge-base(HEAD,<ref>)..HEAD`. Above 2 files / 256 KB the companion
self-collects — it sends only a summary + commit log + file list and tells Codex to inspect the range
itself, so the companion will not overflow. But in self-collect mode Codex must still inspect the
range, so an unbounded range makes Codex do a large/expensive pass (or decline). This is why `--full`
caps Codex to the recent window even though the agents review everything.

## 4. Codex target resolution (by mode)

| Mode                                      | Codex target                                                                        |
| ----------------------------------------- | ----------------------------------------------------------------------------------- |
| `--base <ref>` (with or without `--full`) | `--base <ref>` (mirrors the reviewers' `<ref>...HEAD` scope)                        |
| `--full` alone                            | `--base <CODEX_BASE>` where `CODEX_BASE`=`HEAD~10`, clamped to root if <=10 commits |
| no args (working tree)                    | `--scope working-tree` (mirrors the reviewers' working-tree diff — NOT a base ref)  |

Compute the `--full` bounded base safely:

```bash
if [ "$(git rev-list --count HEAD)" -gt 10 ]; then
  CODEX_BASE=$(git rev-parse HEAD~10)
else
  CODEX_BASE=$(git rev-list --max-parents=0 HEAD | tail -1)
fi
```

Codex mirrors the reviewers' scope in `--base` and working-tree modes. Only under `--full` do the two
diverge: agents review the entire codebase, Codex reviews the recent window (`HEAD~10`) to stay within
its context limit. Note this `--full`-only mismatch in the report. (Working-tree mode must use
`--scope working-tree`, never a root-commit base — the companion's `auto` scope would otherwise diff
against `main` when the tree is clean, but the skill already stops on a clean tree before reaching
Codex.)

## 5. Diff size management (base / working-tree modes only)

`--full` sends no diff (agents Read files themselves). For `--base` and working-tree modes, build the
diff and truncate at 8000 lines:

```bash
git diff <range> 2>/dev/null | wc -l         # total lines
```

If the diff exceeds 8000 lines, truncate `reviewInput` to the first 8000 and prepend:
`[TRUNCATED: diff is <N> lines; showing first 8000. All changed files listed above.]`
Always pass the complete `changedFiles` list even when the diff is truncated.

## 6. Citation verification pseudocode (main session, deterministic)

Source the reviewer findings from `.comprehensive-code-review/raw/workflow-result.json` (the file the
workflow wrote), not from the Workflow return value.

```
for each finding in workflowResult.reviewers[*].findings:
    if finding.file and finding.line and finding.verbatim (>= 5 chars):
        content = Read(finding.file, offset=max(0, finding.line-2), limit=5)
        if collapse_whitespace(finding.verbatim) in collapse_whitespace(content):
            finding.verification = "ok"
        else:
            finding.verification = "dropped_no_match"   -> move to dropped list
    else:
        finding.verification = "dropped_no_citation"     -> move to dropped list
```

`collapse_whitespace`: replace runs of whitespace (incl. newlines) with a single space, then trim.

Codex emits its findings as narrative review markdown (the companion has no structured findings
schema), so there is no verbatim quote to substring-match. For any `file:line` reference Codex cites,
existence-check only (file exists + line within the file's length); include Codex's findings under
"Adversarial-Codex" and note they are existence-checked, not quote-verified.
