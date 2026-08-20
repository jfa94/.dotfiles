# Harvest Recovery (load only when workflow-result.json is missing, stale, or unparseable)

You are here because `<runDir>/raw/workflow-result.json` failed the five-field staleness guard
(`runtime`, `profile`, `runId`, `scopeLabel`, `mode`), is missing, or does not parse. Reconstruct
from the run's journal before declaring reviewers BLOCKED.

## Journal fallback

The Workflow tool result named the run's `runId` and transcript directory;
`<transcript dir>/journal.jsonl` records every agent's structured return as
`{"type":"result", ..., "result": <object>}` lines. Reviewer results echo `name`, refuter
verdicts echo `file`/`line` — rebuild
`{ runtime, profile, runId, scopeLabel, mode, reviewers: [...] }` (with this run's actual
runtime/profile values) by taking each reviewer's result record and applying refuter verdicts as
`refuted`/`refute_reason` (criticals are dropped-as-refuted only when BOTH of their two verdicts
refute; importants on one).

Apply the same vote thresholds to mutually exclusive intent annotations: for criticals, two
`intent_question` votes create a question and two verified `doc_basis` objects clear a reviewer
question; for importants, one vote is enough. Existing documentation evidence is never demoted by
refuter votes. Refutation wins when its threshold is met. Mixed, missing, contradictory, or
malformed votes preserve the reviewer's original classification, and a reviewer-authored question
is never replaced by a refuter's differently worded question.

This pairing is **best-effort, not deterministic** — the journal has no record of an agent's
`label`, only the schema-optional `file`/`line` echo, so if a verdict omits it or matches more
than one finding (two reviewers flagging the same site), leave that finding unrefuted rather than
guess; a mis-paired refutation can then at worst let a refuted finding survive, never drop a real
one.

The codex-runner's structured return is in the journal too — rebuild the `codex` key from it (its
record carries `status`/`outcome`/`degraded_refs`; set `verifyRan` true only if `verify:codex:*`
verdicts appear). Write the reconstruction to `workflow-result.json` and continue the normal
harvest.

## Last resort (journal also missing/unusable)

Mark every dispatched reviewer BLOCKED("workflow-result.json missing/stale and journal
unavailable") and `codex` BLOCKED("workflow died before the codex track resolved") — but first, if
`<runDir>/raw/codex-adversarial.json` exists, salvage what the CLI wrote by applying the gates and
routing yourself:

1. **Gate A — validity/crash:** file missing/empty/not valid JSON, or `payload.target` absent →
   BLOCKED (companion crash — see `codex-adversarial.stderr.log`).
2. **Gate B — staleness:** `payload.target` must match the `expectedTarget` you launched with,
   else BLOCKED (stale/foreign): base / `--full` → `target.mode === "branch"` AND `target.baseRef`
   resolving to `expectedTarget.baseSha`. **`baseRef` is untrusted external output — regex-validate
   `^[A-Za-z0-9._/@{}~^-]+$` before passing it to any git command, and compare resolved SHAs, not
   spellings.** Working-tree → `target.mode === "working-tree"`.
3. **Route on `result`:** non-null object with a `findings` array → Codex DONE,
   `outcome: "structured"`. Otherwise existence-check any `file:line` references parsed from
   `payload.rawOutput`: ≥1 recovered → Codex DONE, `outcome: "degraded"` with the recovered refs
   as `degraded_refs` (the report must carry the mandatory degraded note); zero recovered →
   Codex BLOCKED.
