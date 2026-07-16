#!/usr/bin/env node

// codex-launch.mjs — idempotent launcher-waiter for the Codex adversarial-review CLI.
//
// Why: the codex-runner is a workflow subagent. Background-task completion
// notifications never reach workflow subagents, and subagent teardown kills
// their tracked background Bash tasks — so the companion must run OS-detached
// (its own session, untracked by the harness) while the agent waits in plain
// FOREGROUND Bash calls. This script owns both halves: the first invocation
// spawns the companion detached and writes a pidfile; every invocation
// (including re-runs after a Bash tool timeout) attaches to the pidfile and
// waits. A pidfile means never spawn again, so re-running is always safe.
//
// stdout is a pure token channel: EXITED | STILL_RUNNING pid=<n> | TIMEOUT pid=<n>.
// Diagnostics go to stderr. Exit codes: 0 EXITED/STILL_RUNNING, 2 TIMEOUT,
// 1 usage error / corrupt pidfile / spawn failure. TIMEOUT never kills the
// review — the pid is surfaced for manual cleanup and a later Gate A salvage.
//
// Known residual: the spawn→pidfile-write window is sub-ms; a runner killed
// exactly there could double-spawn on retry, producing interleaved JSON that
// Gate A rejects visibly (never silently). Accepted.

import { closeSync, existsSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import path from "node:path";

const fail = (message) => {
  process.stderr.write(`codex-launch: ${message}\n`);
  process.exit(1);
};

const splitAt = process.argv.indexOf("--");
const flagValues = splitAt === -1 ? process.argv.slice(2) : process.argv.slice(2, splitAt);
const targetFlags = splitAt === -1 ? [] : process.argv.slice(splitAt + 1);

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

const args = parseArgs(flagValues);

const required = (key) => {
  const value = args[key];
  if (!value) fail(`--${key} is required`);
  return value;
};

const positiveInt = (key, fallback) => {
  if (!(key in args)) return fallback;
  const value = Number(args[key]);
  if (!Number.isInteger(value) || value <= 0) fail(`--${key} must be a positive integer`);
  return value;
};

const companion = path.resolve(required("companion"));
const jsonOut = path.resolve(required("json-out"));
const stderrOut = path.resolve(required("stderr-out"));
const pidFile = path.resolve(required("pid-file"));
const maxWaitMs = positiveInt("max-wait-ms", 540000);
const deadlineMs = positiveInt("deadline-ms", 2400000);
const pollIntervalMs = positiveInt("poll-interval-ms", 2000);
if (targetFlags.length === 0) {
  fail("target flags after -- are required (--base <ref> | --scope working-tree)");
}

let record;
if (existsSync(pidFile)) {
  try {
    record = JSON.parse(readFileSync(pidFile, "utf8"));
  } catch {
    record = null;
  }
  if (!record || !Number.isInteger(record.pid) || record.pid <= 0 || !Number.isFinite(record.startedAt)) {
    fail(`pid-file is corrupt: ${pidFile}`);
  }
} else {
  if (!existsSync(companion)) fail(`--companion not found: ${companion}`);
  const jsonFd = openSync(jsonOut, "w");
  const errFd = openSync(stderrOut, "w");
  let child;
  try {
    // Same detach pattern as the codex plugin's own task worker/broker:
    // detached + fd stdio + unref survives the caller's teardown.
    child = spawn(process.execPath, [companion, "adversarial-review", "--json", ...targetFlags], {
      detached: true,
      stdio: ["ignore", jsonFd, errFd],
    });
  } catch (error) {
    fail(`spawn failed: ${error.message}`);
  } finally {
    closeSync(jsonFd);
    closeSync(errFd);
  }
  if (!child.pid) fail("spawn failed: no pid");
  record = { pid: child.pid, startedAt: Date.now() };
  writeFileSync(pidFile, `${JSON.stringify(record)}\n`);
  child.unref();
  process.stderr.write(`codex-launch: spawned pid ${record.pid}\n`);
}

// Any throw counts as exited: ESRCH means the pid is gone; EPERM means it was
// recycled to a foreign-uid process (our child is same-uid), so also gone.
const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const invokedAt = Date.now();
while (alive(record.pid)) {
  if (Date.now() - record.startedAt > deadlineMs) {
    process.stdout.write(`TIMEOUT pid=${record.pid}\n`);
    process.exit(2);
  }
  if (Date.now() - invokedAt > maxWaitMs) {
    process.stdout.write(`STILL_RUNNING pid=${record.pid}\n`);
    process.exit(0);
  }
  await sleep(pollIntervalMs);
}
process.stdout.write("EXITED\n");
