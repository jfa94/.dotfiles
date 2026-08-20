import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
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

import { validateChangeContext, validateWorkflowLaunch } from "./validate-workflow-launch.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(scriptDir, "review-preflight.mjs");
const workflowPath = path.join(scriptDir, "review-fanout.workflow.js");
const CODEX_CACHE_ROOT_ENV = "VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT";

const git = (root, ...args) =>
  execFileSync("git", ["-C", root, "-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    encoding: "utf8",
  });

function repo(t) {
  const root = mkdtempSync(path.join(tmpdir(), "preflight-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  git(root, "init", "-q");
  writeFileSync(path.join(root, "src.js"), "const a = 1;\n");
  git(root, "add", ".");
  git(root, "commit", "-qm", "initial");
  return root;
}

function run(root, extra = [], { input = "", expectFail = false } = {}) {
  const res = spawnSync(
    process.execPath,
    [script, "--repo-root", root, ...extra],
    { input, encoding: "utf8" },
  );
  if (expectFail) assert.notEqual(res.status, 0, res.stdout + res.stderr);
  else assert.equal(res.status, 0, res.stdout + res.stderr);
  const lines = res.stdout.trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
}

function fakeCodexCache(t, versions = ["1.2.3", "1.10.0"]) {
  const cacheRoot = mkdtempSync(path.join(tmpdir(), "preflight-codex-"));
  t.after(() => rmSync(cacheRoot, { recursive: true, force: true }));
  const cmds = {};
  for (const v of versions) {
    const dir = path.join(cacheRoot, v, "scripts");
    mkdirSync(dir, { recursive: true });
    cmds[v] = path.join(dir, "codex-companion.mjs");
    writeFileSync(cmds[v], "export {};\n");
  }
  return { cacheRoot, cmds };
}

test("working-tree mode gathers tracked+untracked, applies EXCLUDES, and welds to the hook", (t) => {
  const root = repo(t);
  mkdirSync(path.join(root, "dist"));
  writeFileSync(path.join(root, "dist", "bundle.js"), "generated\n");
  git(root, "add", "dist/bundle.js");
  git(root, "commit", "-qm", "add dist");
  writeFileSync(path.join(root, "src.js"), "const a = 2;\n");
  writeFileSync(path.join(root, "dist", "bundle.js"), "generated2\n");
  writeFileSync(path.join(root, "new.js"), "const b = 3;\n");
  writeFileSync(path.join(root, "CLAUDE.md"), "# rules\n");

  const { cacheRoot } = fakeCodexCache(t);
  const out = run(root, ["--profile", "focused", "--request-stdin", "--codex-cache-root", cacheRoot], {
    input: "Please review my change",
  });
  assert.equal(out.status, "ok");
  assert.equal(out.workflowArgs.mode, "working-tree");
  assert.equal(out.workflowArgs.profile, "focused");
  assert.equal(out.workflowArgs.runtime, "claude");
  assert.equal(out.workflowArgs.outDir, `.code-review/runs/${out.runId}`);
  assert.equal(out.manifestMode, false);

  const changed = readFileSync(out.workflowArgs.inputs.changedFilesPath, "utf8");
  assert.match(changed, /^src\.js$/m);
  assert.match(changed, /^new\.js$/m);
  assert.doesNotMatch(changed, /dist\/bundle\.js/);

  const reviewInput = readFileSync(out.workflowArgs.inputs.reviewInputPath, "utf8");
  assert.match(reviewInput, /const a = 2;/);
  assert.match(reviewInput, /Untracked files/);
  assert.doesNotMatch(reviewInput, /generated2/);

  const ctx = JSON.parse(readFileSync(out.workflowArgs.inputs.changeContextPath, "utf8"));
  assert.deepEqual(ctx[0], { source: "request", text: "Please review my change" });
  validateChangeContext(out.workflowArgs.inputs.changeContextPath);

  assert.equal(out.workflowArgs.inputs.claudeMdPath, path.join(root, "CLAUDE.md"));
  assert.deepEqual(
    out.workflowArgs.reviewers.map((r) => r.name),
    [
      "security-reviewer",
      "quality-reviewer",
      "simplification-reviewer",
      "silent-failure-hunter",
      "systemic-failure-reviewer",
    ],
  );

  // launch-args.json is the provenance record the hook pins against.
  const launchArgs = JSON.parse(
    readFileSync(path.join(out.runDir, "raw", "inputs", "launch-args.json"), "utf8"),
  );
  assert.deepEqual(launchArgs, out.workflowArgs);

  // Round-trip weld: the hook must accept exactly what the preflight emits.
  const prev = process.env[CODEX_CACHE_ROOT_ENV];
  process.env[CODEX_CACHE_ROOT_ENV] = cacheRoot;
  t.after(() => {
    if (prev === undefined) delete process.env[CODEX_CACHE_ROOT_ENV];
    else process.env[CODEX_CACHE_ROOT_ENV] = prev;
  });
  assert.ok(Buffer.byteLength(JSON.stringify(out.workflowArgs)) <= 8192);
  assert.deepEqual(
    validateWorkflowLaunch({ scriptPath: workflowPath, args: out.workflowArgs }),
    { applies: true, allowed: true },
  );
  assert.equal(out.workflowArgs.codex.targetFlags, "--scope working-tree");
  assert.deepEqual(out.workflowArgs.codex.expectedTarget, { mode: "working-tree" });
});

test("empty working tree stops before creating a run", (t) => {
  const root = repo(t);
  const out = run(root, ["--profile", "focused"]);
  assert.equal(out.status, "empty");
  assert.equal(existsSync(path.join(root, ".code-review")), false);
});

test("base mode diffs against the ref and includes commit messages in changeContext", (t) => {
  const root = repo(t);
  const base = git(root, "rev-parse", "HEAD").trim();
  writeFileSync(path.join(root, "feature.js"), "export const f = 1;\n");
  git(root, "add", ".");
  git(root, "commit", "-qm", "Add feature X");

  const out = run(root, ["--profile", "focused", "--base", base]);
  assert.equal(out.status, "ok");
  assert.equal(out.workflowArgs.mode, "base");
  assert.match(out.scopeLabel, new RegExp(base.slice(0, 7)));
  const changed = readFileSync(out.workflowArgs.inputs.changedFilesPath, "utf8");
  assert.match(changed, /^feature\.js$/m);
  assert.doesNotMatch(changed, /^src\.js$/m);
  const ctx = JSON.parse(readFileSync(out.workflowArgs.inputs.changeContextPath, "utf8"));
  const commits = ctx.find((e) => e.source === "commit-messages");
  assert.match(commits.text, /Add feature X/);
});

test("clean base range stops empty; unknown or unsafe base ref errors before init", (t) => {
  const root = repo(t);
  const head = git(root, "rev-parse", "HEAD").trim();
  const out = run(root, ["--profile", "focused", "--base", head]);
  assert.equal(out.status, "empty");
  assert.equal(existsSync(path.join(root, ".code-review")), false);

  const bad = run(root, ["--profile", "focused", "--base", "no-such-ref"], { expectFail: true });
  assert.equal(bad.status, "error");
  const unsafe = run(root, ["--profile", "focused", "--base", "bad ref;rm"], { expectFail: true });
  assert.equal(unsafe.status, "error");
  assert.equal(existsSync(path.join(root, ".code-review")), false);
});

test("diff over 2000 lines switches to a never-truncated risk-ranked manifest", (t) => {
  const root = repo(t);
  mkdirSync(path.join(root, "api"));
  writeFileSync(path.join(root, "api", "auth.js"), "let s = 0;\n");
  writeFileSync(path.join(root, "big.js"), "// base\n");
  git(root, "add", ".");
  git(root, "commit", "-qm", "seed files");
  writeFileSync(path.join(root, "api", "auth.js"), "let s = 1;\nlet t = 2;\n");
  writeFileSync(
    path.join(root, "big.js"),
    Array.from({ length: 2500 }, (_, i) => `const line${i} = ${i};`).join("\n") + "\n",
  );

  const out = run(root, ["--profile", "focused"]);
  assert.equal(out.status, "ok");
  assert.equal(out.manifestMode, true);
  const patchPath = path.join(out.runDir, "raw", "full-diff.patch");
  const expected = git(
    root,
    "diff",
    "HEAD",
    "--",
    ".",
    ":(top,exclude,glob).code-review/**",
  );
  assert.equal(readFileSync(patchPath, "utf8"), expected);

  const reviewInput = readFileSync(out.workflowArgs.inputs.reviewInputPath, "utf8");
  assert.match(reviewInput, /full-diff\.patch/);
  assert.match(reviewInput, /Read ALL of it/);
  assert.doesNotMatch(reviewInput, /const line42 = 42;/);
  // security-sensitive path ranks above the merely-large change
  const authRow = reviewInput.indexOf("api/auth.js");
  const bigRow = reviewInput.indexOf("big.js");
  assert.ok(authRow !== -1 && bigRow !== -1 && authRow < bigRow);
});

test("focused ignores --full and --spec with a warning", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 9;\n");
  writeFileSync(path.join(root, "spec.md"), "# spec\n");
  const out = run(root, ["--profile", "focused", "--full", "--spec", path.join(root, "spec.md")]);
  assert.equal(out.status, "ok");
  assert.equal(out.workflowArgs.mode, "working-tree");
  assert.equal(out.workflowArgs.inputs.specPath, null);
  assert.ok(out.warnings.some((w) => /--full/.test(w)));
  assert.ok(out.warnings.some((w) => /--spec/.test(w)));
});

test("comprehensive --full sends the inventory with hotspot priority", (t) => {
  const root = repo(t);
  const out = run(root, ["--profile", "comprehensive", "--full"]);
  assert.equal(out.status, "ok");
  assert.equal(out.workflowArgs.mode, "full");
  const changed = readFileSync(out.workflowArgs.inputs.changedFilesPath, "utf8");
  assert.match(changed, /^src\.js$/m);
  const reviewInput = readFileSync(out.workflowArgs.inputs.reviewInputPath, "utf8");
  assert.match(reviewInput, /ENTIRE codebase/i);
  assert.match(reviewInput, /hotspot/i);
  // full mode Codex window: <=30 commits clamps to the root commit
  const { cacheRoot } = fakeCodexCache(t, ["2.0.0"]);
  const withCodex = run(root, ["--profile", "comprehensive", "--full", "--codex-cache-root", cacheRoot]);
  const rootSha = git(root, "rev-list", "--max-parents=0", "HEAD").trim();
  assert.equal(withCodex.workflowArgs.codex.targetFlags, `--base ${rootSha}`);
  assert.equal(withCodex.workflowArgs.codex.expectedTarget.baseSha, rootSha);
  assert.equal(withCodex.workflowArgs.codex.expectedTarget.mode, "branch");
});

test("comprehensive --spec snapshots the spec and appends implementation-reviewer", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 5;\n");
  writeFileSync(path.join(root, "spec.md"), "# the spec\n");
  const out = run(root, ["--profile", "comprehensive", "--spec", path.join(root, "spec.md")]);
  assert.equal(out.status, "ok");
  assert.equal(readFileSync(out.workflowArgs.inputs.specPath, "utf8"), "# the spec\n");
  assert.equal(out.workflowArgs.reviewers.at(-1).name, "implementation-reviewer");

  const missing = run(root, ["--profile", "comprehensive", "--spec", path.join(root, "nope.md")]);
  assert.equal(missing.status, "ok");
  assert.equal(missing.workflowArgs.inputs.specPath, null);
  assert.ok(missing.workflowArgs.reviewers.every((r) => r.name !== "implementation-reviewer"));
  assert.ok(missing.skipped.some((s) => /spec file not found/.test(s)));
});

