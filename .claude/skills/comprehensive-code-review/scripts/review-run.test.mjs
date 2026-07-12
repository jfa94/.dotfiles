import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "review-run.mjs");

const fixture = (t) => {
  const root = mkdtempSync(path.join(tmpdir(), "review-run-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
};

const init = (root, profile = "focused") =>
  JSON.parse(
    execFileSync(process.execPath, [
      script,
      "init",
      "--repo-root",
      root,
      "--runtime",
      "codex",
      "--profile",
      profile,
      "--mode",
      "working-tree",
      "--scope-label",
      "working tree vs HEAD",
    ]),
  );

test("init atomically creates unique run state and raw directory", (t) => {
  const root = fixture(t);
  const first = init(root);
  const second = init(root);
  assert.notEqual(first.runId, second.runId);
  assert.match(first.runId, /^\d{8}T\d{6}Z-focused-[A-Za-z0-9]{6}$/);
  const state = JSON.parse(readFileSync(path.join(first.runDir, "run.json"), "utf8"));
  assert.equal(state.status, "RUNNING");
  assert.equal(state.runtime, "codex");
  assert.equal(state.runId, first.runId);
  assert.equal(existsSync(path.join(first.runDir, "raw")), true);
});

test("finish records terminal state and rejects a second transition", (t) => {
  const root = fixture(t);
  const run = init(root, "comprehensive");
  const finished = JSON.parse(
    execFileSync(process.execPath, [
      script,
      "finish",
      "--run-dir",
      run.runDir,
      "--status",
      "DONE_WITH_CONCERNS",
      "--report",
      "report.md",
      "--reason",
      "one reviewer blocked",
    ]),
  );
  assert.equal(finished.status, "DONE_WITH_CONCERNS");
  assert.equal(finished.report, "report.md");
  const again = spawnSync(process.execPath, [
    script,
    "finish",
    "--run-dir",
    run.runDir,
    "--status",
    "DONE",
  ]);
  assert.notEqual(again.status, 0);
  assert.match(again.stderr.toString(), /already terminal/);
});

test("invalid enum fails without creating a run", (t) => {
  const root = fixture(t);
  const result = spawnSync(process.execPath, [
    script,
    "init",
    "--repo-root",
    root,
    "--runtime",
    "codex",
    "--profile",
    "quick",
    "--mode",
    "working-tree",
    "--scope-label",
    "test",
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr.toString(), /profile/);
});

test("finish rejects a run outside the canonical artifact tree", (t) => {
  const root = fixture(t);
  const result = spawnSync(process.execPath, [
    script,
    "finish",
    "--run-dir",
    root,
    "--status",
    "ABORTED",
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr.toString(), /canonical/);
});
