import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const sourcePath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "review-fanout.workflow.js",
);

test("stubbed workflow preserves intent/refutation vote semantics and sends docs everywhere", async (t) => {
  const temp = mkdtempSync(path.join(tmpdir(), "review-fanout-"));
  t.after(() => rmSync(temp, { recursive: true, force: true }));
  const runnable = path.join(temp, "workflow.mjs");
  writeFileSync(
    runnable,
    readFileSync(sourcePath, "utf8").replace(
      /return consolidated;\s*$/,
      "globalThis.__workflowResult = consolidated;",
    ),
  );

  const docsManifest = [
    "AGENTS.md",
    "docs/it's $(touch /tmp/should-not-run).md",
    "README.md",
    "(2 more omitted)",
  ].join("\n");
  const finding = (line, title, over = {}) => ({
    severity: "critical",
    file: "src/a.js",
    line,
    verbatim: "const enough = true;",
    title,
    why: "trace",
    ...over,
  });
  const prompts = [];
  globalThis.args = {
    runtime: "claude",
    profile: "focused",
    runId: "20260811T120000Z-focused-Ab12Cd",
    scopeLabel: "working tree vs HEAD",
    mode: "working-tree",
    outDir: ".code-review/runs/20260811T120000Z-focused-Ab12Cd",
    repoRoot: "/tmp/repo",
    claudeMdPath: "/tmp/repo/CLAUDE.md",
    changedFiles: "src/a.js",
    reviewInput: "diff --git a/src/a.js b/src/a.js",
    docsManifest,
    reviewers: [
      { name: "quality-reviewer", role: "Review behavior." },
      { name: "systemic-failure-reviewer", role: "Review cross-stage behavior." },
    ],
    codex: {
      cmd: "/tmp/codex-companion.mjs",
      launcher: "/tmp/codex-launch.mjs",
      targetFlags: "--scope working-tree",
      expectedTarget: { mode: "working-tree" },
    },
  };
  globalThis.log = () => {};
  globalThis.parallel = async (thunks) =>
    Promise.all(
      thunks.map(async (thunk) => {
        try {
          return await thunk();
        } catch {
          return null;
        }
      }),
    );
  globalThis.pipeline = async (items, produce, consume) => {
    const output = [];
    for (const item of items) output.push(await consume(await produce(item)));
    return output;
  };
  globalThis.agent = async (prompt, options) => {
    prompts.push({ prompt, options });
    const label = options.label;
    if (label === "review:quality-reviewer") {
      return {
        status: "DONE",
        findings: [
          finding(2, "two intent votes"),
          finding(4, "mixed votes"),
          finding(6, "documented defect", {
            intent_question: "Should this branch intentionally ignore the failed write?",
          }),
          finding(8, "important refutation", { severity: "important" }),
          finding(10, "reviewer minor question", {
            severity: "minor",
            intent_question: "Should this fallback intentionally return an empty value?",
          }),
        ],
      };
    }
    if (label === "review:systemic-failure-reviewer") {
      return { status: "DONE", findings: [] };
    }
    if (label === "codex:adversarial") {
      return {
        status: "DONE",
        outcome: "structured",
        findings: [
          {
            severity: "low",
            title: "Codex low",
            body: "intent dependent",
            file: "src/a.js",
            line_start: 12,
            line_end: 12,
          },
        ],
        degraded_refs: [],
      };
    }
    if (label.startsWith("verify:codex:")) {
      return {
        refuted: false,
        reason: "No documented policy",
        intent_question: "Should low-severity fallback behavior be intentionally silent?",
      };
    }
    if (label.includes(":2:")) {
      return {
        refuted: false,
        reason: "Undocumented intent",
        intent_question: "Should this operation intentionally accept partial completion?",
      };
    }
    if (label.includes(":4:v1")) {
      return { refuted: true, reason: "Guard refutes it" };
    }
    if (label.includes(":4:v2")) return null;
    if (label.includes(":6:")) {
      return {
        refuted: false,
        reason: "Documented contract",
        doc_basis: "docs/contract.md requires failed writes to surface to callers.",
      };
    }
    if (label.includes(":8")) return { refuted: true, reason: "Caller handles it" };
    if (label.startsWith("persist:codex-verify-result.json")) {
      return { written: true, path: "x", entry_count: 1 };
    }
    if (label.startsWith("persist:workflow-result.json")) {
      return { written: true, path: "x", entry_count: 2, findings_count: 5 };
    }
    throw new Error(`unexpected label ${label}`);
  };

  await import(pathToFileURL(runnable).href + `?${Date.now()}`);
  const findings = globalThis.__workflowResult.reviewers[0].findings;
  const byLine = (line) => findings.find((f) => f.line === line);
  assert.match(byLine(2).intent_question, /partial completion/);
  assert.equal(byLine(4).refuted, undefined); // mixed/null critical votes preserve original
  assert.equal(byLine(4).intent_question, undefined);
  assert.equal(byLine(6).intent_question, undefined);
  assert.match(byLine(6).doc_basis, /failed writes/);
  assert.equal(byLine(8).refuted, true);
  assert.match(byLine(10).intent_question, /fallback intentionally/);
  assert.equal(globalThis.__workflowResult.codex.verifyRan, true); // low was verified

  const classifiedPrompts = prompts.filter(({ options }) =>
    /^(review:|verify:|codex:adversarial$)/.test(options.label),
  );
  assert.ok(classifiedPrompts.length >= 10);
  assert.ok(
    classifiedPrompts
      .filter(({ options }) => options.label !== "codex:adversarial")
      .every(({ prompt }) => prompt.includes(docsManifest)),
  );
  const codexPrompt = prompts.find((p) => p.options.label === "codex:adversarial").prompt;
  assert.match(codexPrompt, /AGENTS\.md/);
  assert.match(codexPrompt, /README\.md/);
  assert.match(codexPrompt, /docs\/it'"'"'s \$\(touch \/tmp\/should-not-run\)\.md/);
});