test("docs manifest orders instruction files first and caps at 50 paths", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "CLAUDE.md"), "# rules\n");
  writeFileSync(path.join(root, "README.md"), "# readme\n");
  mkdirSync(path.join(root, "docs"));
  writeFileSync(path.join(root, "docs", "guide.md"), "# guide\n");
  mkdirSync(path.join(root, "notes"));
  for (let i = 0; i < 55; i += 1) {
    writeFileSync(path.join(root, "notes", `n${String(i).padStart(2, "0")}.md`), "note\n");
  }
  git(root, "add", ".");
  git(root, "commit", "-qm", "docs");
  writeFileSync(path.join(root, "src.js"), "const a = 4;\n");

  const out = run(root, ["--profile", "focused"]);
  const manifest = readFileSync(out.workflowArgs.inputs.docsManifestPath, "utf8");
  const lines = manifest.trim().split("\n");
  assert.equal(lines[0], "CLAUDE.md");
  assert.equal(lines[1], "README.md");
  assert.equal(lines[2], "docs/guide.md");
  assert.equal(lines.length, 51);
  assert.match(lines[50], /^\(\d+ more omitted\)$/);
});

test("no markdown at all yields a null docs manifest", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 8;\n");
  const out = run(root, ["--profile", "focused"]);
  assert.equal(out.workflowArgs.inputs.docsManifestPath, null);
});

