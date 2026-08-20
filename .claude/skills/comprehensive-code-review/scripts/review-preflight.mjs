#!/usr/bin/env node

// Deterministic preflight for the code-review skills. Executes everything the
// SKILL.md Phases 1-4 used to hand-execute in the model: scope gathering, run
// init, artifact materialization, docs manifest, dispositions, changeContext,
// static-analysis seeds, Codex resolution, roster assembly — and emits the
// exact Workflow args (also persisted to raw/inputs/launch-args.json for the
// PreToolUse hook's provenance pinning). One JSON line on stdout:
//   {status:"ok", workflowArgs, runDir, runId, ...} | {status:"empty", ...} |
//   {status:"error", message, ...} (exit 1; run finished ABORTED when it exists)

import { execFileSync, spawn } from "node:child_process";
import {
  accessSync,
  constants,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  writeFileSync,
  appendFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { validateChangeContext } from "./validate-workflow-launch.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillDir = path.dirname(scriptDir);
const reviewRunPath = path.join(scriptDir, "review-run.mjs");
const workflowPath = path.join(scriptDir, "review-fanout.workflow.js");
const launcherPath = path.join(scriptDir, "codex-launch.mjs");
const profilesPath = path.join(skillDir, "references", "reviewer-profiles.json");
const agentsDir = path.join(skillDir, "agents");

const DEFAULT_CODEX_CACHE_ROOT = path.join(
  os.homedir(),
  ".claude",
  "plugins",
  "cache",
  "openai-codex",
  "codex",
);
const EXCLUDES = [
  ":(top,exclude,glob).code-review/**",
  ":(top,exclude,glob)**/dist/**",
  ":(top,exclude,glob)**/build/**",
  ":(top,exclude,glob)**/out/**",
  ":(top,exclude,glob)**/.next/**",
  ":(top,exclude,glob)**/.nuxt/**",
  ":(top,exclude,glob)**/.svelte-kit/**",
  ":(top,exclude,glob)**/.output/**",
  ":(top,exclude,glob)**/coverage/**",
  ":(top,exclude,glob)**/*.min.js",
  ":(top,exclude,glob)**/*.min.css",
  ":(top,exclude,glob)**/*.map",
  ":(top,exclude,glob)**/pnpm-lock.yaml",
  ":(top,exclude,glob)**/package-lock.json",
  ":(top,exclude,glob)**/yarn.lock",
  ":(top,exclude,glob)**/bun.lock",
  ":(top,exclude,glob)**/bun.lockb",
];
const DIFF_MANIFEST_THRESHOLD_LINES = 2000;
const SECURITY_PATH_RE =
  /(auth|login|session|password|secret|token|crypto|payment|billing|sql|query|exec|deserialize)/i;
const PROTECTED_CONTEXT_RE = /(^|[\\/])\.env|secret|credential|id_rsa|\.pem$|\.key$/i;
const CHANGE_CONTEXT_MAX_BYTES = 8192;
const SEED_OUTPUT_MAX_LINES = 200;
const REF_RE = /^[A-Za-z0-9._/@{}~^-]+$/;

class PreflightError extends Error {}

const parseFlags = (argv) => {
  const flags = { warnings: [] };
  const booleans = new Set(["full", "request-stdin"]);
  const known = new Set([
    ...booleans,
    "repo-root",
    "profile",
    "runtime",
    "base",
    "spec",
    "context",
    "pass",
    "codex-cache-root",
    "seed-timeout-ms",
    "max-args-bytes",
  ]);
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--")) throw new PreflightError(`unexpected argument: ${key}`);
    const name = key.slice(2);
    if (!known.has(name)) throw new PreflightError(`unknown flag: --${name}`);
    if (booleans.has(name)) {
      flags[name] = true;
    } else {
      const value = argv[i + 1];
      if (value === undefined) throw new PreflightError(`--${name} requires a value`);
      flags[name] = value;
      i += 1;
    }
  }
  return flags;
};

const readableFile = (candidate) => {
  try {
    accessSync(candidate, constants.R_OK);
    return statSync(candidate).isFile();
  } catch {
    return false;
  }
};

const emit = (payload) => {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
};

