export const meta = {
  name: "comprehensive-review-fanout",
  description:
    "Fan out specialist code reviewers in parallel; adversarially verify critical/important findings with fresh refuter agents; persist the consolidated findings to a file the calling skill reads (the JS return value is not harvestable).",
  phases: [
    {
      title: "Review",
      detail: "one specialist reviewer agent per dimension, run concurrently",
    },
    {
      title: "Verify",
      detail:
        "one fresh refuter agent per critical/important finding (claim + location only, no reasoning chain)",
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
// NOTE: the Verify stage annotates findings post-validation with `refuted` +
// `refute_reason`; those fields are intentionally NOT in this schema (it
// validates reviewer output, not the workflow's own annotations).
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
          file: { type: "string", minLength: 1 },
          line: { type: "integer", minimum: 1 },
          verbatim: { type: "string", minLength: 5 },
          title: { type: "string" },
          why: { type: "string" },
          fix_sketch: { type: "string" },
          // Systemic findings (systemic-failure-reviewer only) set the four fields below.
          // Local reviewers never emit `kind` and fall through as local — unchanged behaviour.
          // Intentionally NOT in `required` (same pattern as the `refuted`/`refute_reason`
          // workflow annotations at the top of this file).
          kind: { enum: ["local", "systemic"] },
          failure_mode: {
            enum: [
              "stuck-state",
              "invariant-without-repair",
              "unsafe-recovery",
              "over-pinned-contract",
            ],
          },
          scenario: { type: "string", minLength: 1 },
          anchors: {
            type: "array",
            minItems: 2,
            items: {
              type: "object",
              additionalProperties: false,
              required: ["file", "line", "verbatim"],
              properties: {
                file: { type: "string", minLength: 1 },
                line: { type: "integer", minimum: 1 },
                verbatim: { type: "string", minLength: 5 },
                role: { type: "string" },
              },
            },
          },
        },
      },
    },
  },
};

const VERIFY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["refuted", "reason"],
  properties: {
    refuted: { type: "boolean" },
    reason: { type: "string", minLength: 1 },
  },
};

// Reviewers that audit current state rather than the change itself; sending
// them the diff only dilutes their context (LLM detection degrades as
// non-relevant context grows).
const DIFFLESS_REVIEWERS = new Set(["documentation-reviewer"]);

// ponytail: gates on mode=full (the existing value); no new flag or arg parsing needed.
const TEMPORAL_REVIEWERS = new Set(["quality-reviewer"]);

function buildPrompt(reviewer, ctx) {
  const specBlock = ctx.spec
    ? ["", "## Spec file: " + ctx.spec.path, "", ctx.spec.content, ""].join(
        "\n",
      )
    : "";
  const reviewInput = DIFFLESS_REVIEWERS.has(reviewer.name)
    ? "No diff provided for this role — audit the current state against the changed-files list above; Read files as needed."
    : ctx.reviewInput;
  const parts = [
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
    reviewInput,
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
    'Systemic findings (systemic-failure-reviewer only) additionally set kind="systemic", failure_mode, scenario, and anchors[] (≥2 entries, each with file+line+verbatim); all other reviewers leave these fields unset.',
  ];
  if (ctx.mode === "full" && TEMPORAL_REVIEWERS.has(reviewer.name)) {
    parts.push(
      "",
      "## Temporal reasoning (--full mode)",
      "For every retry, reset, or recovery path in the diff: when it re-runs on the same input that caused the original failure, does it change the condition that failed — or just re-derive the same state and hit the same failure again? Flag any recovery that reproduces the original failure on unchanged input, whether it spins forever or gives up after a fixed number of tries. That is a no-op recovery, not self-healing.",
    );
  }
  return parts.join("\n");
}

// Adversarial verification: the refuter sees only the claim + location — NOT
// the reviewer's `why` reasoning chain — so it evaluates the claim on its own
// terms instead of being anchored by the reviewer's argument.
// For systemic findings the refuter also sees every anchor + the scenario and
// is asked to BREAK THE CHAIN rather than just refute a single site.
function buildVerifyPrompt(reviewerName, f) {
  if (f.kind === "systemic") {
    const anchorLines = (f.anchors || [])
      .map(
        (a, i) =>
          "  Anchor " +
          (i + 1) +
          ": " +
          a.file +
          ":" +
          a.line +
          " — `" +
          a.verbatim +
          "`" +
          (a.role ? " (" + a.role + ")" : ""),
      )
      .join("\n");
    return [
      "You are an adversarial verifier for ONE systemic code-review finding. A " +
        reviewerName +
        " claims:",
      "",
      "- Title: " + f.title,
      "- Severity: " + f.severity,
      "- Failure mode: " + (f.failure_mode || "unset"),
      "- Scenario: " + (f.scenario || "(none)"),
      "- Primary location: " +
        f.file +
        ":" +
        f.line +
        " — `" +
        f.verbatim +
        "`",
      "- All anchors:",
      anchorLines,
      "",
      "BREAK THE CHAIN: refute if ANY of the following holds:",
      "  1. An anchor quote does not appear at (or within ±2 lines of) the stated file:line.",
      "  2. A claimed state transition in the scenario is not supported by the code (a guard, branch, or caller makes it impossible).",
      "  3. A repair/exit path the reviewer missed resolves the stuck state — name the path.",
      "",
      "Read every anchored file around the stated lines, then trace the scenario end-to-end.",
      "Set refuted=true ONLY if you found concrete counter-evidence — quote it (file:line) in reason.",
      "If the chain holds, set refuted=false and state in reason what you verified at each anchor.",
    ].join("\n");
  }
  return [
    "You are an adversarial verifier for ONE code-review finding. A " +
      reviewerName +
      " claims:",
    "",
    "- Title: " + f.title,
    "- Severity: " + f.severity,
    "- Location: " + f.file + ":" + f.line,
    "- Quoted code: " + f.verbatim,
    "",
    "Your job is to REFUTE this claim if you can. Read " +
      f.file +
      " around line " +
      f.line +
      " and whatever code is needed to follow the claim (callers, callees, guards, types).",
    "Look for: handling the reviewer missed, a misreading of the code, preconditions that make the issue impossible, or the claim describing intended/documented behavior.",
    "",
    "Set refuted=true ONLY if you found concrete counter-evidence — quote it (file:line) in reason.",
    "If the claim stands, or you cannot find counter-evidence, set refuted=false and state in reason what you checked.",
  ].join("\n");
}