test("changeContext rejects protected or repo-escaping --context files and caps at 8KiB", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 6;\n");
  writeFileSync(path.join(root, ".env"), "SECRET=x\n");
  const secret = run(root, ["--profile", "focused", "--context", path.join(root, ".env")], {
    expectFail: true,
  });
  assert.equal(secret.status, "error");

  const outside = mkdtempSync(path.join(tmpdir(), "outside-"));
  t.after(() => rmSync(outside, { recursive: true, force: true }));
  writeFileSync(path.join(outside, "ctx.txt"), "context\n");
  const escaping = run(
    root,
    ["--profile", "focused", "--context", path.join(outside, "ctx.txt")],
    { expectFail: true },
  );
  assert.equal(escaping.status, "error");

  const big = run(root, ["--profile", "focused", "--request-stdin"], {
    input: "x".repeat(10000),
  });
  assert.equal(big.status, "ok");
  const ctxPath = big.workflowArgs.inputs.changeContextPath;
  const ctx = JSON.parse(readFileSync(ctxPath, "utf8"));
  const total = ctx.reduce((n, e) => n + Buffer.byteLength(e.text, "utf8"), 0);
  assert.ok(total <= 8192);
  assert.match(ctx[0].text, /truncated/i);
  validateChangeContext(ctxPath);
});

