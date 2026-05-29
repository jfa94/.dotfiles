export const meta = {
  name: "comprehensive-review-fanout",
  description:
    "Fan out specialist code reviewers in parallel; each is forced into one canonical findings schema. Persists the consolidated findings to a file the calling skill reads (the JS return value is not harvestable).",
  phases: [
    {
      title: "Review",
      detail: "one specialist reviewer agent per dimension, run concurrently",
    },
    {
      title: "Persist",
      detail:
        "one agent writes the consolidated findings JSON to a file the skill reads",
    },
  ],
};

// Canonical output shape EVERY reviewer is forced into. Replaces each agent's
// bespoke JSON block + prose verdict fallback + STATUS line. The schema layer
// validates and retries on mismatch, so `verbatim` length and severity enum are
// enforced here rather than by hand-written parser rules downstream.
const FINDINGS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["status", "findings"],
  properties: {
    status: { enum: ["DONE", "BLOCKED"] },
    blocked_reason: { type: "string" },
    verdict: { type: "string" },
    findings: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["severity", "file", "line", "verbatim", "title", "why"],
        properties: {
          severity: { enum: ["critical", "important", "minor"] },
          file: { type: "string" },
          line: { type: "integer" },
          verbatim: { type: "string", minLength: 5 },
          title: { type: "string" },
          why: { type: "string" },
          fix_sketch: { type: "string" },
        },
      },
    },
  },
};

function buildPrompt(reviewer, ctx) {
  const specBlock = ctx.spec
    ? ["", "## Spec file: " + ctx.spec.path, "", ctx.spec.content, ""].join(
        "\n",
      )
    : "";
  return [
    "You are the " + reviewer.name + " for a comprehensive code review.",
    "",
    "## Your role",
    "",
    reviewer.role,
    "",
    "## What to review",
    "",
    "Scope: " + ctx.scopeLabel,
    "",
    "Changed files:",
    ctx.changedFiles,
    "",
    ctx.reviewInput,
    "",
    "## Context",
    "- Repo root: " + ctx.repoRoot,
    "- CLAUDE.md: " + ctx.claudeMdPath,
    specBlock,
    "## Output",
    "Return structured output matching the provided schema — do NOT emit a STATUS line or a prose verdict block.",
    "Every finding MUST include file + line + a verbatim quote (>=5 characters copied exactly from the code at that line). Drop any finding you cannot quote.",
    'If you genuinely cannot perform the review, return status "BLOCKED" with a one-line blocked_reason and an empty findings array. Otherwise return status "DONE".',
    "Respect your role's findings cap; drop the low-signal tail by likelihood x impact.",
  ].join("\n");
}

const reviewers = Array.isArray(args && args.reviewers) ? args.reviewers : [];
if (reviewers.length === 0) {
  log("No reviewers supplied in args.reviewers — nothing to dispatch.");
  return { reviewers: [] };
}

phase("Review");
const results = await parallel(
  reviewers.map(
    (r) => () =>
      agent(buildPrompt(r, args), {
        label: "review:" + r.name,
        phase: "Review",
        schema: FINDINGS_SCHEMA,
      })
        .then((res) =>
          res
            ? Object.assign({ name: r.name }, res)
            : {
                name: r.name,
                status: "BLOCKED",
                blocked_reason: "agent returned no output (skipped)",
                findings: [],
              },
        )
        .catch((e) => ({
          name: r.name,
          status: "BLOCKED",
          blocked_reason: String((e && e.message) || e),
          findings: [],
        })),
  ),
);

const consolidated = { reviewers: results.filter(Boolean) };

// A workflow's JS `return` value is NOT retrievable by the calling skill
// (TaskOutput is deprecated; the task-notification carries only prose). The
// script itself has no filesystem access, so dispatch ONE agent (which has
// Write) to persist the consolidated findings to a fixed path the skill reads.
// Findings caps keep this payload small, so verbatim transcription is reliable;
// the agent reads the file back to confirm it parses before returning.
phase("Persist");
const repoRoot = (args && args.repoRoot) || ".";
const outPath =
  repoRoot + "/.comprehensive-code-review/raw/workflow-result.json";
const payload = JSON.stringify(consolidated, null, 2);
await agent(
  [
    "You persist a code-review result to disk. Do NOT modify, summarize, reformat, or add commentary to the content.",
    "",
    "Steps:",
    "1. Ensure the parent directory exists (create " +
      repoRoot +
      "/.comprehensive-code-review/raw/ if missing).",
    "2. Write the file at this absolute path: " + outPath,
    "   Its ENTIRE contents must be EXACTLY the text between the <CONTENT> and </CONTENT> markers below (exclude the markers themselves).",
    "3. Read the file back; confirm it parses as JSON and the top-level object has a `reviewers` array.",
    "",
    "Return written=true only if the read-back parsed successfully; set reviewer_count to the length of the reviewers array.",
    "",
    "<CONTENT>",
    payload,
    "</CONTENT>",
  ].join("\n"),
  {
    label: "persist:workflow-result",
    phase: "Persist",
    schema: {
      type: "object",
      additionalProperties: false,
      required: ["written", "path"],
      properties: {
        written: { type: "boolean" },
        path: { type: "string" },
        reviewer_count: { type: "integer" },
      },
    },
  },
);

return consolidated;
