# Agent Dispatch Template Reference

## Codex invocation pattern

```bash
# Resolve companion script (latest installed version)
CODEX_CMD=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)

# Resolve furthest-back commit (root commit)
CODEX_BASE=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)

# Launch background review — capture jobId from stdout
CODEX_OUTPUT=$(node "$CODEX_CMD" adversarial-review --background --base "$CODEX_BASE" 2>&1)
CODEX_JOB_ID=$(echo "$CODEX_OUTPUT" | grep -oE 'background as ([a-zA-Z0-9_-]+)' | awk '{print $NF}')

# Poll status
node "$CODEX_CMD" status "$CODEX_JOB_ID" --json 2>/dev/null

# Retrieve result when done
node "$CODEX_CMD" result "$CODEX_JOB_ID" --json 2>/dev/null
```

Codex status JSON shape: `{ "status": "pending|running|done|failed", "progress": "..." }`

Poll timeout: if status is not `done` after 20 minutes, mark Codex as BLOCKED.

## Reviewer Task prompt template

When dispatching each reviewer as a general-purpose subagent, include this structure in the prompt:

```
You are the <REVIEWER_NAME> for a comprehensive code review.

## Your role
<paste full content of agents/<reviewer>.md here>

## Diff to review
Scope: <scope description>
Base ref: <base ref or "working tree vs HEAD">

<paste git diff output here — truncate at 8000 lines if needed, include truncation note>

## Additional context
- CLAUDE.md location: <path if found, else "not found">
- Spec file: <path if --spec provided, else "not applicable">
- Repo root: <absolute path>

## Output requirements
- Follow your Iron Laws exactly.
- End your response with the required STATUS line as the absolute last line.
- Every finding must cite file:line + verbatim quote ≥5 chars.
```

## Diff size management

Before dispatch, check diff size:

```bash
git diff --stat 2>/dev/null | tail -1   # summary line
git diff 2>/dev/null | wc -l            # total lines
```

If diff exceeds 8000 lines:

- Truncate to first 8000 lines
- Add a note at the top of the pasted diff: `[TRUNCATED: diff is <N> lines; showing first 8000]`
- Include the list of all changed files from `git diff --name-only` even if full diff is truncated

## Parallel dispatch rule

**All Task calls + the Codex Bash call must appear in a single assistant message.**

Correct pattern (pseudocode):

```
message = [
  Task(architecture-reviewer prompt),
  Task(quality-reviewer prompt),
  Task(security-reviewer prompt),
  Task(silent-failures prompt),
  Task(test-coverage prompt),
  Task(type-design prompt),
  Task(comment-accuracy prompt),
  Task(simplification prompt),
  Task(documentation-reviewer prompt),
  Task(implementation-reviewer prompt),  # only if --spec provided
  Bash(codex launch, run_in_background=true),  # only if Codex available
]
emit(message)
```

Never emit Task calls sequentially. Never wait for one reviewer before dispatching the next.

## Harvest loop pseudocode

```
# Wait for all Task calls to complete (they run concurrently)
for each reviewer_result in task_results:
    raw_output = reviewer_result.output
    status = extract_last_line(raw_output)  # "STATUS: ..."
    if status missing or malformed:
        mark reviewer as BLOCKED("missing STATUS line")
    else:
        store raw_output to .comprehensive-code-review/raw/<reviewer>-<ts>.md

# Poll Codex separately
if CODEX_JOB_ID:
    wait_for_codex(CODEX_JOB_ID, timeout=20min)
    store codex result to .comprehensive-code-review/raw/codex-adversarial-<ts>.md
```

## Citation verification pseudocode

```
for each finding in all_reviewer_outputs:
    if finding.file and finding.line and finding.verbatim:
        content = Read(finding.file, offset=max(0, finding.line-2), limit=5)
        normalized_quote = collapse_whitespace(finding.verbatim)
        normalized_content = collapse_whitespace(content)
        if normalized_quote not in normalized_content:
            finding.verification = "dropped_no_match"
            move to dropped_findings list
        else:
            finding.verification = "ok"
    else:
        finding.verification = "dropped_no_citation"
        move to dropped_findings list
```

`collapse_whitespace`: replace runs of whitespace (including newlines) with a single space, then trim.

Minimum verbatim length: 5 characters (shorter quotes are too ambiguous to verify).
