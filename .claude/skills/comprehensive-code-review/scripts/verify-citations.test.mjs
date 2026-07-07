import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  rmSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "verify-citations.mjs",
);

// Builds a fixture repo in a temp dir, runs the script, returns parsed output.
function run(
  t,
  {
    files = {},
    reviewers = [],
    codex,
    codexVerify,
    mode = "working-tree",
    changed,
  },
) {
  const dir = mkdtempSync(path.join(tmpdir(), "vc-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) {
    const abs = path.join(dir, rel);
    mkdirSync(path.dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
  const wf = path.join(dir, "workflow-result.json");
  writeFileSync(wf, JSON.stringify({ scopeLabel: "test", mode, reviewers }));
  const args = [
    SCRIPT,
    "--workflow-result",
    wf,
    "--mode",
    mode,
    "--repo-root",
    dir,
    "--out",
    path.join(dir, "out.json"),
  ];
  if (codex) {
    const p = path.join(dir, "codex.json");
    writeFileSync(p, JSON.stringify(codex));
    args.push("--codex", p);
  }
  if (codexVerify) {
    const p = path.join(dir, "codex-verify.json");
    writeFileSync(p, JSON.stringify(codexVerify));
    args.push("--codex-verify", p);
  }
  if (changed) {
    const p = path.join(dir, "changed.txt");
    writeFileSync(p, changed.join("\n"));
    args.push("--changed-files", p);
  }
  execFileSync(process.execPath, args);
  return JSON.parse(readFileSync(path.join(dir, "out.json"), "utf8"));
}

const SRC = [
  "function add(a, b) {",
  "  return a + b;",
  "}",
  "const total = add(1, 2);",
  "if (total > 2) {",
  "  console.log('big total');",
  "}",
  "export default add;",
].join("\n");

const finding = (over = {}) => ({
  severity: "important",
  file: "src/a.js",
  line: 2,
  verbatim: "return a + b;",
  title: "t",
  why: "w",
  ...over,
});

const reviewer = (name, findings, over = {}) => ({
  name,
  status: "DONE",
  findings,
  ...over,
});

test("happy path: quote at claimed line verifies ok", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [reviewer("quality", [finding()])],
  });
  assert.equal(out.findings.length, 1);
  assert.equal(out.findings[0].verification, "ok");
  assert.equal(out.stats.perReviewer.quality.verified, 1);
});

test("line drift: unique single-line quote rescued as relocated_ok with corrected line", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("quality", [
        finding({ line: 1, verbatim: "console.log('big total');" }),
      ]),
    ],
  });
  assert.equal(out.findings[0].verification, "relocated_ok");
  assert.equal(out.findings[0].line, 6);
});

test("multi-match quote outside window is dropped_no_match", (t) => {
  const dup =
    "const x = 1;\nother line here\nconst x = 1;\nmore\nmore\nmore\nmore\nmore";
  const out = run(t, {
    files: { "src/a.js": dup },
    reviewers: [
      reviewer("quality", [finding({ line: 7, verbatim: "const x = 1;" })]),
    ],
  });
  assert.equal(out.findings.length, 0);
  assert.equal(out.dropped[0].verification, "dropped_no_match");
});

test("collapsed quote under 10 chars is dropped_quote_too_short", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [reviewer("quality", [finding({ verbatim: "return  a" })])],
  });
  assert.equal(out.dropped[0].verification, "dropped_quote_too_short");
});

test("refuted finding dropped with refute_reason, counted in stats", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("security", [
        finding({ refuted: true, refute_reason: "guard at line 5" }),
      ]),
    ],
  });
  assert.equal(out.dropped[0].verification, "refuted");
  assert.equal(out.dropped[0].refute_reason, "guard at line 5");
  assert.equal(out.stats.perReviewer.security.refuted, 1);
});

test("systemic with <2 anchors is dropped_systemic_incomplete", (t) => {
  const f = finding({
    kind: "systemic",
    failure_mode: "stuck-state",
    scenario: "s",
    anchors: [{ file: "src/a.js", line: 2, verbatim: "return a + b;" }],
  });
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [reviewer("systemic", [f])],
  });
  assert.equal(out.dropped[0].verification, "dropped_systemic_incomplete");
});