function git(repoRoot, args, { allowFailure = false } = {}) {
  try {
    return execFileSync("git", ["-C", repoRoot, ...args], {
      encoding: "utf8",
      maxBuffer: 1 << 28,
    });
  } catch (error) {
    if (allowFailure) return null;
    throw new PreflightError(
      `git ${args[0]} failed: ${String(error.stderr || error.message).trim()}`,
    );
  }
}

const gitLines = (repoRoot, args) =>
  (git(repoRoot, args) || "").split("\n").map((l) => l.trim()).filter(Boolean);

function readStdin() {
  try {
    return readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function detectPackageManager(repoRoot) {
  if (existsSync(path.join(repoRoot, "pnpm-lock.yaml"))) return "pnpm";
  if (existsSync(path.join(repoRoot, "yarn.lock"))) return "yarn";
  if (
    existsSync(path.join(repoRoot, "bun.lock")) ||
    existsSync(path.join(repoRoot, "bun.lockb"))
  ) {
    return "bun";
  }
  return "npm";
}

function onPath(binary) {
  return (process.env.PATH || "").split(path.delimiter).some((dir) => {
    try {
      return dir && statSync(path.join(dir, binary)).isFile();
    } catch {
      return false;
    }
  });
}

// Run one seed tool in its own process group (grandchildren die with it on
// timeout), capture combined output, cap at SEED_OUTPUT_MAX_LINES.
function runSeedTool({ name, cmd, args }, repoRoot, timeoutMs) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(cmd, args, { cwd: repoRoot, detached: true, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      resolve({ name, output: "", note: `spawn failed: ${error.message}` });
      return;
    }
    let output = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        /* already gone */
      }
    }, timeoutMs);
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (output += chunk));
    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({ name, output: "", note: `failed to run: ${error.message}` });
    });
    child.on("close", () => {
      clearTimeout(timer);
      if (timedOut) {
        resolve({ name, output: "", note: "timeout — killed and skipped" });
        return;
      }
      const lines = output.split("\n");
      const capped =
        lines.length > SEED_OUTPUT_MAX_LINES
          ? lines.slice(0, SEED_OUTPUT_MAX_LINES).join("\n") + "\n"
          : output;
      resolve({ name, output: capped.trim() ? capped : "", note: null });
    });
  });
}

function collectSeedTools(repoRoot, mode, changedFiles) {
  const tools = [];
  const pkgPath = path.join(repoRoot, "package.json");
  let pkg = null;
  if (readableFile(pkgPath)) {
    try {
      pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
    } catch {
      pkg = null;
    }
  }
  const pm = detectPackageManager(repoRoot);
  for (const scriptName of ["lint", "typecheck"]) {
    if (pkg?.scripts?.[scriptName]) {
      tools.push({ name: scriptName, cmd: pm, args: ["run", scriptName] });
    }
  }
  const eslintBin = path.join(repoRoot, "node_modules", ".bin", "eslint");
  const hasEslintConfig =
    ["eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts"].some(
      (f) => existsSync(path.join(repoRoot, f)),
    ) ||
    readdirSync(repoRoot).some((f) => f.startsWith(".eslintrc"));
  if (existsSync(eslintBin) && hasEslintConfig) {
    const targets = mode === "full" ? ["."] : changedFiles.filter((f) => /\.[cm]?[jt]sx?$/.test(f));
    if (targets.length) tools.push({ name: "eslint", cmd: eslintBin, args: targets });
  }
  const tscBin = path.join(repoRoot, "node_modules", ".bin", "tsc");
  if (existsSync(tscBin)) tools.push({ name: "tsc", cmd: tscBin, args: ["--noEmit"] });
  const semgrepConfig = [".semgrep.yml", ".semgrep"].find((f) =>
    existsSync(path.join(repoRoot, f)),
  );
  if (onPath("semgrep") && semgrepConfig) {
    tools.push({
      name: "semgrep",
      cmd: "semgrep",
      args: ["scan", "--config", path.join(repoRoot, semgrepConfig)],
    });
  }
  return tools;
}

