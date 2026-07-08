import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateTasks } from './validate-tasks.mjs';

const task = (over = {}) => ({
  task_id: 'a-001',
  title: 'Registration happy path',
  description: 'End-to-end registration slice',
  files: ['src/routes/register.ts', 'src/services/auth.ts'],
  acceptance_criteria: ['POST /register with valid input returns 201'],
  tests_to_write: ['register.test.ts: valid registration returns 201'],
  depends_on: [],
  risk_tier: 'high',
  risk_rationale: 'Security-critical path',
  ...over,
});

test('valid list passes with no errors', () => {
  const { errors } = validateTasks([
    task(),
    task({ task_id: 'a-002', files: ['src/domain/validation.ts'], depends_on: ['a-001'], risk_tier: 'medium' }),
  ]);
  assert.deepEqual(errors, []);
});

test('non-array and empty array rejected', () => {
  assert.ok(validateTasks({}).errors.length > 0);
  assert.ok(validateTasks([]).errors.length > 0);
});

test('duplicate task_id rejected', () => {
  const { errors } = validateTasks([task(), task({ files: ['other.ts'], risk_tier: 'low' })]);
  assert.ok(errors.some((e) => e.includes('duplicate task_id')));
});

test('files must be 1-3', () => {
  const four = task({ files: ['a.ts', 'b.ts', 'c.ts', 'd.ts'] });
  assert.ok(validateTasks([four]).errors.some((e) => e.includes('must be 1–3')));
  const zero = task({ files: [] });
  assert.ok(validateTasks([zero]).errors.some((e) => e.includes('"files"')));
});

test('tests_to_write must cover every acceptance criterion', () => {
  const { errors } = validateTasks([
    task({
      acceptance_criteria: ['returns 201', 'stores bcrypt hash'],
      tests_to_write: ['register.test.ts: returns 201'],
    }),
  ]);
  assert.ok(errors.some((e) => e.includes('need >= 1 test per criterion')));
});

test('tests_to_write entries must be filename.<ext>: description', () => {
  const { errors } = validateTasks([task({ tests_to_write: ['test that it works'] })]);
  assert.ok(errors.some((e) => e.includes('filename.<ext>')));
});

test('vague acceptance criteria rejected', () => {
  const { errors } = validateTasks([
    task({ acceptance_criteria: ['handles errors gracefully'], tests_to_write: ['x.test.ts: asserts nothing'] }),
  ]);
  assert.ok(errors.some((e) => e.includes('vague acceptance criterion')));
});

test('invalid risk_tier and empty rationale rejected', () => {
  const { errors } = validateTasks([task({ risk_tier: 'extreme', risk_rationale: ' ' })]);
  assert.ok(errors.some((e) => e.includes('risk_tier "extreme"')));
  assert.ok(errors.some((e) => e.includes('"risk_rationale"')));
});

test('dangling depends_on ref rejected', () => {
  const { errors } = validateTasks([task({ depends_on: ['ghost-999'] })]);
  assert.ok(errors.some((e) => e.includes('non-existent task "ghost-999"')));
});

test('self-dependency rejected', () => {
  const { errors } = validateTasks([task({ depends_on: ['a-001'] })]);
  assert.ok(errors.some((e) => e.includes('depends on itself')));
});

test('cycle detected with path', () => {
  const { errors } = validateTasks([
    task({ task_id: 'a-001', depends_on: ['a-002'] }),
    task({ task_id: 'a-002', files: ['x.ts'], depends_on: ['a-003'], risk_tier: 'medium' }),
    task({ task_id: 'a-003', files: ['y.ts'], depends_on: ['a-001'], risk_tier: 'low' }),
  ]);
  const cycle = errors.find((e) => e.startsWith('cycle in depends_on'));
  assert.ok(cycle);
  assert.ok(cycle.includes('->'));
});

test('shared file without dependency path rejected', () => {
  const { errors } = validateTasks([
    task({ task_id: 'a-001' }),
    task({ task_id: 'a-002', files: ['src/services/auth.ts'], risk_tier: 'medium' }),
  ]);
  assert.ok(errors.some((e) => e.includes('no dependency path')));
});

test('transitive dependency path satisfies shared-file rule', () => {
  const { errors } = validateTasks([
    task({ task_id: 'a-001' }),
    task({ task_id: 'a-002', files: ['mid.ts'], depends_on: ['a-001'], risk_tier: 'medium' }),
    task({ task_id: 'a-003', files: ['src/services/auth.ts'], depends_on: ['a-002'], risk_tier: 'low' }),
  ]);
  assert.deepEqual(errors, []);
});

test('blanket risk tier warns but does not fail', () => {
  const { errors, warnings } = validateTasks([
    task({ task_id: 'a-001' }),
    task({ task_id: 'a-002', files: ['b.ts'], depends_on: ['a-001'] }),
    task({ task_id: 'a-003', files: ['c.ts'], depends_on: ['a-002'] }),
  ]);
  assert.deepEqual(errors, []);
  assert.ok(warnings.some((w) => w.includes('blanket tier')));
});
