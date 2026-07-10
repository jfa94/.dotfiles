#!/usr/bin/env node
// Deterministic citation verification for the comprehensive/quick code-review
// skills. Implements the spec in references/workflow-and-codex.md §6 so the
// orchestrator LLM never hand-executes this procedure.
//
// Usage:
//   node verify-citations.mjs --workflow-result <path> [--codex <path>]
//     [--codex-verify <path>] --mode <full|base|working-tree>
//     [--changed-files <path>] --repo-root <path> --out <path>
//
// --codex takes raw/codex-adversarial.json; only payload.result.findings
// (structured outcome) is processed — the degraded rawOutput fallback stays
// with the orchestrator. --codex-verify takes raw/codex-verify-result.json
// (refuter annotations from the workflow's in-script Codex-verify stage).

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";

const MIN_QUOTE = 10;
const EXCLUDED_SEGMENTS = new Set([
  "dist",
  "build",
  "out",
  ".next",
  ".nuxt",
  ".svelte-kit",
  ".output",
  "coverage",
]);
const EXCLUDED_SUFFIXES = [".min.js", ".min.css", ".map"];
const LOCKFILES = new Set([
  "pnpm-lock.yaml",
  "package-lock.json",
  "yarn.lock",
  "bun.lock",
  "bun.lockb",
]);
const SEVERITY_RANK = { critical: 3, important: 2, minor: 1 };
const CODEX_SEVERITY_MAP = {
  critical: "critical",
  high: "important",
  medium: "important",
  low: "minor",
};

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    if (!key.startsWith("--") || argv[i + 1] === undefined) {
      throw new Error("Bad argument: " + key);
    }
    opts[key.slice(2)] = argv[i + 1];
  }
  for (const req of ["workflow-result", "mode", "repo-root", "out"]) {
    if (!opts[req]) throw new Error("Missing required --" + req);
  }
  if (!["full", "base", "working-tree"].includes(opts.mode)) {
    throw new Error("Bad --mode: " + opts.mode);
  }
  return opts;
}

const collapseWs = (s) => String(s).replace(/\s+/g, " ").trim();

function relKey(repoRoot, file) {
  return path.relative(repoRoot, path.resolve(repoRoot, file));
}

function isExcluded(rel) {
  const segments = rel.split(path.sep);
  if (segments.some((s) => EXCLUDED_SEGMENTS.has(s))) return true;
  const base = segments[segments.length - 1];
  if (LOCKFILES.has(base)) return true;
  return EXCLUDED_SUFFIXES.some((suf) => base.endsWith(suf));
}

// Optional inputs (--codex / --codex-verify) are LLM/CLI-written; surface bad
// ones as report-visible errors, never crash the whole verification pass.
function readJsonSafe(p, label) {
  let raw;
  try {
    raw = readFileSync(p, "utf8");
  } catch (e) {
    return { error: label + " unreadable: " + e.message };
  }
  if (!raw.trim()) return { error: label + " is empty" };
  try {
    return { value: JSON.parse(raw) };
  } catch (e) {
    return { error: label + " invalid JSON: " + e.message };
  }
}

// File-content cache: returns array of lines or null if unreadable.
const fileCache = new Map();
function fileLines(repoRoot, file) {
  const abs = path.resolve(repoRoot, file);
  if (!fileCache.has(abs)) {
    // Containment: finding.file comes from LLM/Codex output reviewing
    // potentially hostile code; never read outside repoRoot (../ or absolute).
    const rel = path.relative(repoRoot, abs);
    if (rel === "" || rel.startsWith("..") || path.isAbsolute(rel)) {
      fileCache.set(abs, null);
    } else {
      try {
        fileCache.set(abs, readFileSync(abs, "utf8").split("\n"));
      } catch {
        fileCache.set(abs, null);
      }
    }
  }
  return fileCache.get(abs);
}