function buildDocsManifest(repoRoot, mode) {
  const tracked = gitLines(repoRoot, ["ls-files", "--", ".", ...EXCLUDES]);
  const untracked =
    mode === "working-tree"
      ? gitLines(repoRoot, ["ls-files", "--others", "--exclude-standard", "--", ".", ...EXCLUDES])
      : [];
  const markdown = [...new Set([...tracked, ...untracked])].filter((f) => /\.md$/i.test(f));
  if (markdown.length === 0) return null;
  const groupOf = (file) => {
    const base = path.basename(file);
    if (base === "AGENTS.md" || base === "CLAUDE.md") return 0;
    if (/^README.*\.md$/i.test(base)) return 1;
    if (file === "docs" || file.startsWith("docs/")) return 2;
    return 3;
  };
  markdown.sort((a, b) => groupOf(a) - groupOf(b) || a.localeCompare(b));
  const kept = markdown.slice(0, 50);
  const omitted = markdown.length - kept.length;
  return kept.join("\n") + (omitted > 0 ? `\n(${omitted} more omitted)` : "") + "\n";
}

function truncateToBudget(text, budgetBytes) {
  if (Buffer.byteLength(text, "utf8") <= budgetBytes) return { text, truncated: false };
  const marker = "\n…[truncated to fit the 8 KiB change-context cap]";
  let allowed = budgetBytes - Buffer.byteLength(marker, "utf8");
  if (allowed <= 0) return { text: null, truncated: true };
  let slice = text;
  while (Buffer.byteLength(slice, "utf8") > allowed) {
    slice = slice.slice(0, Math.floor(slice.length * 0.9) || slice.length - 1);
  }
  return { text: slice + marker, truncated: true };
}

function buildChangeContext({ requestText, commitMessages, contextFileText }) {
  const raw = [];
  if (requestText?.trim()) raw.push({ source: "request", text: requestText.trim() });
  if (commitMessages?.trim()) {
    raw.push({ source: "commit-messages", text: commitMessages.trim() });
  }
  if (contextFileText?.trim()) {
    raw.push({ source: "context-file", text: contextFileText.trim() });
  }
  const entries = [];
  let remaining = CHANGE_CONTEXT_MAX_BYTES;
  for (const entry of raw) {
    if (remaining <= 0) break;
    const { text } = truncateToBudget(entry.text, remaining);
    if (!text) continue;
    remaining -= Buffer.byteLength(text, "utf8");
    entries.push({ source: entry.source, text });
  }
  return entries;
}

function resolveCodex({ repoRoot, mode, baseRef, cacheRoot, warnings }) {
  let versions = [];
  try {
    versions = readdirSync(cacheRoot).filter((v) =>
      readableFile(path.join(cacheRoot, v, "scripts", "codex-companion.mjs")),
    );
  } catch {
    versions = [];
  }
  if (versions.length === 0) {
    warnings.push("Codex companion not installed — the adversarial Codex track will be SKIPPED.");
    return null;
  }
  versions.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const cmd = path.join(cacheRoot, versions[versions.length - 1], "scripts", "codex-companion.mjs");

  let targetFlags;
  let expectedTarget;
  if (mode === "working-tree") {
    targetFlags = "--scope working-tree";
    expectedTarget = { mode: "working-tree" };
  } else {
    let codexBase = baseRef;
    if (!codexBase) {
      // --full alone: recent-window base (HEAD~30, clamped to the root commit)
      const count = Number(git(repoRoot, ["rev-list", "--count", "HEAD"]).trim());
      codexBase =
        count > 30
          ? git(repoRoot, ["rev-parse", "HEAD~30"]).trim()
          : gitLines(repoRoot, ["rev-list", "--max-parents=0", "HEAD"]).at(-1);
    }
    targetFlags = `--base ${codexBase}`;
    expectedTarget = {
      mode: "branch",
      baseSha: git(repoRoot, ["rev-parse", `${codexBase}^{commit}`]).trim(),
    };
  }
  return { cmd, launcher: launcherPath, targetFlags, expectedTarget };
}

function computeChurn(repoRoot) {
  const counts = new Map();
  for (const file of gitLines(repoRoot, [
    "log",
    '--since="12 months ago"',
    "--format=",
    "--name-only",
    "--",
    ".",
    ...EXCLUDES,
  ])) {
    counts.set(file, (counts.get(file) || 0) + 1);
  }
  return counts;
}

