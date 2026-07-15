import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
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

// --- disposition subcommand + pass-number ---

const dispositionCmd = (root, over = {}) => {
  const args = {
    "repo-root": root,
    file: "src/upload.ts",
    title: "TOCTOU between stat and rename",
    status: "accepted-risk",
    reason: "single-writer topology",
    ...over,
  };
  return execFileSync(process.execPath, [
    script,
    "disposition",
    ...Object.entries(args).flatMap(([k, v]) => [`--${k}`, v]),
  ]);
};

const readLedger = (root) =>
  JSON.parse(
    readFileSync(path.join(root, ".code-review", "dispositions.json"), "utf8"),
  );

test("disposition creates ledger with id 1 and normalized repo-relative file", (t) => {
  const root = fixture(t);
  const out = JSON.parse(
    dispositionCmd(root, {
      file: path.join(root, "src", "upload.ts"),
      keywords: "toctou, rename ,stat",
    }),
  );
  assert.equal(out.id, 1);
  const ledger = readLedger(root);
  assert.equal(ledger.version, 1);
  assert.equal(ledger.dispositions.length, 1);
  assert.equal(ledger.dispositions[0].fingerprint.file, "src/upload.ts");
  assert.deepEqual(ledger.dispositions[0].fingerprint.keywords, [
    "toctou",
    "rename",
    "stat",
  ]);
  assert.equal(ledger.dispositions[0].decidedBy, "caller");
  assert.ok(ledger.dispositions[0].decidedAt);
});

test("disposition upserts on same file + normalized title, appends on new title", (t) => {
  const root = fixture(t);
  dispositionCmd(root);
  const upserted = JSON.parse(
    dispositionCmd(root, {
      title: "TOCTOU: between stat and RENAME!!", // same normalized title
      status: "overturned",
      reason: "new evidence: multi-writer deploy",
      "decided-by": "report",
    }),
  );
  assert.equal(upserted.id, 1);
  assert.equal(upserted.status, "overturned");
  assert.equal(upserted.decidedBy, "report");
  const appended = JSON.parse(dispositionCmd(root, { title: "other claim" }));
  assert.equal(appended.id, 2);
  assert.equal(readLedger(root).dispositions.length, 2);
});

test("disposition rejects bad status, empty title, file outside repo, corrupt ledger", (t) => {
  const root = fixture(t);
  const attempt = (over) =>
    spawnSync(process.execPath, [
      script,
      "disposition",
      ...Object.entries({
        "repo-root": root,
        file: "src/a.ts",
        title: "t",
        status: "accepted-risk",
        reason: "r",
        ...over,
      }).flatMap(([k, v]) => [`--${k}`, v]),
    ]);
  assert.match(attempt({ status: "fixed" }).stderr.toString(), /--status/);
  assert.match(attempt({ title: "  !! " }).stderr.toString(), /--title/);
  assert.match(attempt({ file: "../escape.ts" }).stderr.toString(), /--file/);
  assert.match(
    attempt({ "decided-by": "nobody" }).stderr.toString(),
    /--decided-by/,
  );
  mkdirSync(path.join(root, ".code-review"), { recursive: true });
  writeFileSync(path.join(root, ".code-review", "dispositions.json"), "{ bad");
  const corrupt = attempt({});
  assert.notEqual(corrupt.status, 0);
  assert.match(corrupt.stderr.toString(), /dispositions\.json/);
});

test("init records passNumber: default 1, explicit value, rejects invalid", (t) => {
  const root = fixture(t);
  const readState = (run) =>
    JSON.parse(readFileSync(path.join(run.runDir, "run.json"), "utf8"));
  assert.equal(readState(init(root)).passNumber, 1);
  const withPass = JSON.parse(
    execFileSync(process.execPath, [
      script,
      "init",
      "--repo-root",
      root,
      "--runtime",
      "claude",
      "--profile",
      "focused",
      "--mode",
      "base",
      "--scope-label",
      "s",
      "--pass-number",
      "3",
    ]),
  );
  assert.equal(readState(withPass).passNumber, 3);
  for (const bad of ["0", "1.5", "x"]) {
    const result = spawnSync(process.execPath, [
      script,
      "init",
      "--repo-root",
      root,
      "--runtime",
      "claude",
      "--profile",
      "focused",
      "--mode",
      "base",
      "--scope-label",
      "s",
      "--pass-number",
      bad,
    ]);
    assert.notEqual(result.status, 0, bad);
    assert.match(result.stderr.toString(), /--pass-number/);
  }
});