test("systemic with one bad anchor is dropped_systemic_anchor_unverified; good one passes", (t) => {
  const anchors = (second) => [
    { file: "src/a.js", line: 2, verbatim: "return a + b;" },
    { file: "src/a.js", line: 6, verbatim: second },
  ];
  const sys = (second) =>
    finding({
      kind: "systemic",
      failure_mode: "stuck-state",
      scenario: "s",
      anchors: anchors(second),
    });
  const bad = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [reviewer("systemic", [sys("not in the file at all")])],
  });
  assert.equal(
    bad.dropped[0].verification,
    "dropped_systemic_anchor_unverified",
  );
  const good = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [reviewer("systemic", [sys("console.log('big total');")])],
  });
  assert.equal(good.findings[0].verification, "ok");
});

test("systemic with valid anchors but stale top-level citation is dropped", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("systemic", [
        finding({
          kind: "systemic",
          failure_mode: "stuck-state",
          scenario: "s",
          // both anchors verify, but the top-level file/line/verbatim does not
          line: 4,
          verbatim: "this text is nowhere in the source file",
          anchors: [
            { file: "src/a.js", line: 2, verbatim: "return a + b;" },
            {
              file: "src/a.js",
              line: 6,
              verbatim: "console.log('big total');",
            },
          ],
        }),
      ]),
    ],
  });
  assert.equal(out.findings.length, 0);
  assert.equal(
    out.dropped[0].verification,
    "dropped_systemic_anchor_unverified",
  );
});

test("path escaping repoRoot (../) is never read; finding dropped_no_match", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("security", [
        finding({
          file: "../../../../../../etc/hostname",
          line: 1,
          verbatim: "some quoted string of enough length",
        }),
      ]),
    ],
  });
  assert.equal(out.findings.length, 0);
  assert.equal(out.dropped[0].verification, "dropped_no_match");
});

test("excluded paths dropped: dist/ segment and lockfile", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("quality", [
        finding({ file: "dist/a.js" }),
        finding({ file: "pnpm-lock.yaml", verbatim: "lockfileVersion: '9.0'" }),
      ]),
    ],
  });
  assert.equal(out.findings.length, 0);
  assert.equal(out.dropped.length, 2);
  assert.ok(
    out.dropped.every(
      (d) => d.verification === "dropped_excluded_build_output",
    ),
  );
});

test("dedup: nearby findings merge, highest severity wins, also_flagged_by set", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("quality", [finding({ severity: "minor" })]),
      reviewer("security", [
        finding({
          severity: "critical",
          line: 4,
          verbatim: "const total = add(1, 2);",
        }),
      ]),
    ],
  });
  assert.equal(out.findings.length, 1);
  assert.equal(out.findings[0].severity, "critical");
  assert.deepEqual(out.findings[0].also_flagged_by, ["security"]);
  assert.equal(out.stats.duplicatesMerged, 1);
});

test("codex: severity mapping, out-of-range line, missing file, refuted via codex-verify", (t) => {
  const cf = (over) => ({
    severity: "high",
    title: "T",
    body: "B",
    file: "src/a.js",
    line_start: 2,
    line_end: 3,
    confidence: 0.9,
    recommendation: "R",
    ...over,
  });
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [],
    codex: {
      target: { mode: "working-tree", explicit: true },
      result: {
        verdict: "needs-attention",
        summary: "s",
        findings: [
          cf({}),
          cf({ title: "OOR", line_start: 2, line_end: 99 }),
          cf({ title: "MISS", file: "src/gone.js" }),
          cf({ title: "REF", line_start: 4 }),
        ],
        next_steps: [],
      },
    },
    codexVerify: {
      codexFindings: [
        {
          file: "src/a.js",
          line_start: 4,
          title: "REF",
          refuted: true,
          refute_reason: "no such path",
        },
      ],
    },
  });
  assert.equal(out.findings.length, 1);
  assert.equal(out.findings[0].severity, "important");
  assert.equal(out.findings[0].codex_severity, "high");
  const byTitle = (title) => out.dropped.find((d) => d.title === title);
  assert.equal(byTitle("OOR").verification, "codex_line_out_of_range");
  assert.equal(byTitle("MISS").verification, "codex_file_missing");
  assert.equal(byTitle("REF").verification, "refuted");
  assert.equal(byTitle("REF").refute_reason, "no such path");
});