function buildManifestReviewInput({ repoRoot, runDir, diffText, diffArgs, repoRelRunDir }) {
  const patchPath = path.join(runDir, "raw", "full-diff.patch");
  writeFileSync(patchPath, diffText);
  const patchLines = diffText.split("\n");
  const fileStart = new Map();
  patchLines.forEach((line, index) => {
    const match = line.match(/^diff --git a\/.* b\/(.*)$/);
    if (match && !fileStart.has(match[1])) fileStart.set(match[1], index + 1);
  });
  const churn = computeChurn(repoRoot);
  const numstat = new Map();
  for (const line of gitLines(repoRoot, ["diff", "--numstat", ...diffArgs])) {
    const [adds, dels, file] = line.split("\t");
    if (file) numstat.set(file, { adds, dels });
  }
  const files = [...fileStart.keys()];
  const riskOf = (file) => (SECURITY_PATH_RE.test(file) ? 2 : churn.get(file) ? 1 : 0);
  files.sort((a, b) => {
    const security = riskOf(b) === 2 ? 1 : 0;
    const securityA = riskOf(a) === 2 ? 1 : 0;
    if (securityA !== security) return security - securityA;
    const churnDelta = (churn.get(b) || 0) - (churn.get(a) || 0);
    if (churnDelta !== 0) return churnDelta;
    const size = (entry) =>
      entry ? (Number(entry.adds) || 0) + (Number(entry.dels) || 0) : 0;
    return size(numstat.get(b)) - size(numstat.get(a));
  });
  const rows = files.map((file) => {
    const stat = numstat.get(file) || { adds: "-", dels: "-" };
    const label = riskOf(file) === 2 ? "sec" : riskOf(file) === 1 ? "churn" : "size";
    return `| ${label} | ${file} | +${stat.adds}/−${stat.dels} | ${fileStart.get(file)} |`;
  });
  const totalLines = patchLines.length;
  return [
    `The complete diff is at ${patchPath} (${totalLines} lines).`,
    "Read ALL of it before reviewing — page through it with Read offset/limit using the per-file",
    "line index below. The manifest is a reading order, not a substitute for the diff.",
    "",
    "| risk | file | +/− | patch line |",
    "| ---- | ---- | --- | ---------- |",
    ...rows,
    "",
  ].join("\n");
}

async function collectSeeds({ repoRoot, runDir, mode, changedFiles, timeoutMs, skipped }) {
  const tools = collectSeedTools(repoRoot, mode, changedFiles);
  if (tools.length === 0) return { seeds: [], manifest: null };
  const results = await Promise.all(tools.map((tool) => runSeedTool(tool, repoRoot, timeoutMs)));
  const seeds = [];
  const manifestLines = [];
  for (const result of results) {
    if (result.note) {
      skipped.push(`seed ${result.name}: ${result.note}`);
      continue;
    }
    if (!result.output) {
      skipped.push(`seed ${result.name}: no output`);
      continue;
    }
    const seedsDir = path.join(runDir, "raw", "seeds");
    mkdirSync(seedsDir, { recursive: true });
    const seedPath = path.join(seedsDir, `${result.name}.txt`);
    writeFileSync(seedPath, result.output.endsWith("\n") ? result.output : `${result.output}\n`);
    seeds.push(result.name);
    manifestLines.push(
      `- ${result.name}: ${result.output.trim().split("\n").length} lines → ${seedPath}`,
    );
  }
  if (seeds.length === 0) return { seeds: [], manifest: null };
  const manifest = [
    "",
    "## Static-analysis seeds (candidate leads — Read the file for your lens, then trace + quote yourself)",
    "A seed becomes a finding ONLY when you trace it and quote the code yourself (file:line + verbatim);",
    "report seeds you cannot substantiate as nothing at all. Read only the tools relevant to your role.",
    ...manifestLines,
    "",
  ].join("\n");
  return { seeds, manifest };
}

function ensureDispositionsNegation(repoRoot) {
  const ledgerPath = path.join(repoRoot, ".code-review", "dispositions.json");
  if (!existsSync(ledgerPath)) return;
  const ignored =
    git(repoRoot, ["check-ignore", "-q", ".code-review/probe"], { allowFailure: true }) !== null;
  if (!ignored) return;
  const gitignorePath = path.join(repoRoot, ".gitignore");
  const current = existsSync(gitignorePath) ? readFileSync(gitignorePath, "utf8") : "";
  if (current.includes("!.code-review/dispositions.json")) return;
  const prefix = current && !current.endsWith("\n") ? "\n" : "";
  appendFileSync(gitignorePath, `${prefix}!.code-review/dispositions.json\n`);
}

