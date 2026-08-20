import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
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
  const sentinel = path.join(temp, "shell-injection-ran");
  const launcher = path.join(temp, "fake-launcher.mjs");
  const capturedArgs = path.join(temp, "launcher-args.json");
  const workflowSource = readFileSync(sourcePath, "utf8");
  // Runtime-compat regression guard: the Workflow runtime forbids these
  // globals/APIs (non-deterministic or filesystem access outside its sandbox).
  for (const forbidden of [
    /\bnew TextEncoder\b/,
    /\bDate\.now\b/,
    /\bMath\.random\b/,
    /\brequire\(\s*["']node:fs/,
    /\bfrom\s+["']node:fs/,
  ]) {
    assert.doesNotMatch(
      workflowSource,
      forbidden,
      `workflow source must not use ${forbidden} (forbidden in Workflow runtime)`,
    );
  }
  writeFileSync(
    launcher,
    `import { writeFileSync } from "node:fs"; writeFileSync(${JSON.stringify(capturedArgs)}, JSON.stringify(process.argv.slice(2)));`,
  );
  writeFileSync(
    runnable,
    workflowSource.replace(
      /return consolidated;\s*$/,
      "globalThis.__workflowResult = consolidated;",
    ),
  );

  const runDir = "/tmp/repo/.code-review/runs/20260811T120000Z-focused-Ab12Cd";
  const docsManifestPath = `${runDir}/raw/inputs/docs it's $(touch ${sentinel}).txt`;
  const changeContextPath = `${runDir}/raw/inputs/change-context.json`;
  const changedFilesPath = `${runDir}/raw/changed-files.txt`;
  const reviewInputPath = `${runDir}/raw/inputs/review-input.txt`;
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
    inputs: {
      claudeMdPath: "/tmp/repo/CLAUDE.md",
      changedFilesPath,
      reviewInputPath,
      docsManifestPath,
      changeContextPath,
      dispositionsPath: `${runDir}/raw/inputs/dispositions.txt`,
      specPath: null,
    },
    reviewers: [
      { name: "quality-reviewer", charterPath: "/tmp/charters/quality-reviewer.md" },
      {
        name: "systemic-failure-reviewer",
        charterPath: "/tmp/charters/systemic-failure-reviewer.md",
      },
      {
        name: "documentation-reviewer",
        charterPath: "/tmp/charters/documentation-reviewer.md",
      },
    ],
    codex: {
      cmd: "/tmp/codex-companion.mjs",
      launcher,
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
    if (label === "review:documentation-reviewer") {
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
        doc_basis: {
          file: "docs/contract.md",
          line: 7,
          verbatim: "Failed writes must surface to callers.",
        },
      };
    }
    if (label.includes(":8")) return { refuted: true, reason: "Caller handles it" };
    if (label.startsWith("persist:codex-verify-result.json")) {
      return { written: true, path: "x", entry_count: 1 };
    }
    if (label.startsWith("persist:workflow-result.json")) {
      return { written: true, path: "x", entry_count: 3, findings_count: 5 };
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
  assert.deepEqual(byLine(6).doc_basis, {
    file: "docs/contract.md",
    line: 7,
    verbatim: "Failed writes must surface to callers.",
  });
  assert.equal(byLine(6).doc_basis_required, 2);
  assert.equal(byLine(8).refuted, true);
  assert.match(byLine(10).intent_question, /fallback intentionally/);
  assert.equal(globalThis.__workflowResult.codex.verifyRan, true); // low was verified
  assert.ok(prompts.some((p) => p.options.label === "verify:codex:src/a.js:12"));

  const classifiedPrompts = prompts.filter(({ options }) =>
    /^(review:|verify:|codex:adversarial$)/.test(options.label),
  );
  assert.ok(classifiedPrompts.length >= 10);
  assert.ok(
    classifiedPrompts
      .filter(({ options }) => options.label !== "codex:adversarial")
      .every(({ prompt }) => prompt.includes(docsManifestPath)),
  );
  assert.ok(classifiedPrompts.every(({ prompt }) => prompt.includes(changeContextPath)));
  const qualityPrompt = prompts.find(
    (p) => p.options.label === "review:quality-reviewer",
  ).prompt;
  assert.match(qualityPrompt, /quality-reviewer\.md/);
  assert.ok(qualityPrompt.includes(changedFilesPath));
  assert.ok(qualityPrompt.includes(reviewInputPath));
  const docsPrompt = prompts.find(
    (p) => p.options.label === "review:documentation-reviewer",
  ).prompt;
  assert.ok(docsPrompt.includes(changedFilesPath));
  assert.equal(docsPrompt.includes(reviewInputPath), false);
  const reviewerSchema = prompts.find((p) => p.options.label === "review:quality-reviewer").options
    .schema.properties.findings.items;
  assert.deepEqual(reviewerSchema.allOf, [
    { not: { required: ["intent_question", "doc_basis"] } },
  ]);
  // Top-level oneOf/allOf/anyOf are rejected by the API for tool input
  // schemas; exclusivity is enforced in applyVerificationVotes instead.
  const refuterSchema = prompts.find((p) => p.options.label.includes(":2:")).options.schema;
  for (const key of ["allOf", "oneOf", "anyOf"]) {
    assert.equal(key in refuterSchema, false, `refuter schema has top-level ${key}`);
  }
  assert.equal(refuterSchema.properties.intent_question.minLength, 10);
  const codexRunnerSchema = prompts.find((p) => p.options.label === "codex:adversarial").options
    .schema.properties.findings.items.properties;
  assert.equal("intent_question" in codexRunnerSchema, false);
  assert.equal("doc_basis" in codexRunnerSchema, false);
  const codexPrompt = prompts.find((p) => p.options.label === "codex:adversarial").prompt;
  assert.match(codexPrompt, /docs it/);
  assert.ok(codexPrompt.includes(changeContextPath));
  const commandStart = codexPrompt.indexOf("  node '");
  const commandEnd = codexPrompt.indexOf("\n\nThe launcher", commandStart);
  const command = codexPrompt
    .slice(commandStart, commandEnd)
    .trim()
    .replace(/\\\n\s*/g, " ");
  execFileSync("sh", ["-c", command]);
  const launcherArgs = JSON.parse(readFileSync(capturedArgs, "utf8"));
  assert.deepEqual(launcherArgs.slice(-3, -1), ["--scope", "working-tree"]);
  assert.ok(launcherArgs.at(-1).includes(docsManifestPath));
  assert.ok(launcherArgs.at(-1).includes(changeContextPath));
  assert.equal(existsSync(sentinel), false);

  const validArgs = globalThis.args;
  assert.ok(
    Buffer.byteLength(JSON.stringify({ scriptPath: sourcePath, args: validArgs })) <= 8192,
  );
  globalThis.args = { ...validArgs, reviewInput: "legacy inline diff" };
  await assert.rejects(
    import(pathToFileURL(runnable).href + `?legacy-inline-${Date.now()}`),
    /obsolete inline input/,
  );
  globalThis.args = {
    ...validArgs,
    inputs: { ...validArgs.inputs, reviewInputPath: "relative.txt" },
  };
  await assert.rejects(
    import(pathToFileURL(runnable).href + `?relative-input-${Date.now()}`),
    /reviewInputPath.*absolute path/,
  );
  globalThis.args = validArgs;
});

function baseArgs(overrides = {}) {
  const runDir = "/tmp/repo/.code-review/runs/20260811T120000Z-focused-Ab12Cd";
  return {
    runtime: "claude",
    profile: "focused",
    runId: "20260811T120000Z-focused-Ab12Cd",
    scopeLabel: "working tree vs HEAD",
    mode: "working-tree",
    outDir: ".code-review/runs/20260811T120000Z-focused-Ab12Cd",
    repoRoot: "/tmp/repo",
    inputs: {
      claudeMdPath: null,
      changedFilesPath: `${runDir}/raw/changed-files.txt`,
      reviewInputPath: `${runDir}/raw/inputs/review-input.txt`,
      docsManifestPath: null,
      changeContextPath: null,
      dispositionsPath: null,
      specPath: null,
    },
    reviewers: [],
    codex: null,
    ...overrides,
  };
}

function setupGlobals() {
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
}

function writeRunnable(temp) {
  const runnable = path.join(temp, "workflow.mjs");
  const workflowSource = readFileSync(sourcePath, "utf8");
  writeFileSync(
    runnable,
    workflowSource.replace(
      /return consolidated;\s*$/,
      "globalThis.__workflowResult = consolidated;",
    ),
  );
  return runnable;
}

test("shell-quoting: codex-runner command args with hostile characters arrive literally", async (t) => {
  const temp = mkdtempSync(path.join(tmpdir(), "review-fanout-quote-"));
  t.after(() => rmSync(temp, { recursive: true, force: true }));
  const runnable = writeRunnable(temp);
  const sentinel = path.join(temp, "shell-injection-ran");
  // Node's ESM loader itself rejects a script path containing a raw
  // backslash (ERR_INVALID_MODULE_SPECIFIER) regardless of shell quoting, so
  // the launcher's own filename stays free of "\" — the backslash case is
  // covered below via the companion/output-path arguments instead.
  const launcher = path.join(temp, "fake launcher's `dir` $(x).mjs");
  const capturedArgs = path.join(temp, "launcher-args.json");
  writeFileSync(
    launcher,
    `import { writeFileSync } from "node:fs"; writeFileSync(${JSON.stringify(capturedArgs)}, JSON.stringify(process.argv.slice(2)));`,
  );

  const hostile = (label) => `/tmp/repo/it's ${label} \`backtick\` $(touch ${sentinel}) back\\slash dir`;
  const cmdPath = hostile("cmd");

  const prompts = [];
  setupGlobals();
  globalThis.args = baseArgs({
    inputs: { ...baseArgs().inputs },
    reviewers: [],
    repoRoot: hostile("root"),
    codex: {
      cmd: cmdPath,
      launcher,
      targetFlags: "--scope working-tree",
      expectedTarget: { mode: "working-tree" },
    },
  });
  // Just record + return a plausible result here — the actual shell exec and
  // assertions happen after import() resolves (below), so a real failure in
  // the extracted command fails the test loudly instead of being swallowed by
  // runCodexTrack's retry-then-BLOCKED error handling.
  globalThis.agent = async (prompt, options) => {
    prompts.push({ prompt, options });
    if (options.label === "codex:adversarial") {
      return { status: "DONE", outcome: "structured", findings: [], degraded_refs: [] };
    }
    if (options.label.startsWith("persist:")) return { written: true, path: "x", entry_count: 0 };
    throw new Error(`unexpected label ${options.label}`);
  };
  await import(pathToFileURL(runnable).href + `?quote-${Date.now()}`);
  const codexPrompt = prompts.find((p) => p.options.label === "codex:adversarial").prompt;
  const commandStart = codexPrompt.indexOf("  node '");
  const commandEnd = codexPrompt.indexOf("\n\nThe launcher", commandStart);
  const command = codexPrompt
    .slice(commandStart, commandEnd)
    .trim()
    .replace(/\\\n\s*/g, " ");
  execFileSync("sh", ["-c", command]);
  const launcherArgs = JSON.parse(readFileSync(capturedArgs, "utf8"));
  // node <launcher> --companion <cmd> --json-out <path> --stderr-out <path> --pid-file <path> -- <flags...>
  assert.equal(launcherArgs[1], cmdPath);
  assert.ok(launcherArgs[3].startsWith(hostile("root")));
  assert.equal(existsSync(sentinel), false, "no sentinel — no shell substitution ran");
});