// The Workflow runtime may hand `args` to the script as a JSON string rather
// than a parsed object; normalize so the caller can pass args either way.
const input = typeof args === "string" ? JSON.parse(args) : args || {};

const reviewers = Array.isArray(input.reviewers) ? input.reviewers : [];
if (reviewers.length === 0) {
  log("No reviewers supplied in args.reviewers — nothing to dispatch.");
  return { reviewers: [] };
}

// pipeline, not parallel: each reviewer's findings go to verification as soon
// as that reviewer finishes — no barrier waiting on the slowest reviewer.
const results = await pipeline(
  reviewers,
  (r) =>
    agent(buildPrompt(r, input), {
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
  async (res) => {
    if (!res || res.status !== "DONE") return res;
    const toVerify = (res.findings || []).filter(
      (f) => f.severity === "critical" || f.severity === "important",
    );
    if (toVerify.length === 0) return res;
    const verdicts = await parallel(
      toVerify.map(
        (f) => () =>
          agent(buildVerifyPrompt(res.name, f), {
            label: "verify:" + res.name + ":" + f.file + ":" + f.line,
            phase: "Verify",
            schema: VERIFY_SCHEMA,
          }),
      ),
    );
    // A null verdict (verifier skipped/died) keeps the finding — verification
    // failure must not silently delete a reviewer's finding.
    verdicts.forEach((v, i) => {
      if (v && v.refuted) {
        toVerify[i].refuted = true;
        toVerify[i].refute_reason = v.reason;
      }
    });
    return res;
  },
);

// Stamp the run's scope into the result so the skill can detect a stale file
// (a prior run's leftover) rather than silently accepting it as the current run.
const consolidated = {
  scopeLabel: input.scopeLabel || null,
  mode: input.mode || null,
  reviewers: results.filter(Boolean),
};

// A workflow's JS `return` value is NOT retrievable by the calling skill
// (TaskOutput is deprecated; the task-notification carries only prose). The
// script itself has no filesystem access, so dispatch ONE agent (which has
// Write) to persist the consolidated findings to a fixed path the skill reads.
// Findings caps keep this payload small, so verbatim transcription is reliable;
// the agent reads the file back to confirm it parses before returning.
const repoRoot = input.repoRoot || ".";
// outDir lets a derived skill (e.g. quick-code-review) persist to its own dir;
// default preserves the comprehensive skill's path.
const outDir = input.outDir || ".comprehensive-code-review";
const outPath = repoRoot + "/" + outDir + "/raw/workflow-result.json";
const payload = JSON.stringify(consolidated, null, 2);
// Collision-proof delimiter: extend the marker until it cannot occur inside the
// payload, so a verbatim finding quote that happens to contain the literal marker
// (e.g. when this skill reviews its own source) can't truncate the extracted text.
let marker = "WORKFLOW_RESULT_PAYLOAD";
while (payload.includes(marker)) marker += "_X";
const openTag = "<" + marker + ">";
const closeTag = "</" + marker + ">";
await agent(
  [
    "You persist a code-review result to disk. Do NOT modify, summarize, reformat, or add commentary to the content.",
    "",
    "Steps:",
    "1. Ensure the parent directory exists (create " +
      repoRoot +
      "/" +
      outDir +
      "/raw/ if missing).",
    "2. Write the file at this absolute path: " + outPath,
    "   Its ENTIRE contents must be EXACTLY the text between the " +
      openTag +
      " and " +
      closeTag +
      " markers below (exclude the markers themselves).",
    "3. Read the file back; confirm it parses as JSON and the top-level object has a `reviewers` array.",
    "",
    "Return written=true only if the read-back parsed successfully; set reviewer_count to the length of the reviewers array.",
    "",
    openTag,
    payload,
    closeTag,
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