async function main() {
  const flags = parseFlags(process.argv.slice(2));
  const warnings = [];
  const skipped = [];

  const repoRoot = path.resolve(flags["repo-root"] || "");
  if (!flags["repo-root"] || !path.isAbsolute(flags["repo-root"])) {
    throw new PreflightError("--repo-root must be an absolute path");
  }
  const profile = flags.profile;
  if (!["focused", "comprehensive"].includes(profile)) {
    throw new PreflightError("--profile must be focused or comprehensive");
  }
  const runtime = flags.runtime || "claude";
  if (!["claude", "codex"].includes(runtime)) {
    throw new PreflightError("--runtime must be claude or codex");
  }
  const passNumber = flags.pass ? Number(flags.pass) : 1;
  if (!Number.isInteger(passNumber) || passNumber < 1) {
    throw new PreflightError("--pass must be an integer >= 1");
  }
  const seedTimeoutMs = flags["seed-timeout-ms"] ? Number(flags["seed-timeout-ms"]) : 120000;
  const maxArgsBytes = flags["max-args-bytes"] ? Number(flags["max-args-bytes"]) : 8192;
  git(repoRoot, ["rev-parse", "--git-dir"]);

  let full = Boolean(flags.full);
  let specFlag = flags.spec || null;
  if (profile === "focused" && full) {
    // Codex-native router contract: reject, never silently rescope.
    if (runtime === "codex") throw new PreflightError("--full is not supported by the focused profile");
    warnings.push("--full is not supported by the focused profile — ignored.");
    full = false;
  }
  if (profile === "focused" && specFlag) {
    if (runtime === "codex") throw new PreflightError("--spec is not supported by the focused profile");
    warnings.push("--spec is not supported by the focused profile — ignored.");
    specFlag = null;
  }

  const baseRef = flags.base || null;
  if (baseRef) {
    if (!REF_RE.test(baseRef)) throw new PreflightError(`unsafe --base ref: ${baseRef}`);
    if (git(repoRoot, ["rev-parse", "--verify", "--quiet", `${baseRef}^{commit}`], { allowFailure: true }) === null) {
      throw new PreflightError(`--base ref does not resolve to a commit: ${baseRef}`);
    }
  }

  let contextFileText = null;
  if (flags.context) {
    const resolved = path.resolve(repoRoot, flags.context);
    let real;
    try {
      real = realpathSync(resolved);
    } catch {
      throw new PreflightError(`--context file not readable: ${flags.context}`);
    }
    const relative = path.relative(realpathSync(repoRoot), real);
    if (relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new PreflightError("--context file must resolve inside the repository");
    }
    if (PROTECTED_CONTEXT_RE.test(relative)) {
      throw new PreflightError("--context file matches a protected/secret path pattern");
    }
    if (!readableFile(real)) throw new PreflightError(`--context file not readable: ${flags.context}`);
    contextFileText = readFileSync(real, "utf8");
  }

  const requestText = flags["request-stdin"] ? readStdin() : "";

  const mode = full ? "full" : baseRef ? "base" : "working-tree";
  const scopeLabel =
    mode === "full"
      ? "ENTIRE CODEBASE (current state)"
      : mode === "base"
        ? `${baseRef}...HEAD`
        : "working tree vs HEAD";

  // ---- Gather changed files (empty guard runs BEFORE any run dir exists) ----
  let changedFiles;
  let untrackedFiles = [];
  const diffArgs =
    mode === "base" ? [`${baseRef}...HEAD`, "--", ".", ...EXCLUDES] : ["HEAD", "--", ".", ...EXCLUDES];
  if (mode === "full") {
    changedFiles = gitLines(repoRoot, ["ls-files", "--", ".", ...EXCLUDES]);
  } else if (mode === "base") {
    changedFiles = gitLines(repoRoot, ["diff", "--name-only", ...diffArgs]);
  } else {
    const tracked = gitLines(repoRoot, ["diff", "--name-only", ...diffArgs]);
    untrackedFiles = gitLines(repoRoot, [
      "ls-files",
      "--others",
      "--exclude-standard",
      "--",
      ".",
      ...EXCLUDES,
    ]);
    changedFiles = [...new Set([...tracked, ...untrackedFiles])].sort();
  }
  if (changedFiles.length === 0) {
    const message =
      mode === "full"
        ? "Nothing to review: no tracked files (build outputs excluded)."
        : mode === "base"
          ? `Nothing to review: no changes vs ${baseRef} (build outputs excluded).`
          : "Nothing to review: working tree matches HEAD and no untracked files (build outputs excluded).";
    emit({ status: "empty", message, warnings });
    return;
  }

  if (runtime === "codex") {
    const probeIgnored =
      git(repoRoot, ["check-ignore", "-q", ".code-review/probe"], { allowFailure: true }) !== null;
    if (!probeIgnored) {
      warnings.push(
        ".code-review/probe is not gitignored — run artifacts would be visible to git; finish DONE_WITH_CONCERNS.",
      );
    }
  }

  // ---- Create the run ----
  const runState = JSON.parse(
    execFileSync(
      process.execPath,
      [
        reviewRunPath,
        "init",
        "--repo-root",
        repoRoot,
        "--runtime",
        runtime,
        "--profile",
        profile,
        "--mode",
        mode,
        "--scope-label",
        scopeLabel,
        "--pass-number",
        String(passNumber),
      ],
      { encoding: "utf8" },
    ),
  );
  const runDir = runState.runDir;
  const runId = runState.runId;

  try {
    const inputsDir = path.join(runDir, "raw", "inputs");
    const changedFilesPath = path.join(runDir, "raw", "changed-files.txt");
    writeFileSync(changedFilesPath, changedFiles.join("\n") + "\n");

    // ---- Review input (direct diff, manifest, or full-mode inventory) ----
    let manifestMode = false;
    let reviewInput;
    if (mode === "full") {
      const churn = computeChurn(repoRoot);
      const hotspots = [...churn.entries()]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 20)
        .map(([file, count]) => `${count}\t${file}`);
      reviewInput = [
        "Review the ENTIRE codebase at its current committed state. Use Read/Grep/Glob to open and",
        "inspect the actual files listed in the changed-files inventory. Do NOT expect a diff.",
        "",
        "Prioritize these high-churn hotspot files (defect density concentrates in churn):",
        hotspots.length ? hotspots.join("\n") : "(no hotspot history)",
        "Cover hotspots first, then sample the rest.",
        "",
      ].join("\n");
    } else {
      const diffText = git(repoRoot, ["diff", ...diffArgs]);
      const diffLineCount = diffText === "" ? 0 : diffText.split("\n").length - 1;
      if (diffLineCount > DIFF_MANIFEST_THRESHOLD_LINES) {
        manifestMode = true;
        reviewInput = buildManifestReviewInput({ repoRoot, runDir, diffText, diffArgs });
      } else {
        reviewInput = diffText;
      }
      if (mode === "working-tree" && untrackedFiles.length > 0) {
        reviewInput += "\nUntracked files in the changed-files list have no diff; Read them directly.\n";
      }
    }
    const reviewInputPath = path.join(inputsDir, "review-input.txt");
    writeFileSync(reviewInputPath, reviewInput);

    // ---- Docs manifest ----
    const docsManifest = buildDocsManifest(repoRoot, mode);
    let docsManifestPath = null;
    if (docsManifest) {
      docsManifestPath = path.join(inputsDir, "docs-manifest.txt");
      writeFileSync(docsManifestPath, docsManifest);
    }

    // ---- Disposition ledger (corrupt ledger fails open with a warning) ----
    let dispositionsPath = null;
    try {
      const rendered = JSON.parse(
        execFileSync(
          process.execPath,
          [
            reviewRunPath,
            "render-dispositions",
            "--repo-root",
            repoRoot,
            ...(mode === "full" ? ["--full", "true"] : ["--changed-files", changedFilesPath]),
          ],
          { encoding: "utf8" },
        ),
      );
      if (rendered.reviewerBlock) {
        dispositionsPath = path.join(inputsDir, "dispositions.txt");
        writeFileSync(dispositionsPath, rendered.reviewerBlock + "\n");
      }
    } catch (error) {
      warnings.push(
        `disposition ledger unreadable — previously adjudicated claims may re-appear (${String(error.stderr || error.message).trim()})`,
      );
    }

    // ---- Change rationale ----
    const commitMessages =
      mode !== "working-tree" && baseRef
        ? git(repoRoot, ["log", `${baseRef}..HEAD`, "--format=%B"], { allowFailure: true }) || ""
        : "";
    const changeContext = buildChangeContext({ requestText, commitMessages, contextFileText });
    let changeContextPath = null;
    if (changeContext.length > 0) {
      changeContextPath = path.join(inputsDir, "change-context.json");
      writeFileSync(changeContextPath, `${JSON.stringify(changeContext, null, 2)}\n`);
      validateChangeContext(changeContextPath);
    }
    if (!requestText.trim()) {
      warnings.push(
        "no --request-stdin text supplied — the report's Scope section should disclose the missing change rationale.",
      );
    }

    // ---- Static-analysis seeds (comprehensive only, parallel, capped) ----
    let seeds = [];
    if (profile === "comprehensive") {
      const collected = await collectSeeds({
        repoRoot,
        runDir,
        mode,
        changedFiles,
        timeoutMs: seedTimeoutMs,
        skipped,
      });
      seeds = collected.seeds;
      if (collected.manifest) appendFileSync(reviewInputPath, collected.manifest);
    }

    // ---- Spec snapshot + roster ----
    const profiles = JSON.parse(readFileSync(profilesPath, "utf8"));
    if (profiles.version !== 1 || !Array.isArray(profiles[profile])) {
      throw new PreflightError("reviewer profile manifest is invalid");
    }
    const names = [...profiles[profile]];
    let specPath = null;
    if (specFlag) {
      const resolvedSpec = path.resolve(repoRoot, specFlag);
      if (!readableFile(resolvedSpec)) {
        skipped.push(`implementation-reviewer: spec file not found: ${specFlag}`);
      } else {
        specPath = path.join(inputsDir, "spec");
        writeFileSync(specPath, readFileSync(resolvedSpec));
        if (profiles.conditional?.["implementation-reviewer"] !== "spec") {
          throw new PreflightError("conditional implementation reviewer manifest is invalid");
        }
        names.push("implementation-reviewer");
      }
    }
    const reviewers = names.map((name) => {
      const charterPath = path.join(agentsDir, `${name}.md`);
      if (!readableFile(charterPath)) {
        throw new PreflightError(`reviewer charter missing or unreadable: ${charterPath}`);
      }
      return { name, charterPath };
    });

    // ---- Codex resolution + Gate B (claude runtime only; native runs never recurse) ----
    const codex =
      runtime === "claude"
        ? resolveCodex({
            repoRoot,
            mode,
            baseRef,
            cacheRoot: flags["codex-cache-root"] || DEFAULT_CODEX_CACHE_ROOT,
            warnings,
          })
        : null;

    const claudeMdCandidate = path.join(repoRoot, "CLAUDE.md");
    const claudeMdPath = readableFile(claudeMdCandidate) ? claudeMdCandidate : null;

    const workflowArgs = {
      runtime,
      profile,
      runId,
      scopeLabel,
      mode,
      repoRoot,
      outDir: `.code-review/runs/${runId}`,
      inputs: {
        reviewInputPath,
        changedFilesPath,
        docsManifestPath,
        changeContextPath,
        dispositionsPath,
        specPath,
        claudeMdPath,
      },
      reviewers,
      codex,
    };
    const serializedBytes = Buffer.byteLength(
      JSON.stringify({ scriptPath: workflowPath, args: workflowArgs }),
      "utf8",
    );
    if (serializedBytes > maxArgsBytes) {
      throw new PreflightError(
        `serialized Workflow launch is ${serializedBytes} bytes — exceeds the ${maxArgsBytes}-byte cap`,
      );
    }
    writeFileSync(
      path.join(inputsDir, "launch-args.json"),
      `${JSON.stringify(workflowArgs, null, 2)}\n`,
    );

    ensureDispositionsNegation(repoRoot);

    emit({
      status: "ok",
      workflowArgs,
      runDir,
      runId,
      scopeLabel,
      manifestMode,
      seeds,
      skipped,
      warnings,
    });
  } catch (error) {
    const message = String(error?.message || error);
    try {
      execFileSync(
        process.execPath,
        [
          reviewRunPath,
          "finish",
          "--run-dir",
          runDir,
          "--status",
          "ABORTED",
          "--reason",
          message.slice(0, 500),
        ],
        { encoding: "utf8" },
      );
    } catch {
      /* run.json already terminal or unwritable — the error below still surfaces */
    }
    emit({ status: "error", message, runDir, runId, warnings });
    process.exitCode = 1;
  }
}

main().catch((error) => {
  emit({ status: "error", message: String(error?.message || error) });
  process.exitCode = 1;
});
