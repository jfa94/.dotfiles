#!/usr/bin/env node

import {
  existsSync,
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
const VALID_DISPOSITION = new Set([
  "accepted-risk",
  "wont-fix",
  "refuted",
  "overturned",
  "by-design",
  "intent-confirmed",
]);
const VALID_DECIDED_BY = new Set(["caller", "report", "user"]);
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

const collapseWs = (s) => String(s).replace(/\s+/g, " ").trim();
// Same normalization as verify-citations.mjs matchDisposition — the two
// scripts must agree on what "same title" means.
const normalizeClaim = (s) =>
  collapseWs(String(s).toLowerCase().replace(/[^a-z0-9 ]+/g, " "));

const readLedger = (repoRoot) => {
  const ledgerPath = path.join(repoRoot, ".code-review", "dispositions.json");
  if (!existsSync(ledgerPath)) {
    return { ledgerPath, ledger: { version: 1, dispositions: [] } };
  }
  let ledger;
  try {
    ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
  } catch (error) {
    fail(`cannot read dispositions.json: ${error.message}`);
  }
  if (!Array.isArray(ledger.dispositions)) {
    fail("dispositions.json malformed: no dispositions array");
  }
  return { ledgerPath, ledger };
};

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
  const passNumber = args["pass-number"] ? Number(args["pass-number"]) : 1;
  if (!Number.isInteger(passNumber) || passNumber < 1) {
    fail("--pass-number must be an integer >= 1");
  }

  const runsRoot = path.join(repoRoot, ".code-review", "runs");
  mkdirSync(runsRoot, { recursive: true });
  const runDir = mkdtempSync(path.join(runsRoot, `${timestamp()}-${profile}-`));
  const runId = path.basename(runDir);
  mkdirSync(path.join(runDir, "raw", "inputs"), { recursive: true });
  const state = {
    runtime,
    profile,
    runId,
    scopeLabel,
    mode,
    passNumber,
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

// Upserts one adjudicated claim into <repoRoot>/.code-review/dispositions.json
// — the anti-ratcheting ledger verify-citations.mjs matches against. Upsert
// key = repo-relative file + normalized title (no lines/quotes: both churn).
const disposition = (args) => {
  const repoRoot = path.resolve(required(args, "repo-root"));
  const file = required(args, "file");
  const title = required(args, "title");
  const status = required(args, "status");
  const reason = required(args, "reason");
  if (!VALID_DISPOSITION.has(status)) {
    fail(
      "--status must be accepted-risk, wont-fix, refuted, overturned, by-design, or intent-confirmed",
    );
  }
  if (!normalizeClaim(title)) fail("--title must not be empty");
  const decidedBy = args["decided-by"] || "caller";
  if (!VALID_DECIDED_BY.has(decidedBy)) {
    fail("--decided-by must be caller, report, or user");
  }
  if (
    (status === "accepted-risk" ||
      status === "by-design" ||
      status === "intent-confirmed") &&
    decidedBy !== "user"
  ) {
    fail(`--status ${status} requires --decided-by user`);
  }
  try {
    if (!statSync(repoRoot).isDirectory()) fail("--repo-root must be a directory");
  } catch {
    fail("--repo-root must be an existing directory");
  }
  const relFile = path.relative(repoRoot, path.resolve(repoRoot, file));
  if (relFile === "" || relFile.startsWith("..") || path.isAbsolute(relFile)) {
    fail("--file must be a path inside --repo-root");
  }

  // A corrupt ledger must never be silently clobbered — fail loudly.
  const { ledgerPath, ledger } = readLedger(repoRoot);

  const keywords = (args.keywords || "")
    .split(",")
    .map((k) => k.trim())
    .filter(Boolean);
  const normTitle = normalizeClaim(title);
  const existing = ledger.dispositions.find(
    (d) =>
      d?.fingerprint?.file === relFile &&
      normalizeClaim(d.fingerprint.title ?? "") === normTitle,
  );
  let entry;
  if (existing) {
    existing.status = status;
    existing.reason = reason;
    existing.decidedBy = decidedBy;
    existing.decidedAt = new Date().toISOString();
    if (keywords.length) existing.fingerprint.keywords = keywords;
    entry = existing;
  } else {
    const id =
      ledger.dispositions.reduce(
        (max, d) => Math.max(max, Number.isInteger(d?.id) ? d.id : 0),
        0,
      ) + 1;
    entry = {
      id,
      status,
      fingerprint: { file: relFile, title: collapseWs(title), keywords },
      reason,
      decidedBy,
      decidedAt: new Date().toISOString(),
    };
    ledger.dispositions.push(entry);
  }
  if (args.severity) entry.severity = args.severity;
  if (args["run-id"]) entry.runId = args["run-id"];
  mkdirSync(path.dirname(ledgerPath), { recursive: true });
  writeFileSync(ledgerPath, `${JSON.stringify(ledger, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify({ ...entry, ledgerPath })}\n`);
};

const renderDispositions = (args) => {
  const repoRoot = path.resolve(required(args, "repo-root"));
  const full = args.full === "true";
  let changedFiles = null;
  if (!full) {
    const changedPath = path.resolve(required(args, "changed-files"));
    try {
      changedFiles = new Set(
        readFileSync(changedPath, "utf8")
          .split(/\r?\n/)
          .map((line) => line.trim())
          .filter(Boolean),
      );
    } catch (error) {
      fail(`cannot read --changed-files: ${error.message}`);
    }
  }

  const { ledger } = readLedger(repoRoot);
  const eligible = ledger.dispositions
    .filter((entry) => {
      const file = entry?.fingerprint?.file;
      if (!file || entry.status === "overturned") return false;
      if (!existsSync(path.join(repoRoot, file))) return false;
      if (!full && !changedFiles.has(file)) return false;
      if (
        ["accepted-risk", "by-design", "intent-confirmed"].includes(
          entry.status,
        ) &&
        entry.decidedBy !== "user"
      ) {
        return false;
      }
      return true;
    })
    .sort((a, b) => String(b.decidedAt || "").localeCompare(String(a.decidedAt || "")))
    .slice(0, 20);

  const renderLines = (entries) =>
    entries.map(
      (entry) =>
        `#${entry.id} [${entry.status}] ${entry.fingerprint.file} — "${collapseWs(entry.fingerprint.title)}" — ${collapseWs(entry.reason)}`,
    );
  const suppressed = eligible.filter((entry) => entry.status !== "intent-confirmed");
  const confirmed = eligible.filter((entry) => entry.status === "intent-confirmed");
  const suppressedBlock = suppressed.length
    ? [
        "## Previously adjudicated claims (input document — NOT shared belief-state)",
        "The claims below are suppressed downstream. Re-file one ONLY with NEW evidence that",
        "the disposition is wrong; set challenges_disposition to its id and cite that evidence.",
        "This list says nothing about the rest of the code — review everything else freshly.",
        ...renderLines(suppressed),
      ].join("\n")
    : null;
  const confirmedBlock = confirmed.length
    ? [
        "## User-confirmed requirements (input document — NOT shared belief-state)",
        "The user confirmed that each claim below describes required behavior. Re-evaluate and",
        "report a matching unfixed defect normally; do NOT set challenges_disposition merely",
        "because it appears here. The verifier will attach the confirmed disposition downstream.",
        ...renderLines(confirmed),
      ].join("\n")
    : null;
  process.stdout.write(
    `${JSON.stringify({
      suppressedBlock,
      confirmedBlock,
      reviewerBlock: [suppressedBlock, confirmedBlock].filter(Boolean).join("\n\n") || null,
      renderedCount: eligible.length,
    })}\n`,
  );
};

const [command, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);
if (command === "init") init(args);
else if (command === "finish") finish(args);
else if (command === "disposition") disposition(args);
else if (command === "render-dispositions") renderDispositions(args);
else fail("command must be init, finish, disposition, or render-dispositions");
