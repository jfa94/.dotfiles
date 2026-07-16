#!/usr/bin/env node
// Deterministic validator for prd-to-spec tasks.json — enforces the Iron Laws mechanically.
// Usage: node validate-tasks.mjs <path-to-tasks.json>
// Exit 0 = clean (warnings allowed). Exit 1 = one ERROR line per finding.

import { readFileSync, realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const RISK_TIERS = ['low', 'medium', 'high'];
const VAGUE_PHRASES = [
  'works well',
  'as expected',
  'user-friendly',
  'performant',
  'robust',
  'handle errors gracefully',
  'handles errors gracefully',
  'looks good',
];
// "filename.<ext>: description" — e.g. "register.test.ts: valid registration returns 201"
const TEST_ENTRY_RE = /^[^\s:]+\.[A-Za-z0-9_]+\s*:\s*\S/;

export function validateTasks(tasks) {
  const errors = [];
  const warnings = [];

  if (!Array.isArray(tasks) || tasks.length === 0) {
    errors.push('tasks.json must be a non-empty JSON array');
    return { errors, warnings };
  }

  const isStr = (v) => typeof v === 'string' && v.trim().length > 0;
  const strArray = (v) => Array.isArray(v) && v.every(isStr);

  // Field shape + per-task rules
  const ids = new Map(); // id -> index
  tasks.forEach((t, i) => {
    const label = isStr(t?.task_id) ? t.task_id : `tasks[${i}]`;
    if (t === null || typeof t !== 'object' || Array.isArray(t)) {
      errors.push(`${label}: task must be an object`);
      return;
    }
    for (const f of ['task_id', 'title', 'description', 'risk_tier', 'risk_rationale']) {
      if (!isStr(t[f])) errors.push(`${label}: "${f}" must be a non-empty string`);
    }
    for (const f of ['files', 'acceptance_criteria', 'tests_to_write']) {
      if (!strArray(t[f])) errors.push(`${label}: "${f}" must be an array of non-empty strings`);
    }
    if (t.depends_on !== undefined && !(Array.isArray(t.depends_on) && t.depends_on.every(isStr))) {
      errors.push(`${label}: "depends_on" must be an array of task ids`);
    }

    if (isStr(t.task_id)) {
      if (ids.has(t.task_id)) errors.push(`${label}: duplicate task_id (also at index ${ids.get(t.task_id)})`);
      else ids.set(t.task_id, i);
    }
    if (strArray(t.files) && (t.files.length < 1 || t.files.length > 3)) {
      errors.push(`${label}: "files" has ${t.files.length} entries — must be 1–3`);
    }
    if (isStr(t.risk_tier) && !RISK_TIERS.includes(t.risk_tier)) {
      errors.push(`${label}: risk_tier "${t.risk_tier}" not in ${RISK_TIERS.join('|')}`);
    }
    if (strArray(t.acceptance_criteria) && strArray(t.tests_to_write)) {
      if (t.tests_to_write.length < t.acceptance_criteria.length) {
        errors.push(
          `${label}: ${t.acceptance_criteria.length} acceptance criteria but only ${t.tests_to_write.length} tests_to_write — need >= 1 test per criterion`,
        );
      }
    }
    if (strArray(t.tests_to_write)) {
      for (const entry of t.tests_to_write) {
        if (!TEST_ENTRY_RE.test(entry)) {
          errors.push(`${label}: tests_to_write entry "${entry}" must be "filename.<ext>: what it asserts"`);
        }
      }
    }
    if (strArray(t.acceptance_criteria)) {
      for (const c of t.acceptance_criteria) {
        const lc = c.toLowerCase();
        const hit = VAGUE_PHRASES.find((p) => lc.includes(p));
        if (hit) errors.push(`${label}: vague acceptance criterion "${c}" (contains "${hit}") — restate as a pass/fail predicate`);
      }
    }
  });

  // Dependency graph: dangling refs, self-deps, cycles
  const deps = new Map(); // id -> string[] (only refs to existing ids, for traversal)
  for (const t of tasks) {
    if (!isStr(t?.task_id)) continue;
    const list = Array.isArray(t.depends_on) ? t.depends_on.filter(isStr) : [];
    for (const d of list) {
      if (d === t.task_id) errors.push(`${t.task_id}: depends on itself`);
      else if (!ids.has(d)) errors.push(`${t.task_id}: depends_on references non-existent task "${d}"`);
    }
    deps.set(t.task_id, list.filter((d) => ids.has(d) && d !== t.task_id));
  }

  const state = new Map(); // 0 = visiting, 1 = done
  const findCycle = (id, path) => {
    if (state.get(id) === 1) return null;
    if (state.get(id) === 0) return [...path.slice(path.indexOf(id)), id];
    state.set(id, 0);
    path.push(id);
    for (const d of deps.get(id) ?? []) {
      const cycle = findCycle(d, path);
      if (cycle) return cycle;
    }
    path.pop();
    state.set(id, 1);
    return null;
  };
  for (const id of deps.keys()) {
    const cycle = findCycle(id, []);
    if (cycle) {
      errors.push(`cycle in depends_on: ${cycle.join(' -> ')}`);
      break; // one cycle report is enough; fixing it re-runs the validator
    }
  }

  // Tasks sharing a file need a dependency path between them (either direction, transitive OK)
  const reachable = (from, to) => {
    const seen = new Set();
    const stack = [from];
    while (stack.length) {
      const cur = stack.pop();
      if (cur === to) return true;
      if (seen.has(cur)) continue;
      seen.add(cur);
      stack.push(...(deps.get(cur) ?? []));
    }
    return false;
  };
  const withFiles = tasks.filter((t) => isStr(t?.task_id) && strArray(t.files));
  for (let a = 0; a < withFiles.length; a++) {
    for (let b = a + 1; b < withFiles.length; b++) {
      const ta = withFiles[a];
      const tb = withFiles[b];
      const shared = ta.files.find((f) => tb.files.includes(f));
      if (shared && !reachable(ta.task_id, tb.task_id) && !reachable(tb.task_id, ta.task_id)) {
        errors.push(`${ta.task_id} and ${tb.task_id} both touch "${shared}" but have no dependency path between them`);
      }
    }
  }

  // Blanket risk tier is a non-judgment (warning — the rationale text may still justify it)
  const tiers = new Set(tasks.map((t) => t?.risk_tier).filter(isStr));
  if (tasks.length >= 3 && tiers.size === 1) {
    warnings.push(`all ${tasks.length} tasks share risk_tier "${[...tiers][0]}" — a blanket tier is not a judgment; re-check each`);
  }

  return { errors, warnings };
}

// realpath both sides: import.meta.url is symlink-resolved by the ESM loader, argv[1] is not
const isMain = process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href;
if (isMain) {
  const path = process.argv[2];
  if (!path) {
    console.error('Usage: node validate-tasks.mjs <path-to-tasks.json>');
    process.exit(1);
  }
  let tasks;
  try {
    tasks = JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    console.error(`ERROR: cannot read/parse ${path}: ${e.message}`);
    process.exit(1);
  }
  const { errors, warnings } = validateTasks(tasks);
  for (const w of warnings) console.log(`WARN: ${w}`);
  for (const e of errors) console.log(`ERROR: ${e}`);
  if (errors.length) {
    console.log(`${errors.length} error(s) — fix and re-run.`);
    process.exit(1);
  }
  console.log(`OK: ${tasks.length} tasks pass all mechanical checks${warnings.length ? ` (${warnings.length} warning(s))` : ''}.`);
}
