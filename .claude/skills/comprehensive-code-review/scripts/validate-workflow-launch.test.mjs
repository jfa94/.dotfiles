import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { validateWorkflowLaunch } from "./validate-workflow-launch.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillDir = path.dirname(scriptDir);
const workflowPath = path.join(scriptDir, "review-fanout.workflow.js");
const validatorPath = path.join(scriptDir, "validate-workflow-launch.mjs");
const launcherPath = path.join(scriptDir, "codex-launch.mjs");
const profiles = JSON.parse(
  readFileSync(path.join(skillDir, "references", "reviewer-profiles.json"), "utf8"),
);

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
  const codexCmd = path.join(repoRoot, "codex-companion.mjs");
  writeFileSync(codexCmd, "export {};\n");
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
