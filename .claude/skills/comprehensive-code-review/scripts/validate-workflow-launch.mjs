#!/usr/bin/env node

import { accessSync, constants, readFileSync, realpathSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const skillDir = path.dirname(scriptDir);
const workflowPath = path.join(scriptDir, "review-fanout.workflow.js");
const launcherPath = path.join(scriptDir, "codex-launch.mjs");
const profilesPath = path.join(skillDir, "references", "reviewer-profiles.json");
const agentsDir = path.join(skillDir, "agents");
const MAX_TOOL_INPUT_BYTES = 8192;
// Installed-plugin layout documented in references/workflow-and-codex.md §3:
// ~/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs
const CODEX_CACHE_ROOT = path.join(
  os.homedir(),
  ".claude",
  "plugins",
  "cache",
  "openai-codex",
  "codex",
);
// Test seam: production hook input never sets this env var; tests point it at a tmp cache
// root, read at call time so it also crosses the CLI's spawned-subprocess boundary.
const CODEX_CACHE_ROOT_OVERRIDE_ENV = "VALIDATE_WORKFLOW_LAUNCH_CODEX_CACHE_ROOT";

function codexCacheRoot() {
  return process.env[CODEX_CACHE_ROOT_OVERRIDE_ENV] || CODEX_CACHE_ROOT;
}

function canonical(candidate) {
  try {
    return realpathSync(candidate);
  } catch {
    return path.resolve(candidate);
  }
}

function samePath(left, right) {
  return canonical(left) === canonical(right);
}

function isWithin(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative === "" || (!relative.startsWith(".." + path.sep) && relative !== "..");
}

function readableFile(candidate) {
  try {
    accessSync(candidate, constants.R_OK);
    return statSync(candidate).isFile();
  } catch {
    return false;
  }
}

function parseArgs(value) {
  if (typeof value === "string") return JSON.parse(value);
  return value;
}

function validateRunInput(runDir, label, candidate, required = false) {
  if (candidate == null) {
    if (required) throw new Error(`inputs.${label} is required`);
    return;
  }
  if (typeof candidate !== "string" || !path.isAbsolute(candidate)) {
    throw new Error(`inputs.${label} must be an absolute path`);
  }
  const resolved = canonical(candidate);
  if (!isWithin(runDir, resolved)) {
    throw new Error(`inputs.${label} must stay inside the current run directory`);
  }
  if (!readableFile(resolved)) throw new Error(`inputs.${label} is not a readable file`);
  // runDir is already proven within repoRoot by the caller, so containment in runDir
  // transitively guarantees containment in repoRoot — no separate repoRoot check needed.
}

// Installed-plugin layout: <cacheRoot>/<version>/scripts/codex-companion.mjs
function validateCodexCmd(candidate) {
  const invalid = () => new Error("codex.cmd must be an absolute readable companion path");
  if (typeof candidate !== "string" || candidate.length === 0 || !path.isAbsolute(candidate)) {
    throw invalid();
  }
  if (!readableFile(candidate)) throw invalid();
  const resolved = canonical(candidate);
  if (path.basename(resolved) !== "codex-companion.mjs") throw invalid();
  const cacheRoot = canonical(codexCacheRoot());
  if (!isWithin(cacheRoot, resolved)) throw invalid();
  const relative = path.relative(cacheRoot, resolved);
  const segments = relative.split(path.sep);
  if (segments.length !== 3 || segments[1] !== "scripts") throw invalid();
}

function validateChangeContext(candidate) {
  if (candidate == null) return;
  let context;
  try {
    context = JSON.parse(readFileSync(candidate, "utf8"));
  } catch {
    throw new Error("inputs.changeContextPath must contain valid JSON");
  }
  if (
    !Array.isArray(context) ||
    context.length === 0 ||
    context.some(
      (entry) =>
        !entry ||
        !["request", "commit-messages", "context-file"].includes(entry.source) ||
        typeof entry.text !== "string" ||
        entry.text.length === 0,
    ) ||
    context.reduce((bytes, entry) => bytes + Buffer.byteLength(entry.text, "utf8"), 0) > 8192
  ) {
    throw new Error("inputs.changeContextPath contains an invalid or oversized context array");
  }
}

export function validateWorkflowLaunch(toolInput) {
  if (!toolInput || !samePath(toolInput.scriptPath || "", workflowPath)) {
    return { applies: false };
  }

  try {
    if (Buffer.byteLength(JSON.stringify(toolInput), "utf8") > MAX_TOOL_INPUT_BYTES) {
      throw new Error(`serialized Workflow input exceeds ${MAX_TOOL_INPUT_BYTES} bytes`);
    }
    const args = parseArgs(toolInput.args);
    if (!args || typeof args !== "object" || Array.isArray(args)) {
      throw new Error("args must be a JSON object");
    }
    if (args.runtime !== "claude") throw new Error('args.runtime must be "claude"');
    if (!["focused", "comprehensive"].includes(args.profile)) {
      throw new Error("args.profile is invalid");
    }
    if (!["full", "base", "working-tree"].includes(args.mode)) {
      throw new Error("args.mode is invalid");
    }
    if (args.profile === "focused" && args.mode === "full") {
      throw new Error("focused reviews cannot use full mode");
    }
    if (typeof args.scopeLabel !== "string" || args.scopeLabel.length === 0) {
      throw new Error("args.scopeLabel must be a non-empty string");
    }
    const runIdPattern = /^\d{8}T\d{6}Z-(focused|comprehensive)-[A-Za-z0-9]{6}$/;
    if (!runIdPattern.test(args.runId || "") || !args.runId.includes(`-${args.profile}-`)) {
      throw new Error("args.runId does not match the selected profile");
    }
    if (!path.isAbsolute(args.repoRoot || "")) {
      throw new Error("args.repoRoot must be absolute");
    }
    const repoRoot = canonical(args.repoRoot);
    const expectedOutDir = `.code-review/runs/${args.runId}`;
    if (args.outDir !== expectedOutDir) {
      throw new Error(`args.outDir must equal ${expectedOutDir}`);
    }
    const runDir = canonical(path.resolve(repoRoot, args.outDir));
    if (!isWithin(repoRoot, runDir) || !isWithin(path.join(repoRoot, ".code-review", "runs"), runDir)) {
      throw new Error("run directory escapes .code-review/runs");
    }
    let runDirStat;
    try {
      runDirStat = statSync(runDir);
    } catch (error) {
      if (error?.code === "ENOENT") throw new Error("run directory does not exist");
      throw error;
    }
    if (!runDirStat.isDirectory()) throw new Error("run directory path is not a directory");

    const inputs = args.inputs;
    if (!inputs || typeof inputs !== "object" || Array.isArray(inputs)) {
      throw new Error("args.inputs must be an object");
    }

    const profiles = JSON.parse(readFileSync(profilesPath, "utf8"));
    if (profiles.version !== 1 || !Array.isArray(profiles[args.profile])) {
      throw new Error("reviewer profile manifest is invalid");
    }
    const expectedNames = [...profiles[args.profile]];
    if (inputs.specPath != null) {
      if (args.profile !== "comprehensive") {
        throw new Error("specPath is only valid for comprehensive reviews");
      }
      if (profiles.conditional?.["implementation-reviewer"] !== "spec") {
        throw new Error("conditional implementation reviewer manifest is invalid");
      }
      expectedNames.push("implementation-reviewer");
    }
    if (!Array.isArray(args.reviewers) || args.reviewers.length !== expectedNames.length) {
      throw new Error("reviewer roster does not match the selected profile");
    }
    expectedNames.forEach((name, index) => {
      const reviewer = args.reviewers[index];
      const expectedCharter = path.join(agentsDir, `${name}.md`);
      if (
        !reviewer ||
        reviewer.name !== name ||
        Object.hasOwn(reviewer, "role") ||
        !samePath(reviewer.charterPath || "", expectedCharter) ||
        !readableFile(expectedCharter)
      ) {
        throw new Error(`reviewer ${name} does not reference its canonical charter`);
      }
    });

    for (const legacyKey of [
      "reviewInput",
      "changedFiles",
      "docsManifest",
      "changeContext",
      "dispositions",
      "spec",
    ]) {
      if (Object.hasOwn(args, legacyKey)) {
        throw new Error(`args.${legacyKey} is an obsolete inline input`);
      }
    }
    validateRunInput(runDir, "reviewInputPath", inputs.reviewInputPath, true);
    validateRunInput(runDir, "changedFilesPath", inputs.changedFilesPath, true);
    for (const key of [
      "docsManifestPath",
      "changeContextPath",
      "dispositionsPath",
      "specPath",
    ]) {
      validateRunInput(runDir, key, inputs[key]);
    }
    validateChangeContext(inputs.changeContextPath);
    if (inputs.claudeMdPath != null) {
      if (!path.isAbsolute(inputs.claudeMdPath)) {
        throw new Error("inputs.claudeMdPath must be absolute");
      }
      const claudeMdPath = canonical(inputs.claudeMdPath);
      if (!isWithin(repoRoot, claudeMdPath) || !readableFile(claudeMdPath)) {
        throw new Error("inputs.claudeMdPath must be a readable repository file");
      }
    }

    if (args.codex != null) {
      if (!samePath(args.codex.launcher || "", launcherPath)) {
        throw new Error("codex.launcher is not the bundled launcher");
      }
      validateCodexCmd(args.codex.cmd);
      const workingTree = args.codex.targetFlags === "--scope working-tree";
      const branch = /^--base [A-Za-z0-9._/@{}~^-]+$/.test(args.codex.targetFlags || "");
      if (!workingTree && !branch) throw new Error("codex.targetFlags is unsafe");
      if ((args.mode === "working-tree") !== workingTree) {
        throw new Error("codex.targetFlags does not match review mode");
      }
      if (workingTree && args.codex.expectedTarget?.mode !== "working-tree") {
        throw new Error("codex.expectedTarget does not match working-tree scope");
      }
      if (
        branch &&
        (args.codex.expectedTarget?.mode !== "branch" ||
          !/^[0-9a-f]{40,64}$/.test(args.codex.expectedTarget.baseSha || ""))
      ) {
        throw new Error("codex.expectedTarget does not contain a valid branch SHA");
      }
    }
    return { applies: true, allowed: true };
  } catch (error) {
    return {
      applies: true,
      allowed: false,
      reason: String(error?.message || error),
    };
  }
}

function emitDecision(decision) {
  if (!decision.applies) return;
  const allowed = decision.allowed === true;
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: allowed ? "allow" : "deny",
        permissionDecisionReason: allowed
          ? "Validated bundled code-review Workflow launch."
          : `Rejected malformed bundled code-review Workflow launch: ${decision.reason}`,
      },
    }),
  );
}

if (process.argv[1] && samePath(process.argv[1], fileURLToPath(import.meta.url))) {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    raw += chunk;
  });
  process.stdin.on("end", () => {
    try {
      const payload = JSON.parse(raw || "{}");
      if (payload.tool_name !== "Workflow") return;
      emitDecision(validateWorkflowLaunch(payload.tool_input));
    } catch (error) {
      emitDecision({ applies: true, allowed: false, reason: `invalid hook input: ${error.message}` });
    }
  });
}