test("missing request text yields null changeContext and a disclosure warning", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 7;\n");
  const out = run(root, ["--profile", "focused"]);
  assert.equal(out.workflowArgs.inputs.changeContextPath, null);
  assert.ok(out.warnings.some((w) => /request/.test(w)));
});

test("codex resolution picks the highest installed version; absence means codex null", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 3;\n");
  const { cacheRoot, cmds } = fakeCodexCache(t, ["1.2.3", "1.10.0", "1.9.9"]);
  const out = run(root, ["--profile", "focused", "--codex-cache-root", cacheRoot]);
  assert.equal(out.workflowArgs.codex.cmd, cmds["1.10.0"]);

  const empty = mkdtempSync(path.join(tmpdir(), "empty-cache-"));
  t.after(() => rmSync(empty, { recursive: true, force: true }));
  const without = run(root, ["--profile", "focused", "--codex-cache-root", empty]);
  assert.equal(without.workflowArgs.codex, null);
  assert.ok(without.warnings.some((w) => /codex/i.test(w)));
});

test("base mode Gate B pins the resolved SHA of the trusted ref", (t) => {
  const root = repo(t);
  const baseSha = git(root, "rev-parse", "HEAD").trim();
  git(root, "branch", "basepoint");
  writeFileSync(path.join(root, "next.js"), "export const n = 1;\n");
  git(root, "add", ".");
  git(root, "commit", "-qm", "next");
  const { cacheRoot } = fakeCodexCache(t, ["3.0.0"]);
  const out = run(root, ["--profile", "focused", "--base", "basepoint", "--codex-cache-root", cacheRoot]);
  assert.equal(out.workflowArgs.codex.targetFlags, "--base basepoint");
  assert.deepEqual(out.workflowArgs.codex.expectedTarget, { mode: "branch", baseSha });
});

test("comprehensive runs installed seed tools in parallel with caps; focused skips seeds", (t) => {
  const root = repo(t);
  writeFileSync(
    path.join(root, "seed-lint.js"),
    "for (let i = 0; i < 300; i++) console.log('lint hit ' + i);\n" +
      "setTimeout(() => {}, 2000);\n",
  );
  writeFileSync(
    path.join(root, "seed-type.js"),
    "console.log('type hit');\nsetTimeout(() => {}, 2000);\n",
  );
  writeFileSync(
    path.join(root, "package.json"),
    JSON.stringify({
      name: "fixture",
      scripts: {
        lint: `node ${path.join(root, "seed-lint.js")}`,
        typecheck: `node ${path.join(root, "seed-type.js")}`,
      },
    }),
  );
  git(root, "add", ".");
  git(root, "commit", "-qm", "seed tools");
  writeFileSync(path.join(root, "src.js"), "const a = 10;\n");

  const started = Date.now();
  const out = run(root, ["--profile", "comprehensive"]);
  const wall = Date.now() - started;
  assert.equal(out.status, "ok");
  assert.ok(out.seeds.includes("lint"));
  assert.ok(out.seeds.includes("typecheck"));
  const lintSeed = readFileSync(path.join(out.runDir, "raw", "seeds", "lint.txt"), "utf8");
  assert.ok(lintSeed.trim().split("\n").length <= 200);
  const reviewInput = readFileSync(out.workflowArgs.inputs.reviewInputPath, "utf8");
  assert.match(reviewInput, /Static-analysis seeds/);
  assert.match(reviewInput, /raw\/seeds\/lint\.txt/);
  // parallel: two ~2s tools must finish well under the ~4s+overhead sequential floor
  assert.ok(wall < 5500, `expected parallel seeds, wall was ${wall}ms`);

  const focused = run(root, ["--profile", "focused"]);
  assert.deepEqual(focused.seeds, []);
  assert.doesNotMatch(
    readFileSync(focused.workflowArgs.inputs.reviewInputPath, "utf8"),
    /Static-analysis seeds/,
  );
});

