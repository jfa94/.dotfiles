import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const directory = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(directory, "review-benchmark.mjs");
const corpusPath = path.join(directory, "..", "benchmarks", "corpus.json");

test("benchmark corpus has 14 balanced, uniquely named cases", () => {
  const corpus = JSON.parse(readFileSync(corpusPath, "utf8"));
  assert.equal(corpus.cases.length, 14);
  assert.equal(new Set(corpus.cases.map((entry) => entry.id)).size, 14);
  assert.ok(corpus.cases.some((entry) => entry.polarity === "clean"));
  assert.ok(corpus.cases.some((entry) => entry.polarity === "seeded"));
  assert.equal(corpus.recommendedRepetitions, 3);
  assert.deepEqual(corpus.requiredRuntimes, ["claude", "codex"]);
});

test("offline scorer reports recall, clean precision proxy, stability, and missing repetitions", (t) => {
  const temp = mkdtempSync(path.join(tmpdir(), "review-benchmark-"));
  t.after(() => rmSync(temp, { recursive: true, force: true }));
  const seeded = path.join(temp, "seeded.json");
  const clean = path.join(temp, "clean.json");
  writeFileSync(seeded, JSON.stringify({
    findings: [{ file: "src/users.js", title: "SQL injection through interpolated query" }],
    openQuestions: [],
  }));
  writeFileSync(clean, JSON.stringify({ findings: [], openQuestions: [] }));
  const results = path.join(temp, "results.json");
  writeFileSync(results, JSON.stringify({ runs: [
    { case: "security-sql-injection", runtime: "claude", repetition: 1, verifiedFindings: seeded },
    { case: "security-sql-injection", runtime: "claude", repetition: 2, verifiedFindings: seeded },
    { case: "clean-parameterized-query", runtime: "claude", repetition: 1, verifiedFindings: clean },
    { case: "clean-parameterized-query", runtime: "claude", repetition: 2, verifiedFindings: clean }
  ] }));
  const scored = JSON.parse(execFileSync(process.execPath, [script, "--corpus", corpusPath, "--results", results]));
  assert.equal(scored.seededRecall, 1);
  assert.equal(scored.cleanPassRate, 1);
  assert.equal(scored.casePassRate, 1);
  assert.equal(scored.stability, 1);
  assert.ok(scored.missingRecommendedRuns.length > 0);
  assert.ok(scored.missingRecommendedRuns.some((run) => run.runtime === "codex"));

  const duplicateResults = path.join(temp, "duplicate-results.json");
  writeFileSync(duplicateResults, JSON.stringify({ runs: [
    { case: "security-sql-injection", runtime: "claude", repetition: 1, verifiedFindings: seeded },
    { case: "security-sql-injection", runtime: "claude", repetition: 1, verifiedFindings: seeded }
  ] }));
  const duplicate = spawnSync(process.execPath, [script, "--corpus", corpusPath, "--results", duplicateResults]);
  assert.notEqual(duplicate.status, 0);
  assert.match(duplicate.stderr.toString(), /duplicate run/);
});
