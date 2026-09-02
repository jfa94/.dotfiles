import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { validateWorkflowLaunch } from "./validate-workflow-launch.mjs";

const CODEX_CACHE_ROOT_ENV = "VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillDir = path.dirname(scriptDir);
const workflowPath = path.join(scriptDir, "review-fanout.workflow.js");
const validatorPath = path.join(scriptDir, "validate-workflow-launch.mjs");
const launcherPath = path.join(scriptDir, "codex-launch.mjs");
const profiles = JSON.parse(
  readFileSync(path.join(skillDir, "references", "reviewer-profiles.json"), "utf8"),
);

function fakeCodexCache(t) {
  const cacheRoot = mkdtempSync(path.join(tmpdir(), "codex-cache-"));
  const previous = process.env[CODEX_CACHE_ROOT_ENV];
  t.after(() => {
    rmSync(cacheRoot, { recursive: true, force: true });
    if (previous === undefined) delete process.env[CODEX_CACHE_ROOT_ENV];
    else process.env[CODEX_CACHE_ROOT_ENV] = previous;
  });
  process.env[CODEX_CACHE_ROOT_ENV] = cacheRoot;
  const scriptsDir = path.join(cacheRoot, "1.2.3", "scripts");
  mkdirSync(scriptsDir, { recursive: true });
  const cmd = path.join(scriptsDir, "codex-companion.mjs");
  writeFileSync(cmd, "export {};\n");
  return { cacheRoot, cmd };
}

function fixture(t, profile = "focused", withSpec = false) {
  const repoRoot = mkdtempSync(path.join(tmpdir(), "workflow-launch-"));
  t.after(() => rmSync(repoRoot, { recursive: true, force: true }));
  const runId = `20260814T120000Z-${profile}-Ab12Cd`;
  const outDir = `.code-review/runs/${runId}`;
  const runDir = path.join(repoRoot, outDir);
  const inputsDir = path.join(runDir, "raw", "inputs");
  mkdirSync(inputsDir, { recursive: true });
  const write = (relative, content = "fixture\n") => {
    const target = path.join(runDir, relative);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, content);
    return target;
  };
  const claudeMdPath = path.join(repoRoot, "CLAUDE.md");
  writeFileSync(claudeMdPath, "# Instructions\n");
  const names = [...profiles[profile]];
  const specPath = withSpec ? write("raw/inputs/spec", "# Spec\n") : null;
  if (withSpec) names.push("implementation-reviewer");
  const { cmd: codexCmd } = fakeCodexCache(t);
  const args = {
    runtime: "claude",
    profile,
    runId,
    scopeLabel: "working tree vs HEAD",
    mode: "working-tree",
    repoRoot,
    outDir,
    inputs: {
      reviewInputPath: write("raw/inputs/review-input.txt"),
      changedFilesPath: write("raw/changed-files.txt", "src/a.js\n"),
      docsManifestPath: write("raw/inputs/docs-manifest.txt", "CLAUDE.md\n"),
      changeContextPath: write(
        "raw/inputs/change-context.json",
        '[{"source":"request","text":"review it"}]\n',
      ),
      dispositionsPath: write("raw/inputs/dispositions.txt"),
      specPath,
      claudeMdPath,
    },
    reviewers: names.map((name) => ({
      name,
      charterPath: path.join(skillDir, "agents", `${name}.md`),
    })),
    codex: {
      cmd: codexCmd,
      launcher: launcherPath,
      targetFlags: "--scope working-tree",
      expectedTarget: { mode: "working-tree" },
    },
  };
  return { repoRoot, runDir, args, toolInput: { scriptPath: workflowPath, args } };
}

test("allows compact focused and comprehensive bundled launches", (t) => {
  for (const [profile, withSpec] of [
    ["focused", false],
    ["comprehensive", true],
  ]) {
    const { toolInput } = fixture(t, profile, withSpec);
    assert.ok(Buffer.byteLength(JSON.stringify(toolInput)) <= 8192);
    assert.deepEqual(validateWorkflowLaunch(toolInput), { applies: true, allowed: true });
  }
});