test("a seed tool exceeding its timeout is killed and skipped with a note", (t) => {
  const root = repo(t);
  writeFileSync(
    path.join(root, "package.json"),
    JSON.stringify({ name: "fixture", scripts: { lint: "node -e 'setTimeout(()=>{},60000)'" } }),
  );
  git(root, "add", ".");
  git(root, "commit", "-qm", "slow tool");
  writeFileSync(path.join(root, "src.js"), "const a = 11;\n");
  const out = run(root, ["--profile", "comprehensive", "--seed-timeout-ms", "500"]);
  assert.equal(out.status, "ok");
  assert.ok(!out.seeds.includes("lint"));
  assert.ok(out.skipped.some((s) => /lint/.test(s) && /timeout/i.test(s)));
});

test("a fake node_modules tsc binary is collected as a seed", (t) => {
  const root = repo(t);
  const binDir = path.join(root, "node_modules", ".bin");
  mkdirSync(binDir, { recursive: true });
  const tsc = path.join(binDir, "tsc");
  writeFileSync(tsc, "#!/bin/sh\necho 'src.js(1,1): error TS0000: fixture'\n");
  chmodSync(tsc, 0o755);
  writeFileSync(path.join(root, "src.js"), "const a = 12;\n");
  const out = run(root, ["--profile", "comprehensive"]);
  assert.ok(out.seeds.includes("tsc"));
  assert.match(
    readFileSync(path.join(out.runDir, "raw", "seeds", "tsc.txt"), "utf8"),
    /error TS0000/,
  );
});

test("gitignored .code-review with an existing ledger gets the dispositions negation once", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, ".gitignore"), ".code-review/\n");
  mkdirSync(path.join(root, ".code-review"));
  writeFileSync(
    path.join(root, ".code-review", "dispositions.json"),
    '{"version":1,"dispositions":[]}\n',
  );
  git(root, "add", ".gitignore");
  git(root, "commit", "-qm", "ignore runs");
  writeFileSync(path.join(root, "src.js"), "const a = 13;\n");
  run(root, ["--profile", "focused"]);
  run(root, ["--profile", "focused"]);
  const gitignore = readFileSync(path.join(root, ".gitignore"), "utf8");
  const hits = gitignore.match(/!\.code-review\/dispositions\.json/g) || [];
  assert.equal(hits.length, 1);
});

test("codex runtime records runtime codex and warns when the probe path is not ignored", (t) => {
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 14;\n");
  const out = run(root, ["--profile", "focused", "--runtime", "codex"]);
  assert.equal(out.status, "ok");
  assert.equal(out.workflowArgs.runtime, "codex");
  const runState = JSON.parse(readFileSync(path.join(out.runDir, "run.json"), "utf8"));
  assert.equal(runState.runtime, "codex");
  assert.ok(out.warnings.some((w) => /\.code-review\/probe/.test(w)));

  const ignored = repo(t);
  writeFileSync(path.join(ignored, ".gitignore"), ".code-review/\n");
  git(ignored, "add", ".gitignore");
  git(ignored, "commit", "-qm", "ignore");
  writeFileSync(path.join(ignored, "src.js"), "const a = 15;\n");
  const ok = run(ignored, ["--profile", "focused", "--runtime", "codex"]);
  assert.ok(!ok.warnings.some((w) => /\.code-review\/probe/.test(w)));
});

test("a post-init failure aborts the run and reports status error", (t) => {
  // Trigger the real assembly-cap failure through a lowered test-seam cap so
  // the genuine over-8KiB path (deep repo roots) is exercised portably.
  const root = repo(t);
  writeFileSync(path.join(root, "src.js"), "const a = 2;\n");
  const out = run(root, ["--profile", "focused", "--max-args-bytes", "500"], {
    expectFail: true,
  });
  assert.equal(out.status, "error");
  assert.match(out.message, /bytes/);
  const runsDir = path.join(root, ".code-review", "runs");
  const runs = existsSync(runsDir)
    ? execFileSync("ls", [runsDir], { encoding: "utf8" }).trim().split("\n").filter(Boolean)
    : [];
  assert.equal(runs.length, 1);
  const runState = JSON.parse(readFileSync(path.join(runsDir, runs[0], "run.json"), "utf8"));
  assert.equal(runState.status, "ABORTED");
});