// §6 core check: line±2 collapsed-substring, else single-line grep rescue
// (exactly one matching line → relocated_ok). Returns {status, line}.
function verifyCitation(repoRoot, { file, line, verbatim }) {
  const quote = collapseWs(verbatim);
  if (quote.length < MIN_QUOTE) return { status: "dropped_quote_too_short" };
  const lines = fileLines(repoRoot, file);
  if (!lines) return { status: "dropped_no_match", detail: "file unreadable" };
  const window = lines.slice(Math.max(0, line - 3), line + 2).join("\n");
  if (collapseWs(window).includes(quote)) return { status: "ok", line };
  if (!String(verbatim).trim().includes("\n")) {
    const hits = [];
    lines.forEach((l, i) => {
      if (collapseWs(l).includes(quote)) hits.push(i + 1);
    });
    if (hits.length === 1) return { status: "relocated_ok", line: hits[0] };
  }
  return { status: "dropped_no_match" };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const repoRoot = path.resolve(opts["repo-root"]);
  const workflowResult = JSON.parse(
    readFileSync(opts["workflow-result"], "utf8"),
  );
  const changedFiles = opts["changed-files"]
    ? readFileSync(opts["changed-files"], "utf8")
        .split("\n")
        .map((l) => l.trim())
        .filter(Boolean)
        .map((f) => relKey(repoRoot, f))
    : null;
  const diffMode = opts.mode !== "full";

  const verified = [];
  const dropped = [];
  let unmatchedCodexRefutations = 0;
  const perReviewer = {};
  const bump = (name, key) => {
    perReviewer[name] ||= {
      verified: 0,
      refuted: 0,
      droppedCitation: 0,
      droppedOther: 0,
    };
    perReviewer[name][key]++;
  };
  // Genuine citation-verification failures vs. everything else (excluded
  // build output, Codex existence checks) — keeps the Calibration line honest
  // about what actually failed quote/line verification.
  const CITATION_VERIFICATIONS = new Set([
    "dropped_no_citation",
    "dropped_no_match",
    "dropped_quote_too_short",
    "dropped_systemic_incomplete",
    "dropped_systemic_anchor_unverified",
  ]);
  const drop = (finding, verification, extra) => {
    dropped.push(Object.assign({}, finding, { verification }, extra || {}));
    const bucket =
      verification === "refuted"
        ? "refuted"
        : CITATION_VERIFICATIONS.has(verification)
          ? "droppedCitation"
          : "droppedOther";
    bump(finding.reviewer, bucket);
  };
  const keep = (finding, verification) => {
    finding.verification = verification;
    if (
      diffMode &&
      changedFiles &&
      finding.kind !== "systemic" &&
      !changedFiles.includes(relKey(repoRoot, finding.file))
    ) {
      finding.outside_diff = true;
    }
    verified.push(finding);
    bump(finding.reviewer, "verified");
  };

  // --- Reviewer findings (§6 order: excluded → refuted → systemic → citation) ---
  for (const reviewer of workflowResult.reviewers || []) {
    for (const raw of reviewer.findings || []) {
      const f = Object.assign({}, raw, { reviewer: reviewer.name });
      if (f.file && isExcluded(relKey(repoRoot, f.file))) {
        drop(f, "dropped_excluded_build_output");
      } else if (f.refuted) {
        drop(f, "refuted");
      } else if (f.kind === "systemic") {
        if (!f.failure_mode || !f.scenario || (f.anchors || []).length < 2) {
          drop(f, "dropped_systemic_incomplete");
        } else {
          // Verify every anchor AND the top-level citation (the charter
          // repeats anchors[0] there, but a stale/unrelated top-level must not
          // ride in unverified behind valid anchors).
          const toCheck = [
            ...f.anchors,
            { file: f.file, line: f.line, verbatim: f.verbatim },
          ];
          const bad = toCheck.find(
            (a) => !verifyCitation(repoRoot, a).status.includes("ok"),
          );
          if (bad) {
            drop(f, "dropped_systemic_anchor_unverified", {
              detail: "anchor failed: " + bad.file + ":" + bad.line,
            });
          } else {
            keep(f, "ok");
          }
        }
      } else if (f.file && f.line && f.verbatim) {
        const res = verifyCitation(repoRoot, f);
        if (res.status === "ok" || res.status === "relocated_ok") {
          f.line = res.line;
          keep(f, res.status);
        } else {
          drop(f, res.status, res.detail ? { detail: res.detail } : undefined);
        }
      } else {
        drop(f, "dropped_no_citation");
      }
    }
  }

  // --- Codex findings (structured outcome only): existence-checked, not quote-verified ---
  let codexFindings = [];
  let codexPayloadError = null;
  let codexVerifyError = null;
  if (opts.codex) {
    const r = readJsonSafe(opts.codex, "--codex payload");
    if (r.error) {
      codexPayloadError = r.error;
      console.error(
        "verify-citations: " + r.error + " — Codex track dropped from this pass",
      );
    } else {
      codexFindings = (r.value.result && r.value.result.findings) || [];
    }
  }
  if (opts["codex-verify"] && codexFindings.length) {
    const r = readJsonSafe(opts["codex-verify"], "--codex-verify payload");
    const verify = r.value;
    if (r.error) {
      codexVerifyError = r.error;
      console.error(
        "verify-citations: " + r.error + " — Codex findings kept unrefuted",
      );
    }
    for (const v of (verify && verify.codexFindings) || []) {
      if (!v.refuted) continue;
      // Content (this loop's target) comes from the trusted codex-adversarial
      // payload; only the refute bit is trusted from the LLM-transcribed
      // codex-verify-result. Mark every match (not just the first) so a
      // duplicate (file,line_start,title) triple can't leave a sibling
      // unrefuted, and never let an unmatched refutation vanish silently.
      const matches = codexFindings.filter(
        (c) =>
          c.file === v.file &&
          c.line_start === v.line_start &&
          c.title === v.title,
      );
      if (matches.length === 0) {
        unmatchedCodexRefutations++;
        console.error(
          "verify-citations: codex-verify refutation matched no finding — " +
            JSON.stringify({
              file: v.file,
              line_start: v.line_start,
              title: v.title,
            }),
        );
        continue;
      }
      for (const match of matches) {
        match.refuted = true;
        match.refute_reason = v.refute_reason;
      }
    }
  }
  for (const c of codexFindings) {
    if (!(c.severity in CODEX_SEVERITY_MAP)) {
      console.error(
        "verify-citations: unrecognized Codex severity " +
          JSON.stringify(c.severity) +
          " for " +
          c.file +
          ":" +
          c.line_start +
          " — demoted to minor",
      );
    }
    const f = {
      reviewer: "codex-adversarial",
      severity: CODEX_SEVERITY_MAP[c.severity] || "minor",
      codex_severity: c.severity,
      file: c.file,
      line: c.line_start,
      line_end: c.line_end,
      title: c.title,
      why: c.body,
      fix_sketch: c.recommendation,
      confidence: c.confidence,
      kind: "local",
    };
    if (c.refuted) {
      drop(Object.assign(f, { refute_reason: c.refute_reason }), "refuted");
    } else if (!f.file || isExcluded(relKey(repoRoot, f.file))) {
      drop(f, f.file ? "dropped_excluded_build_output" : "codex_file_missing");
    } else {
      const lines = fileLines(repoRoot, f.file);
      if (!lines) {
        drop(f, "codex_file_missing");
      } else if (
        !Number.isInteger(c.line_start) ||
        !Number.isInteger(c.line_end) ||
        c.line_start < 1 ||
        c.line_end < c.line_start ||
        c.line_end > lines.length
      ) {
        drop(f, "codex_line_out_of_range");
      } else {
        keep(f, "ok");
      }
    }
  }

  // --- Dedup: same file AND same kind AND (lines ±3 OR identical collapsed verbatim) ---
  let duplicatesMerged = 0;
  const deduped = [];
  for (const f of verified) {
    const fKind = f.kind || "local";
    const twin = deduped.find(
      (k) =>
        relKey(repoRoot, k.file) === relKey(repoRoot, f.file) &&
        (k.kind || "local") === fKind &&
        (Math.abs(k.line - f.line) <= 3 ||
          (k.verbatim &&
            f.verbatim &&
            collapseWs(k.verbatim) === collapseWs(f.verbatim))),
    );
    if (twin) {
      if (SEVERITY_RANK[f.severity] > SEVERITY_RANK[twin.severity]) {
        twin.severity = f.severity;
      }
      twin.also_flagged_by = [
        ...new Set([...(twin.also_flagged_by || []), f.reviewer]),
      ];
      duplicatesMerged++;
    } else {
      deduped.push(f);
    }
  }

  const output = {
    scopeLabel: workflowResult.scopeLabel ?? null,
    mode: opts.mode,
    reviewers: (workflowResult.reviewers || []).map((r) => ({
      name: r.name,
      status: r.status,
      verdict: r.verdict,
      blocked_reason: r.blocked_reason,
      dropped_by_cap: r.dropped_by_cap,
    })),
    findings: deduped,
    dropped,
    codexPayloadError,
    codexVerifyError,
    stats: { perReviewer, duplicatesMerged, unmatchedCodexRefutations },
  };
  mkdirSync(path.dirname(path.resolve(opts.out)), { recursive: true });
  writeFileSync(opts.out, JSON.stringify(output, null, 2));
  console.log(
    `verified=${deduped.length} dropped=${dropped.length} duplicatesMerged=${duplicatesMerged}` +
      (codexPayloadError ? ` codexPayloadError=${JSON.stringify(codexPayloadError)}` : "") +
      (codexVerifyError ? ` codexVerifyError=${JSON.stringify(codexVerifyError)}` : "") +
      ` -> ${opts.out}`,
  );
}

main();