test("rejects roster, path, launcher, and payload regressions", (t) => {
  const { repoRoot, args, toolInput } = fixture(t);

  const badRoster = structuredClone(toolInput);
  badRoster.args.reviewers[0].name = "quality-reviewer";
  assert.match(validateWorkflowLaunch(badRoster).reason, /canonical charter|roster/);

  const outsidePath = path.join(repoRoot, "outside.txt");
  writeFileSync(outsidePath, "outside\n");
  const badInput = structuredClone(toolInput);
  badInput.args.inputs.reviewInputPath = outsidePath;
  assert.match(validateWorkflowLaunch(badInput).reason, /current run directory/);

  const badLauncher = structuredClone(toolInput);
  badLauncher.args.codex.launcher = args.codex.cmd;
  assert.match(validateWorkflowLaunch(badLauncher).reason, /bundled launcher/);

  writeFileSync(args.inputs.changeContextPath, '[{"source":"unknown","text":"x"}]\n');
  assert.match(validateWorkflowLaunch(toolInput).reason, /invalid or oversized context/);
  writeFileSync(
    args.inputs.changeContextPath,
    '[{"source":"request","text":"review it"}]\n',
  );

  const oversized = structuredClone(toolInput);
  oversized.args.scopeLabel = "x".repeat(9000);
  assert.match(validateWorkflowLaunch(oversized).reason, /exceeds 8192 bytes/);
});

test("rejects codex.cmd outside the installed plugin cache layout", (t) => {
  const { repoRoot, toolInput } = fixture(t);

  const arbitraryRepoFile = path.join(repoRoot, "codex-companion.mjs");
  writeFileSync(arbitraryRepoFile, "export {};\n");
  const arbitrary = structuredClone(toolInput);
  arbitrary.args.codex.cmd = arbitraryRepoFile;
  assert.match(validateWorkflowLaunch(arbitrary).reason, /codex\.cmd must be/);

  const { cacheRoot } = fakeCodexCache(t);
  const wrongBasenamePath = path.join(cacheRoot, "1.2.3", "scripts", "not-codex.mjs");
  writeFileSync(wrongBasenamePath, "export {};\n");
  const wrongBasename = structuredClone(toolInput);
  wrongBasename.args.codex.cmd = wrongBasenamePath;
  assert.match(validateWorkflowLaunch(wrongBasename).reason, /codex\.cmd must be/);

  const wrongDepthDir = path.join(cacheRoot, "1.2.3");
  mkdirSync(wrongDepthDir, { recursive: true });
  const wrongDepthPath = path.join(wrongDepthDir, "codex-companion.mjs");
  writeFileSync(wrongDepthPath, "export {};\n");
  const wrongDepth = structuredClone(toolInput);
  wrongDepth.args.codex.cmd = wrongDepthPath;
  assert.match(validateWorkflowLaunch(wrongDepth).reason, /codex\.cmd must be/);

  const missingScriptsDir = path.join(cacheRoot, "1.2.3", "other", "nested");
  mkdirSync(missingScriptsDir, { recursive: true });
  const missingScriptsPath = path.join(missingScriptsDir, "codex-companion.mjs");
  writeFileSync(missingScriptsPath, "export {};\n");
  const missingScripts = structuredClone(toolInput);
  missingScripts.args.codex.cmd = missingScriptsPath;
  assert.match(validateWorkflowLaunch(missingScripts).reason, /codex\.cmd must be/);

  const outsideCacheDir = mkdtempSync(path.join(tmpdir(), "codex-escape-"));
  t.after(() => rmSync(outsideCacheDir, { recursive: true, force: true }));
  const escapeTarget = path.join(outsideCacheDir, "codex-companion.mjs");
  writeFileSync(escapeTarget, "export {};\n");
  const symlinkScriptsDir = path.join(cacheRoot, "9.9.9", "scripts");
  mkdirSync(symlinkScriptsDir, { recursive: true });
  const symlinkPath = path.join(symlinkScriptsDir, "codex-companion.mjs");
  symlinkSync(escapeTarget, symlinkPath);
  const escaping = structuredClone(toolInput);
  escaping.args.codex.cmd = symlinkPath;
  assert.match(validateWorkflowLaunch(escaping).reason, /codex\.cmd must be/);
});

