#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const fail = (message) => {
  process.stderr.write(`review-benchmark: ${message}\n`);
  process.exit(1);
};
const parseArgs = (values) => {
  const out = {};
  for (let i = 0; i < values.length; i += 2) {
    if (!values[i]?.startsWith("--") || values[i + 1] === undefined) fail("arguments must be --name value pairs");
    out[values[i].slice(2)] = values[i + 1];
  }
  return out;
};
const readJson = (file, label) => {
  if (!file) fail(`--${label} is required`);
  try {
    return JSON.parse(readFileSync(file instanceof URL ? file : path.resolve(file), "utf8"));
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
};
const args = parseArgs(process.argv.slice(2));
const corpus = readJson(args.corpus || new URL("../benchmarks/corpus.json", import.meta.url), "corpus");
const resultIndex = readJson(args.results, "results");
if (corpus.version !== 1 || !Array.isArray(corpus.cases)) fail("unsupported corpus");
if (!Array.isArray(resultIndex.runs)) fail("results must contain a runs array");

const cases = new Map(corpus.cases.map((entry) => [entry.id, entry]));
const expectedRuns = corpus.recommendedRepetitions || 3;
const requiredRuntimes = corpus.requiredRuntimes;
if (!Array.isArray(requiredRuntimes) || requiredRuntimes.length === 0) fail("corpus must define requiredRuntimes");
const runKeys = new Set();
const normalizedRuns = resultIndex.runs.map((run) => {
  const benchmarkCase = cases.get(run.case);
  if (!benchmarkCase) fail(`unknown case ${run.case}`);
  if (!requiredRuntimes.includes(run.runtime)) fail(`unsupported runtime ${run.runtime}`);
  if (!Number.isInteger(run.repetition) || run.repetition < 1 || run.repetition > expectedRuns) {
    fail(`invalid repetition for ${run.runtime}:${run.case}`);
  }
  const runKey = `${run.runtime}:${run.case}:${run.repetition}`;
  if (runKeys.has(runKey)) fail(`duplicate run ${runKey}`);
  runKeys.add(runKey);
  const output = readJson(run.verifiedFindings, `verified findings for ${run.case}`);
  const candidates = [
    ...(output.findings || []).map((finding) => ({ kind: "finding", ...finding })),
    ...(output.openQuestions || []).map((finding) => ({ kind: "question", ...finding })),
  ];
  const matches = benchmarkCase.expected.map((expected) =>
    candidates.some((candidate) => {
      if (candidate.kind !== expected.kind || candidate.file !== expected.file) return false;
      const text = `${candidate.title || ""} ${candidate.why || ""} ${candidate.body || ""} ${candidate.intent_question || ""}`.toLowerCase();
      return expected.signals.some((signal) => text.includes(signal.toLowerCase()));
    }),
  );
  return {
    case: run.case,
    runtime: run.runtime,
    repetition: run.repetition,
    polarity: benchmarkCase.polarity,
    expected: matches.length,
    detected: matches.filter(Boolean).length,
    unexpected: benchmarkCase.polarity === "clean" ? candidates.length : 0,
    passed: benchmarkCase.polarity === "clean" ? candidates.length === 0 : matches.every(Boolean),
  };
});

const groups = new Map();
for (const run of normalizedRuns) {
  const key = `${run.runtime}:${run.case}`;
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(run);
}
const missing = [];
for (const runtime of requiredRuntimes) {
  for (const benchmarkCase of corpus.cases) {
    const count = groups.get(`${runtime}:${benchmarkCase.id}`)?.length || 0;
    if (count < expectedRuns) missing.push({ runtime, case: benchmarkCase.id, missing: expectedRuns - count });
  }
}
const seeded = normalizedRuns.filter((run) => run.polarity === "seeded");
const clean = normalizedRuns.filter((run) => run.polarity === "clean");
const summary = {
  schemaVersion: 1,
  runs: normalizedRuns.length,
  seededRecall: seeded.reduce((sum, run) => sum + run.detected, 0) /
    Math.max(1, seeded.reduce((sum, run) => sum + run.expected, 0)),
  cleanPassRate: clean.filter((run) => run.passed).length / Math.max(1, clean.length),
  casePassRate: normalizedRuns.filter((run) => run.passed).length / Math.max(1, normalizedRuns.length),
  stability: [...groups.values()].filter((runs) => runs.length >= 2 && runs.every((run) => run.passed === runs[0].passed)).length /
    Math.max(1, [...groups.values()].filter((runs) => runs.length >= 2).length),
  missingRecommendedRuns: missing,
  runsByCase: normalizedRuns,
};
const serialized = `${JSON.stringify(summary, null, 2)}\n`;
if (args.out) writeFileSync(path.resolve(args.out), serialized, "utf8");
else process.stdout.write(serialized);