test("outside_diff tagged in base mode, absent in full mode", (t) => {
  const fixture = {
    files: { "src/a.js": SRC },
    reviewers: [reviewer("quality", [finding()])],
    changed: ["src/other.js"],
  };
  const base = run(t, { ...fixture, mode: "base" });
  assert.equal(base.findings[0].outside_diff, true);
  const full = run(t, { ...fixture, mode: "full" });
  assert.equal(full.findings[0].outside_diff, undefined);
});

test("dedup never merges a local finding with a systemic finding at the same site", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("quality", [finding({ line: 2, verbatim: "return a + b;" })]),
      reviewer("systemic", [
        finding({
          kind: "systemic",
          line: 2,
          verbatim: "return a + b;",
          failure_mode: "stuck-state",
          scenario: "s",
          anchors: [
            { file: "src/a.js", line: 2, verbatim: "return a + b;" },
            {
              file: "src/a.js",
              line: 6,
              verbatim: "console.log('big total');",
            },
          ],
        }),
      ]),
    ],
  });
  assert.equal(out.findings.length, 2);
  assert.equal(out.stats.duplicatesMerged, 0);
  assert.ok(out.findings.every((f) => !f.also_flagged_by));
});

test("codex excludes backstop: build-output path dropped, missing file field dropped", (t) => {
  const cf = (over) => ({
    severity: "high",
    title: "T",
    body: "B",
    file: "src/a.js",
    line_start: 2,
    line_end: 3,
    confidence: 0.9,
    ...over,
  });
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [],
    codex: {
      target: { mode: "working-tree", explicit: true },
      result: {
        verdict: "needs-attention",
        summary: "s",
        findings: [
          cf({ title: "DIST", file: "dist/bundle.js" }),
          cf({ title: "NOFILE", file: undefined }),
        ],
        next_steps: [],
      },
    },
  });
  assert.equal(out.findings.length, 0);
  const byTitle = (title) => out.dropped.find((d) => d.title === title);
  assert.equal(byTitle("DIST").verification, "dropped_excluded_build_output");
  assert.equal(byTitle("NOFILE").verification, "codex_file_missing");
});

test("unmatched codex refutation is surfaced in stats, not silently discarded", (t) => {
  const cf = (over) => ({
    severity: "high",
    title: "T",
    body: "B",
    file: "src/a.js",
    line_start: 2,
    line_end: 3,
    confidence: 0.9,
    ...over,
  });
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [],
    codex: {
      target: { mode: "working-tree", explicit: true },
      result: {
        verdict: "needs-attention",
        summary: "s",
        findings: [cf({})],
        next_steps: [],
      },
    },
    codexVerify: {
      codexFindings: [
        {
          // title drifted from "T" to "T2" — no finding matches this refutation
          file: "src/a.js",
          line_start: 2,
          title: "T2",
          refuted: true,
          refute_reason: "drifted",
        },
      ],
    },
  });
  // The unmatched refutation must not silently drop; the original finding
  // still ships as verified.
  assert.equal(out.findings.length, 1);
  assert.equal(out.stats.unmatchedCodexRefutations, 1);
});

test("Calibration buckets: exclusion/existence drops land in droppedOther, not droppedCitation", (t) => {
  const out = run(t, {
    files: { "src/a.js": SRC },
    reviewers: [
      reviewer("quality", [finding({ file: "dist/a.js" })]),
      reviewer("security", [
        finding({ verbatim: "too short" }), // < 10 chars collapsed -> citation failure
      ]),
    ],
  });
  assert.equal(out.stats.perReviewer.quality.droppedOther, 1);
  assert.equal(out.stats.perReviewer.quality.droppedCitation, 0);
  assert.equal(out.stats.perReviewer.security.droppedCitation, 1);
  assert.equal(out.stats.perReviewer.security.droppedOther, 0);
});