test("distinguishes a missing run directory from a run path that is a file", (t) => {
  const { repoRoot, toolInput } = fixture(t);

  const missingRunDir = structuredClone(toolInput);
  missingRunDir.args.runId = "20260814T120000Z-focused-Zz99Yy";
  missingRunDir.args.outDir = `.code-review/runs/${missingRunDir.args.runId}`;
  assert.match(validateWorkflowLaunch(missingRunDir).reason, /run directory does not exist/);

  const runsDir = path.join(repoRoot, ".code-review", "runs");
  mkdirSync(runsDir, { recursive: true });
  const fileRunId = "20260814T120000Z-focused-Ff11Gg";
  const fileRunPath = path.join(runsDir, fileRunId);
  writeFileSync(fileRunPath, "not a directory\n");
  const runIsFile = structuredClone(toolInput);
  runIsFile.args.runId = fileRunId;
  runIsFile.args.outDir = `.code-review/runs/${fileRunId}`;
  assert.match(
    validateWorkflowLaunch(runIsFile).reason,
    /run directory path is not a directory/,
  );
});

test("provenance pinning: launch-args.json must deep-equal args when present", (t) => {
  const { runDir, args, toolInput } = fixture(t);
  const launchArgsPath = path.join(runDir, "raw", "inputs", "launch-args.json");

  // absent file → backwards-compatible allow (covered again explicitly here)
  assert.deepEqual(validateWorkflowLaunch(toolInput), { applies: true, allowed: true });

  // matching content in different key order / formatting → still allowed
  const reordered = { codex: args.codex, inputs: args.inputs, ...args };
  writeFileSync(launchArgsPath, JSON.stringify(reordered, null, 4));
  assert.deepEqual(validateWorkflowLaunch(toolInput), { applies: true, allowed: true });

  // drifted value → denied
  const drifted = structuredClone(args);
  drifted.scopeLabel = "something else";
  writeFileSync(launchArgsPath, `${JSON.stringify(drifted, null, 2)}\n`);
  assert.match(validateWorkflowLaunch(toolInput).reason, /launch-args\.json/);

  // corrupt provenance record → denied, never silently skipped
  writeFileSync(launchArgsPath, "{not json");
  assert.match(validateWorkflowLaunch(toolInput).reason, /launch-args\.json/);
});

test("leaves unrelated workflows undecided and emits hook decisions", (t) => {
  const { toolInput } = fixture(t);
  assert.deepEqual(validateWorkflowLaunch({ scriptPath: "/tmp/other.workflow.js", args: {} }), {
    applies: false,
  });

  const allowed = spawnSync(process.execPath, [validatorPath], {
    input: JSON.stringify({ tool_name: "Workflow", tool_input: toolInput }),
    encoding: "utf8",
  });
  assert.equal(allowed.status, 0);
  assert.equal(
    JSON.parse(allowed.stdout).hookSpecificOutput.permissionDecision,
    "allow",
  );

  const unrelated = spawnSync(process.execPath, [validatorPath], {
    input: JSON.stringify({
      tool_name: "Workflow",
      tool_input: { scriptPath: "/tmp/other.workflow.js", args: {} },
    }),
    encoding: "utf8",
  });
  assert.equal(unrelated.status, 0);
  assert.equal(unrelated.stdout, "");
});

test("denies review launches that bypass the bundled script", (t) => {
  const { args, toolInput } = fixture(t);
  const copyDir = mkdtempSync(path.join(tmpdir(), "workflow-copy-"));
  t.after(() => rmSync(copyDir, { recursive: true, force: true }));
  const copyPath = path.join(copyDir, "review-fanout.workflow.js");
  writeFileSync(copyPath, readFileSync(workflowPath));

  const copied = validateWorkflowLaunch({ scriptPath: copyPath, args });
  assert.equal(copied.applies, true);
  assert.equal(copied.allowed, false);
  assert.match(copied.reason, /bundled review-fanout\.workflow\.js/);

  const inline = validateWorkflowLaunch({ script: "export const meta = {};", args });
  assert.deepEqual({ applies: inline.applies, allowed: inline.allowed }, { applies: true, allowed: false });

  assert.deepEqual(validateWorkflowLaunch({ scriptPath: "/tmp/other.workflow.js", args: {} }), {
    applies: false,
  });

  const denied = spawnSync(process.execPath, [validatorPath], {
    input: JSON.stringify({ tool_name: "Workflow", tool_input: { ...toolInput, scriptPath: copyPath } }),
    encoding: "utf8",
  });
  assert.equal(denied.status, 0);
  assert.equal(JSON.parse(denied.stdout).hookSpecificOutput.permissionDecision, "deny");
});
