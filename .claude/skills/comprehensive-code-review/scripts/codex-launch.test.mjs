import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "codex-launch.mjs");

const fixture = (t) => {
  const root = mkdtempSync(path.join(tmpdir(), "codex-launch-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
};

// Fake companions append their pid to spawns.log on start — the single-spawn assertion.
const writeCompanion = (root, body) => {
  const companion = path.join(root, "companion.mjs");
  writeFileSync(
    companion,
    `import { appendFileSync } from "node:fs";\n` +
      `appendFileSync(${JSON.stringify(path.join(root, "spawns.log"))}, process.pid + "\\n");\n` +
      body,
  );
  return companion;
};

const spawnCount = (root) => {
  const log = path.join(root, "spawns.log");
  return existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").length : 0;
};

const launch = (root, companion, extra = []) =>
  spawnSync(
    process.execPath,
    [
      script,
      "--companion", companion,
      "--json-out", path.join(root, "codex-adversarial.json"),
      "--stderr-out", path.join(root, "codex-adversarial.stderr.log"),
      "--pid-file", path.join(root, "codex.pid"),
      "--poll-interval-ms", "50",
      ...extra,
      "--", "--scope", "working-tree",
    ],
    { encoding: "utf8" },
  );

test("spawns detached, waits, prints EXITED with intact json", (t) => {
  const root = fixture(t);
  const companion = writeCompanion(
    root,
    `setTimeout(() => console.log('{"target":{"mode":"working-tree"}}'), 200);\n`,
  );
  const result = launch(root, companion);
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), "EXITED");
  assert.deepEqual(JSON.parse(readFileSync(path.join(root, "codex-adversarial.json"), "utf8")), {
    target: { mode: "working-tree" },
  });
  assert.equal(existsSync(path.join(root, "codex.pid")), true);
  assert.equal(spawnCount(root), 1);
});

test("re-invocation attaches instead of respawning, then EXITED", (t) => {
  const root = fixture(t);
  const companion = writeCompanion(root, `setTimeout(() => console.log("{}"), 2000);\n`);
  const first = launch(root, companion, ["--max-wait-ms", "200"]);
  assert.equal(first.status, 0);
  assert.match(first.stdout, /^STILL_RUNNING pid=\d+$/m);
  const pid = JSON.parse(readFileSync(path.join(root, "codex.pid"), "utf8")).pid;
  const second = launch(root, companion, ["--max-wait-ms", "200"]);
  assert.match(second.stdout, /^STILL_RUNNING pid=\d+$/m);
  assert.equal(JSON.parse(readFileSync(path.join(root, "codex.pid"), "utf8")).pid, pid);
  assert.equal(spawnCount(root), 1);
  const third = launch(root, companion, ["--max-wait-ms", "10000"]);
  assert.equal(third.stdout.trim(), "EXITED");
  assert.equal(spawnCount(root), 1);
});

test("re-invocation after exit prints EXITED immediately without respawn", (t) => {
  const root = fixture(t);
  const companion = writeCompanion(root, `console.log("{}");\n`);
  assert.equal(launch(root, companion).stdout.trim(), "EXITED");
  const again = launch(root, companion);
  assert.equal(again.status, 0);
  assert.equal(again.stdout.trim(), "EXITED");
  assert.equal(spawnCount(root), 1);
});

test("detached companion survives the launcher being SIGKILLed mid-wait", async (t) => {
  const root = fixture(t);
  const companion = writeCompanion(root, `setTimeout(() => console.log("{}"), 2000);\n`);
  const launcher = spawn(
    process.execPath,
    [
      script,
      "--companion", companion,
      "--json-out", path.join(root, "codex-adversarial.json"),
      "--stderr-out", path.join(root, "codex-adversarial.stderr.log"),
      "--pid-file", path.join(root, "codex.pid"),
      "--poll-interval-ms", "50",
      "--", "--scope", "working-tree",
    ],
    { stdio: "ignore" },
  );
  const pidFile = path.join(root, "codex.pid");
  for (let i = 0; i < 100 && !existsSync(pidFile); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(existsSync(pidFile), true);
  const pid = JSON.parse(readFileSync(pidFile, "utf8")).pid;
  launcher.kill("SIGKILL");
  assert.doesNotThrow(() => process.kill(pid, 0)); // companion still alive
  const resumed = launch(root, companion, ["--max-wait-ms", "10000"]);
  assert.equal(resumed.stdout.trim(), "EXITED");
  assert.equal(readFileSync(path.join(root, "codex-adversarial.json"), "utf8").trim(), "{}");
  assert.equal(spawnCount(root), 1);
});

test("crashing companion still yields EXITED; stderr captured for Gate A", (t) => {
  const root = fixture(t);
  const companion = writeCompanion(root, `process.stderr.write("boom\\n"); process.exit(1);\n`);
  const result = launch(root, companion);
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), "EXITED");
  assert.equal(readFileSync(path.join(root, "codex-adversarial.json"), "utf8"), "");
  assert.match(readFileSync(path.join(root, "codex-adversarial.stderr.log"), "utf8"), /boom/);
});

test("deadline exceeded prints TIMEOUT, exit 2, never kills the review", async (t) => {
  const root = fixture(t);
  const companion = writeCompanion(root, `setTimeout(() => console.log("{}"), 60000);\n`);
  const bystander = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000);"], {
    stdio: "ignore",
  });
  t.after(() => bystander.kill("SIGKILL"));
  writeFileSync(
    path.join(root, "codex.pid"),
    `${JSON.stringify({ pid: bystander.pid, startedAt: Date.now() - 9999999 })}\n`,
  );
  const result = launch(root, companion);
  assert.equal(result.status, 2);
  assert.equal(result.stdout.trim(), `TIMEOUT pid=${bystander.pid}`);
  assert.doesNotThrow(() => process.kill(bystander.pid, 0)); // still alive
});

test("usage errors and corrupt pidfile fail with exit 1 and codex-launch: message", (t) => {
  const root = fixture(t);
  const companion = writeCompanion(root, `console.log("{}");\n`);
  const missingFlag = spawnSync(
    process.execPath,
    [script, "--companion", companion, "--", "--scope", "working-tree"],
    { encoding: "utf8" },
  );
  assert.equal(missingFlag.status, 1);
  assert.match(missingFlag.stderr, /codex-launch: --json-out is required/);

  const noTarget = spawnSync(
    process.execPath,
    [
      script,
      "--companion", companion,
      "--json-out", path.join(root, "j"),
      "--stderr-out", path.join(root, "e"),
      "--pid-file", path.join(root, "p"),
    ],
    { encoding: "utf8" },
  );
  assert.equal(noTarget.status, 1);
  assert.match(noTarget.stderr, /codex-launch: target flags after -- are required/);

  writeFileSync(path.join(root, "codex.pid"), "garbage");
  const corrupt = launch(root, companion);
  assert.equal(corrupt.status, 1);
  assert.match(corrupt.stderr, /codex-launch: pid-file is corrupt/);
});
