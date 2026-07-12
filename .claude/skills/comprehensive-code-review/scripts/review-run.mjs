#!/usr/bin/env node

import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

const VALID_RUNTIME = new Set(["claude", "codex"]);
const VALID_PROFILE = new Set(["focused", "comprehensive"]);
const VALID_MODE = new Set(["working-tree", "base", "full"]);
const VALID_TERMINAL = new Set(["DONE", "DONE_WITH_CONCERNS", "ABORTED"]);
const RUN_ID = /^\d{8}T\d{6}Z-(focused|comprehensive)-[A-Za-z0-9]{6}$/;

const fail = (message) => {
  process.stderr.write(`review-run: ${message}\n`);
  process.exit(1);
};

const parseArgs = (values) => {
  const result = {};
  for (let index = 0; index < values.length; index += 2) {
    const key = values[index];
    const value = values[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail(`invalid arguments near ${key ?? "end of input"}`);
    }
    result[key.slice(2)] = value;
  }
  return result;
};

const required = (args, key) => {
  const value = args[key];
  if (!value) fail(`--${key} is required`);
  return value;
};

const timestamp = () =>
  new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");

const writeJson = (filePath, value) => {
  writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
  });
};

const init = (args) => {
  const repoRoot = path.resolve(required(args, "repo-root"));
  const runtime = required(args, "runtime");
  const profile = required(args, "profile");
  const mode = required(args, "mode");
  const scopeLabel = required(args, "scope-label");
  if (!VALID_RUNTIME.has(runtime)) fail("--runtime must be claude or codex");
  if (!VALID_PROFILE.has(profile)) fail("--profile must be focused or comprehensive");
  if (!VALID_MODE.has(mode)) fail("--mode must be working-tree, base, or full");
  try {
    if (!statSync(repoRoot).isDirectory()) fail("--repo-root must be a directory");
  } catch {
    fail("--repo-root must be an existing directory");
  }

  const runsRoot = path.join(repoRoot, ".code-review", "runs");
  mkdirSync(runsRoot, { recursive: true });
  const runDir = mkdtempSync(path.join(runsRoot, `${timestamp()}-${profile}-`));
  const runId = path.basename(runDir);
  mkdirSync(path.join(runDir, "raw"));
  const state = {
    runtime,
    profile,
    runId,
    scopeLabel,
    mode,
    startedAt: new Date().toISOString(),
    status: "RUNNING",
  };
  writeJson(path.join(runDir, "run.json"), state);
  process.stdout.write(`${JSON.stringify({ ...state, runDir })}\n`);
};

const finish = (args) => {
  const runDir = path.resolve(required(args, "run-dir"));
  const status = required(args, "status");
  if (!VALID_TERMINAL.has(status)) {
    fail("--status must be DONE, DONE_WITH_CONCERNS, or ABORTED");
  }
  const runId = path.basename(runDir);
  if (
    !RUN_ID.test(runId) ||
    path.basename(path.dirname(runDir)) !== "runs" ||
    path.basename(path.dirname(path.dirname(runDir))) !== ".code-review"
  ) {
    fail("--run-dir must be a canonical .code-review/runs/<runId> directory");
  }
  if (args.report && args.report !== "report.md") fail("--report must be report.md");
  const statePath = path.join(runDir, "run.json");
  let current;
  try {
    current = JSON.parse(readFileSync(statePath, "utf8"));
  } catch (error) {
    fail(`cannot read run.json: ${error.message}`);
  }
  if (current.runId !== runId) fail("run.json identity does not match --run-dir");
  if (current.status !== "RUNNING") fail(`run is already terminal: ${current.status}`);
  const next = {
    ...current,
    completedAt: new Date().toISOString(),
    status,
  };
  if (args.report) next.report = args.report;
  if (args.reason) next.reason = args.reason;
  writeFileSync(statePath, `${JSON.stringify(next, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify({ ...next, runDir })}\n`);
};

const [command, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);
if (command === "init") init(args);
else if (command === "finish") finish(args);
else fail("command must be init or finish");
